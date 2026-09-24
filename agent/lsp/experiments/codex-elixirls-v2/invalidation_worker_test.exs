defmodule ElixirLS.LanguageServer.InvalidationWorkerTest do
  alias ElixirLS.LanguageServer.{Build, MixProjectCache, Parser, Server, SourceFile, Tracer}
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

  @tag :fixture
  test "worker death preserves an invalidation for an unrelated later trigger", %{server: server} do
    in_fixture(__DIR__, "clean", fn ->
      File.mkdir_p!("lib")
      target = Path.expand("lib/retention_target.ex")
      source = "defmodule RetentionTarget do\n  def answer, do: :aa\nend\n"
      File.write!(target, source)

      File.write!("lib/retention_caller.ex", """
      defmodule RetentionCaller do
        @answer RetentionTarget.answer()
        def answer, do: @answer
      end
      """)

      initialize(server)
      assert apply(RetentionTarget, :answer, []) == :aa
      assert apply(RetentionCaller, :answer, []) == :aa
      stat = File.stat!(target)
      File.write!(target, String.replace(source, ":aa", ":bb"))
      File.touch!(target, stat.mtime)
      uri = SourceFile.Path.to_uri(target)

      # Kill the actual worker while it waits for the existing build lock,
      # before it can service the path. No mocked success or state replacement.
      Build.with_build_lock(fn ->
        Server.receive_packet(server, did_change_watched_files([%{"uri" => uri, "type" => 2}]))
        wait_for_worker(server)
        %{build_pid: pid, build_running?: true} = :sys.get_state(server)
        Process.exit(pid, :kill)
      end)

      wait_until_compiled(server)
      assert apply(RetentionTarget, :answer, []) == :aa

      other = SourceFile.Path.to_uri(Path.expand("test/retry.exs"))
      Server.receive_packet(server, did_change_watched_files([%{"uri" => other, "type" => 2}]))
      wait_until_compiled(server)
      assert apply(RetentionTarget, :answer, []) == :bb
      assert apply(RetentionCaller, :answer, []) == :bb
    end)
  end

  defp wait_for_worker(server, attempts \\ 100)
  defp wait_for_worker(_server, 0), do: flunk("build worker did not start")

  defp wait_for_worker(server, attempts) do
    unless :sys.get_state(server).build_running? do
      Process.sleep(10)
      wait_for_worker(server, attempts - 1)
    end
  end
end
