defmodule ElixirLS.LanguageServer.BuildBatchingTest do
  alias ElixirLS.LanguageServer.{MixProjectCache, Parser, Server, SourceFile, Tracer}
  import ElixirLS.LanguageServer.Test.ServerTestHelpers
  use ElixirLS.Utils.MixTest.Case, async: false
  use ElixirLS.LanguageServer.Protocol

  setup do
    {:ok, server} = Server.start_link()
    start_server(server)
    start_supervised!(Tracer)
    start_supervised!(MixProjectCache)
    start_supervised!(Parser)

    on_exit(fn ->
      Code.put_compiler_option(:tracers, [])
      if Process.alive?(server), do: GenServer.stop(server)
    end)

    %{server: server}
  end

  defp source(value, delay \\ 0) do
    recipient = self() |> :erlang.term_to_binary() |> Base.encode64()

    """
    defmodule BatchTarget do
      send(:erlang.binary_to_term(Base.decode64!("#{recipient}")),
        {:compiled, :#{value}, System.monotonic_time(:millisecond)})
      Process.sleep(#{delay})
      def answer, do: :#{value}
    end
    """
  end

  defp fixture(server, fun) do
    in_fixture(__DIR__, "clean", fn ->
      File.mkdir_p!("lib")
      path = Path.expand("lib/batch_target.ex")
      File.write!(path, source(:aa))

      File.write!("lib/batch_caller.ex", """
      defmodule BatchCaller do
        @value BatchTarget.answer()
        def answer, do: @value
      end
      """)

      initialize(server)
      assert_receive {:compiled, :aa, _}, 2000
      drain_queued()
      fun.(path, SourceFile.Path.to_uri(path))
    end)
  end

  defp drain_queued do
    receive do
      %{"method" => "telemetry/event", "params" => %{"name" => "build_queued"}} ->
        drain_queued()
    after
      0 -> :ok
    end
  end

  defp changed(server, uri, type \\ 2) do
    Server.receive_packet(server, did_change_watched_files([%{"uri" => uri, "type" => type}]))
  end

  @tag :fixture
  test "save and watcher bursts use one fixed window and one incremental compile", %{
    server: server
  } do
    fixture(server, fn path, uri ->
      text = source(:bb)
      File.write!(path, text)
      started = System.monotonic_time(:millisecond)
      changed(server, uri)

      assert_receive %{"method" => "telemetry/event", "params" => %{"name" => "build_queued"}},
                     100

      # A later save and a creation event from another producer must not reset
      # the original timer. The file is open by the time the watcher arrives.
      refute_receive {:compiled, :bb, _}, 80
      Server.receive_packet(server, did_open(uri, "elixir", 1, text))
      Server.receive_packet(server, did_save(uri))
      refute_receive {:compiled, :bb, _}, 80
      changed(server, uri, 1)
      assert_receive {:compiled, :bb, compiled_at}, 180
      assert compiled_at - started >= 240
      assert compiled_at - started < 350
      wait_until_compiled(server)
      refute_receive {:compiled, :bb, _}, 350
      assert apply(BatchTarget, :answer, []) == :bb
      assert apply(BatchCaller, :answer, []) == :bb
    end)
  end

  @tag :fixture
  test "late duplicate notifications cost one follow-up build without looping", %{server: server} do
    fixture(server, fn path, uri ->
      File.write!(path, source(:bb, 400))
      changed(server, uri)
      assert_receive {:compiled, :bb, _}, 1500
      # No second disk write: intentionally exercise redundant late delivery.
      for _ <- 1..10, do: changed(server, uri)
      assert_receive {:compiled, :bb, _}, 1500
      wait_until_compiled(server)
      refute_receive {:compiled, :bb, _}, 350
      assert apply(BatchTarget, :answer, []) == :bb
      assert apply(BatchCaller, :answer, []) == :bb
    end)
  end

  @tag :fixture
  test "a same-path edit during compilation survives completion of the old batch", %{
    server: server
  } do
    fixture(server, fn path, uri ->
      File.write!(path, source(:bb, 500))
      changed(server, uri)
      assert_receive {:compiled, :bb, _}, 1500
      drain_queued()
      File.write!(path, source(:cc))
      for _ <- 1..10, do: changed(server, uri)

      assert_receive %{"method" => "telemetry/event", "params" => %{"name" => "build_queued"}},
                     100

      assert_receive {:compiled, :cc, _}, 2000
      wait_until_compiled(server)
      refute_receive {:compiled, :cc, _}, 350
      assert apply(BatchTarget, :answer, []) == :cc
      assert apply(BatchCaller, :answer, []) == :cc
    end)
  end
end
