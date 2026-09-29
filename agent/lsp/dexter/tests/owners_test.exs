# Acceptance tests for the incoming-calls ownership parser, through its CLI.
# Run: elixir agent/lsp/dexter/tests/owners_test.exs
ExUnit.start()

defmodule OwnersAcceptanceTest do
  use ExUnit.Case, async: true

  @helper Path.expand("../owners.exs", __DIR__)
  @runner Path.join(__DIR__, "stdin_runner.py")
  @fixtures Path.join(__DIR__, "fixtures/owners")
  @inputs Path.join(
            System.tmp_dir!(),
            "dx-owners-test-#{System.pid()}-#{System.unique_integer([:positive])}"
          )

  setup_all do
    File.mkdir_p!(@inputs)
    on_exit(fn -> File.rm_rf!(@inputs) end)
  end

  @admit %{"module" => "MyApp.Admission", "function" => "admit"}

  describe "four-call fixture" do
    test "test and setup bodies own their calls, including after a closed helper" do
      result =
        run_owners!("four_call", [
          fixture("four_call/a_test.exs", [5]),
          fixture("four_call/b_test.exs", [9, 13]),
          fixture("four_call/c_test.exs", [5])
        ])

      assert %{"unavailable" => []} = result

      assert %{
               {"a_test.exs", 5} => %{
                 "kind" => "test",
                 "module" => "MyApp.ATest",
                 "name" => "a1",
                 "line" => 4,
                 "end_line" => 6
               },
               {"b_test.exs", 9} => %{
                 "kind" => "test",
                 "module" => "MyApp.BTest",
                 "name" => "b1",
                 "line" => 8,
                 "end_line" => 10
               },
               {"b_test.exs", 13} => %{
                 "kind" => "setup",
                 "module" => "MyApp.BTest",
                 "line" => 12,
                 "end_line" => 15
               },
               {"c_test.exs", 5} => %{
                 "kind" => "test",
                 "module" => "MyApp.CTest",
                 "name" => "c1",
                 "line" => 4,
                 "end_line" => 6
               }
             } = owners(result)
    end
  end

  describe "supported shapes" do
    test "ordinary functions with inline ends, guards and keyword do" do
      lines = [5, 8, 12, 16, 20, 26, 30, 33, 35, 38]
      result = run_owners!("functions", [fixture("functions.ex", lines)])

      assert %{"unavailable" => []} = result

      assert %{
               {"functions.ex", 5} => %{"name" => "check", "line" => 4, "end_line" => 6},
               {"functions.ex", 8} => %{"name" => "quick", "line" => 8},
               {"functions.ex", 12} => %{"name" => "guarded", "line" => 10},
               {"functions.ex", 16} => %{"name" => "spread", "line" => 14},
               {"functions.ex", 20} => %{
                 "name" => "guarded_block",
                 "line" => 18,
                 "end_line" => 21
               },
               {"functions.ex", 26} => %{"name" => "multi", "line" => 25, "end_line" => 27},
               {"functions.ex", 30} => %{"kind" => "defp", "name" => "private", "line" => 29},
               {"functions.ex", 33} => %{"name" => "one_line", "line" => 33, "end_line" => 33},
               {"functions.ex", 35} => %{
                 "name" => "after_one_line",
                 "line" => 34,
                 "end_line" => 36
               },
               {"functions.ex", 38} => %{"name" => "twice", "line" => 38}
             } = owners = owners(result)

      for {{_file, line}, owner} <- owners, line != 30 do
        assert %{
                 "kind" => "def",
                 "module" => "MyApp.Gate",
                 "arity" => 1,
                 "arity_ambiguous" => false
               } =
                 owner
      end
    end

    test "ExUnit tests with inline ends, keyword do and a context argument" do
      result = run_owners!("shapes", [fixture("shapes_test.exs", [4, 6, 9, 13, 16])])

      assert %{"unavailable" => []} = result

      assert %{
               {"shapes_test.exs", 4} => %{"name" => "inline end", "line" => 4, "end_line" => 4},
               {"shapes_test.exs", 6} => %{
                 "name" => "after inline end",
                 "line" => 5,
                 "end_line" => 7
               },
               {"shapes_test.exs", 9} => %{"name" => "keyword do", "line" => 9},
               {"shapes_test.exs", 13} => %{"name" => "keyword do spread", "line" => 11},
               {"shapes_test.exs", 16} => %{
                 "name" => "with context",
                 "line" => 15,
                 "end_line" => 17
               }
             } = owners = owners(result)

      for {_site, owner} <- owners do
        assert %{"kind" => "test", "module" => "MyApp.ShapesTest"} = owner
      end
    end

    test "describe, control flow and fn are transparent; a second module keeps its own owners" do
      result = run_owners!("nested", [fixture("nested_test.exs", [2, 9, 15, 21, 22, 29, 35])])

      assert %{"unavailable" => []} = result

      assert %{
               {"nested_test.exs", 2} => %{
                 "kind" => "def",
                 "module" => "MyApp.GateHelper",
                 "name" => "build",
                 "arity" => 1
               },
               {"nested_test.exs", 9} => %{
                 "kind" => "setup_all",
                 "module" => "MyApp.NestedTest",
                 "line" => 8,
                 "end_line" => 11
               },
               {"nested_test.exs", 15} => %{
                 "kind" => "setup",
                 "module" => "MyApp.NestedTest",
                 "line" => 14,
                 "end_line" => 17
               },
               {"nested_test.exs", 21} => %{
                 "kind" => "test",
                 "module" => "MyApp.NestedTest",
                 "name" => "control flow",
                 "line" => 19,
                 "end_line" => 25
               },
               {"nested_test.exs", 22} => %{
                 "kind" => "test",
                 "module" => "MyApp.NestedTest",
                 "name" => "control flow",
                 "line" => 19,
                 "end_line" => 25
               },
               {"nested_test.exs", 29} => %{
                 "kind" => "test",
                 "module" => "MyApp.NestedTest",
                 "name" => "with and fn",
                 "line" => 27,
                 "end_line" => 31
               },
               {"nested_test.exs", 35} => %{
                 "kind" => "test",
                 "module" => "MyApp.NestedTest",
                 "name" => "after describe",
                 "line" => 34,
                 "end_line" => 36
               }
             } = owners(result)
    end

    test "nested modules take the outer prefix, Elixir. names are absolute, the outer resumes" do
      result = run_owners!("modules", [fixture("modules.ex", [3, 7, 10])])

      assert %{"unavailable" => []} = result

      assert %{
               {"modules.ex", 3} => %{"module" => "MyApp.Outer.Inner", "name" => "run"},
               {"modules.ex", 7} => %{"module" => "MyApp.Absolute", "name" => "run"},
               {"modules.ex", 10} => %{"module" => "MyApp.Outer", "name" => "after_nested"}
             } = owners(result)
    end

    test "default arguments report the maximum arity and are marked ambiguous" do
      result = run_owners!("defaults", [fixture("functions.ex", [41])])

      assert %{
               {"functions.ex", 41} => %{
                 "kind" => "def",
                 "name" => "with_default",
                 "arity" => 2,
                 "arity_ambiguous" => true
               }
             } = owners(result)
    end
  end

  describe "explicit unavailable outcomes" do
    test "captures, quote, typespecs, mixed call/capture and two owners on one line" do
      result = run_owners!("rejects", [fixture("rejects.ex", [4, 5, 8, 12, 17, 21, 23, 25])])

      assert %{{"rejects.ex", 25} => %{"kind" => "def", "name" => "genuine"}} = owners(result)

      assert [4, 5, 8, 12, 17, 21, 23] == unavailable_lines(result, "rejects.ex")
    end

    test "a parse error makes every line of that file unavailable without sinking the batch" do
      result =
        run_owners!("broken", [
          fixture("broken.ex", [3, 7]),
          fixture("four_call/a_test.exs", [5])
        ])

      assert %{{"a_test.exs", 5} => %{"kind" => "test", "name" => "a1"}} = owners(result)
      assert [3, 7] == unavailable_lines(result, "broken.ex")
    end

    test "module body, script top level and dynamic identities are unavailable, without evaluation" do
      result = run_owners!("body", [fixture("body.exs", [1, 6, 8, 9, 19, 27, 32])])

      assert %{
               {"body.exs", 6} => %{
                 "kind" => "def",
                 "module" => "MyApp.Body",
                 "name" => "first",
                 "arity" => 0
               }
             } = owners(result)

      assert [1, 8, 9, 19, 27, 32] == unavailable_lines(result, "body.exs")
    end
  end

  # Fixtures are stored as .txt so no index reads them; the helper sees the source label.
  defp fixture(relative, lines) do
    path = Path.join(@fixtures, relative)
    %{"path" => path, "source" => File.read!(path <> ".txt"), "lines" => lines}
  end

  # Pipes one JSON document to `elixir owners.exs` and requires one JSON document back.
  # Every input file+line comes back exactly once: as a resolved call site, or as
  # unavailable with a reason.
  defp run_owners!(name, files) do
    input = Path.join(@inputs, "#{name}.json")
    File.write!(input, JSON.encode!(%{"target" => @admit, "files" => files}))

    {stdout, status} = System.cmd("python3", [@runner, input, "elixir", @helper])
    assert status == 0, "owners.exs exited #{status}, stdout: #{inspect(stdout)}"

    result = JSON.decode!(stdout)
    assert %{"sites" => sites, "unavailable" => unavailable} = result

    expected = for %{"path" => path, "lines" => lines} <- files, line <- lines, do: {path, line}
    returned = for %{"path" => path, "line" => line} <- sites ++ unavailable, do: {path, line}
    assert Enum.sort(returned) == Enum.sort(expected)

    for site <- sites do
      assert %{
               "status" => "resolved",
               "kind" => "call",
               "owner" => %{"line" => first, "end_line" => last}
             } =
               site

      assert first <= site["line"] and site["line"] <= last
    end

    for entry <- unavailable, do: assert(%{"reason" => <<_, _::binary>>} = entry)

    result
  end

  # Resolved call owners keyed by {file basename, line}.
  defp owners(%{"sites" => sites}) do
    Map.new(sites, fn %{"path" => path, "line" => line, "owner" => owner} ->
      {{Path.basename(path), line}, owner}
    end)
  end

  defp unavailable_lines(%{"unavailable" => entries}, basename) do
    for %{"path" => path, "line" => line} <- entries, Path.basename(path) == basename do
      line
    end
    |> Enum.sort()
  end
end
