# Acceptance tests for the outgoing-calls site parser, through its CLI.
# Run: elixir agent/lsp/dexter/tests/sites_test.exs
ExUnit.start()

defmodule SitesAcceptanceTest do
  use ExUnit.Case, async: true

  @helper Path.expand("../sites.exs", __DIR__)
  @runner Path.join(__DIR__, "stdin_runner.py")
  @fixtures Path.join(__DIR__, "fixtures/sites")
  @inputs Path.join(
            System.tmp_dir!(),
            "dx-sites-test-#{System.pid()}-#{System.unique_integer([:positive])}"
          )

  setup_all do
    File.mkdir_p!(@inputs)
    on_exit(fn -> File.rm_rf!(@inputs) end)
  end

  describe "caller selection" do
    test "a default head, a later head and a body line select every admit/3 clause and no sibling arity" do
      for line <- [20, 22, 25] do
        assert %{
                 "caller" => %{"module" => "Shop.Accounts", "name" => "admit", "arity" => 3},
                 "clauses" => [
                   %{"line" => 20, "end_line" => 20},
                   %{"line" => 22, "end_line" => 30}
                 ]
               } = result = run_sites!("accounts.ex", line)

        assert [
                 {"normalize", 22, 23},
                 {"is_ip_address", 24, 13},
                 {"call", 25, 16}
               ] == sites(result),
               "query at line #{line}"
      end
    end

    test "either clause of handle/2, or a body line, selects both clauses" do
      for line <- [32, 36, 39] do
        assert %{
                 "caller" => %{"module" => "Shop.Accounts", "name" => "handle", "arity" => 2},
                 "clauses" => [
                   %{"line" => 32, "end_line" => 34},
                   %{"line" => 36, "end_line" => 43}
                 ]
               } = result = run_sites!("accounts.ex", line)

        # No row for the `count > 3` operator or the `state.table` field access.
        assert [
                 {"info", 32, 18},
                 {"map", 36, 19},
                 {"entry", 36, 30},
                 {"find", 38, 14},
                 {"limited", 40, 23}
               ] == sites(result),
               "query at line #{line}"
      end
    end

    test "sibling arities stay apart" do
      assert %{
               "caller" => %{"name" => "deliver", "arity" => 1},
               "clauses" => [%{"line" => 4, "end_line" => 8}]
             } = deliver1 = run_sites!("accounts.ex", 4)

      assert [{"build", 4, 18}, {"insert!", 5, 9}, {"send_login", 6, 16}] == sites(deliver1)

      assert %{
               "caller" => %{"name" => "deliver", "arity" => 2},
               "clauses" => [%{"line" => 57, "end_line" => 59}]
             } = deliver2 = run_sites!("accounts.ex", 58)

      assert [{"verify", 57, 10}] == sites(deliver2)

      assert %{
               "caller" => %{"name" => "admit", "arity" => 1},
               "clauses" => [%{"line" => 61, "end_line" => 61}]
             } = admit1 = run_sites!("accounts.ex", 61)

      assert [{"verify", 60, 30}] == sites(admit1)
    end
  end

  describe "ordinary call shapes" do
    test "pipe targets and a private helper" do
      for line <- [10, 12] do
        assert %{"caller" => %{"name" => "update", "arity" => 2}} =
                 result = run_sites!("accounts.ex", line)

        assert [{"changeset", 11, 13}, {"save_and_clear", 12, 7}] == sites(result)
      end
    end

    test "a remote call and a local capture on one line" do
      assert %{"caller" => %{"name" => "normalize_all", "arity" => 1}} =
               result = run_sites!("accounts.ex", 16)

      assert [{"map", 16, 9}, {"normalize", 16, 22}] == sites(result)
    end

    test "a private caller of generated repo functions" do
      assert %{
               "caller" => %{
                 "module" => "Shop.Accounts",
                 "name" => "save_and_clear",
                 "arity" => 1
               },
               "clauses" => [%{"line" => 47, "end_line" => 51}]
             } = result = run_sites!("accounts.ex", 47)

      assert [{"insert!", 47, 15}, {"delete!", 48, 9}] == sites(result)
    end

    test "string interpolation keeps its calls and adds no parser-generated to_string" do
      text = ~S'''
      defmodule Demo do
        def label(x), do: "value: #{String.trim(x)}"
        def plain(x), do: Kernel.to_string(x)
      end
      '''

      assert {stdout, 0} = run_sites(text, 2)
      assert [{"trim", 1, 37}] == sites(JSON.decode!(stdout))
      # A to_string written in source is still a call.
      assert {stdout, 0} = run_sites(text, 3)
      assert [{"to_string", 2, 27}] == sites(JSON.decode!(stdout))
    end

    test "a function without calls has an empty site list" do
      assert %{
               "caller" => %{"name" => "version", "arity" => 0},
               "clauses" => [%{"line" => 45, "end_line" => 45}],
               "sites" => []
             } = run_sites!("accounts.ex", 45)
    end

    test "a helper in an ExUnit module keeps Kernel calls and skips the anonymous call" do
      assert %{
               "caller" => %{
                 "module" => "Shop.AccountsTest",
                 "name" => "synchronized_write",
                 "arity" => 2
               },
               "clauses" => [%{"line" => 10, "end_line" => 16}]
             } = result = run_sites!("accounts_test.exs", 10)

      assert [{"one", 10, 15}, {"send", 11, 4}, {"self", 11, 26}, {"await", 12, 4}] ==
               sites(result)
    end
  end

  describe "positions" do
    test "characters are UTF-16 code units, not bytes, codepoints or graphemes" do
      assert [{"build", 2, 30}] == sites(run_sites!("unicode.ex", 3))
      # 👩‍👩‍👧 is one grapheme, five codepoints and eight UTF-16 units.
      assert [{"foo", 6, 20}] == sites(run_sites!("unicode.ex", 7))
      assert [{"bar", 10, 14}] == sites(run_sites!("unicode.ex", 11))
    end
  end

  describe "failures" do
    test "a parse error, a line outside any def and a line shared by two functions fail without output" do
      failing = [
        {source("broken.ex"), 2},
        {source("accounts.ex"), 2},
        {source("accounts.ex"), 19},
        {"defmodule Shop.Twice do\n  def a, do: 1; def b, do: 2\nend\n", 2}
      ]

      for {text, line} <- failing do
        assert {"", 1} == run_sites(text, line), "line #{line} of #{inspect(text)}"
      end
    end

    test "the source is parsed, never evaluated" do
      marker = Path.join(@inputs, "evaluated")

      text = """
      defmodule Shop.Danger do
        File.write!(#{inspect(marker)}, "module body ran")
        def run, do: System.halt(7)
      end
      """

      assert {stdout, 0} = run_sites(text, 3)
      assert [{"halt", 2, 22}] == sites(JSON.decode!(stdout))
      refute File.exists?(marker)
    end
  end

  # Fixtures are stored as .txt so no index reads them.
  defp source(name), do: File.read!(Path.join(@fixtures, name <> ".txt"))

  # Pipes {source, line} to `elixir sites.exs` and requires one JSON document back.
  defp run_sites!(name, line) do
    {stdout, status} = run_sites(source(name), line)
    assert status == 0, "sites.exs exited #{status}, stdout: #{inspect(stdout)}"
    JSON.decode!(stdout)
  end

  defp run_sites(source, line) do
    input = Path.join(@inputs, "#{System.unique_integer([:positive])}.json")
    File.write!(input, JSON.encode!(%{"source" => source, "line" => line}))
    System.cmd("python3", [@runner, input, "elixir", @helper])
  end

  # Sites as {name, zero-based line, UTF-16 character} in source order. Each range must
  # cover exactly the name on one line.
  defp sites(%{"sites" => sites}) do
    for %{"name" => name, "range" => %{"start" => start, "end" => finish}} <- sites do
      assert %{"line" => line, "character" => character} = start
      assert finish == %{"line" => line, "character" => character + utf16_length(name)}
      {name, line, character}
    end
    |> Enum.sort_by(fn {_name, line, character} -> {line, character} end)
  end

  defp utf16_length(text),
    do: text |> :unicode.characters_to_binary(:utf8, :utf16) |> byte_size() |> div(2)
end
