defmodule Tips.Content.Media.ImageParserCapacityTest do
  # The parser slots are shared by the whole application, so no other test may hold one.
  use ExUnit.Case, async: false

  alias Tips.Content.Media.ImageParser

  @moduletag :tmp_dir

  test "a cancelled caller holds a running parser slot and never starts a queued parser", %{
    tmp_dir: dir
  } do
    image = Path.join(dir, "image.png")
    File.write!(image, "")

    # Stand in for Python. The slow parser records its start and end.
    parser = fn name, body ->
      path = Path.join(dir, name)

      File.write!(
        path,
        "#!/bin/sh\n#{body}echo '{\"verdict\": \"reject\", \"reason\": \"unclassifiable\"}'\n"
      )

      File.chmod!(path, 0o755)
      path
    end

    slow = parser.("slow", "touch \"#{dir}/$$.started\"; sleep 1; touch \"#{dir}/$$.done\"\n")
    size = :tips |> Application.fetch_env!(ImageParser) |> Keyword.fetch!(:size)
    running = for _ <- 1..size, do: spawn(fn -> ImageParser.classify(image, python: slow) end)
    wait_until(fn -> length(Path.wildcard("#{dir}/*.started")) == size end)
    queued = spawn(fn -> ImageParser.classify(image, python: slow) end)

    wait_until(fn ->
      length(Task.Supervisor.children(Tips.Content.Media.ParserTasks)) == size + 1
    end)

    Enum.each([queued | running], &Process.exit(&1, :kill))

    assert {:error, :unsupported} = ImageParser.classify(image, python: parser.("fast", ""))
    assert length(Path.wildcard("#{dir}/*.done")) == size
    assert length(Path.wildcard("#{dir}/*.started")) == size
  end

  defp wait_until(fun) do
    unless fun.() do
      Process.sleep(10)
      wait_until(fun)
    end
  end
end
