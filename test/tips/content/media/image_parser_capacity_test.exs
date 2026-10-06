defmodule Tips.Content.Media.ImageParserCapacityTest do
  # The parser slots are shared by the whole application, so no other test may hold one.
  use ExUnit.Case, async: false

  alias Tips.Content.Media.ImageParser

  @moduletag :tmp_dir

  test "a cancelled caller keeps its slot until its parser exits", %{tmp_dir: dir} do
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

    slow = parser.("slow", "touch #{dir}/$$.started; sleep 1; touch #{dir}/$$.done\n")
    size = :tips |> Application.fetch_env!(ImageParser) |> Keyword.fetch!(:size)
    callers = for _ <- 1..size, do: spawn(fn -> ImageParser.classify(image, python: slow) end)
    wait_until(fn -> length(Path.wildcard("#{dir}/*.started")) == size end)
    Enum.each(callers, &Process.exit(&1, :kill))

    assert {:error, :unsupported} = ImageParser.classify(image, python: parser.("fast", ""))
    assert length(Path.wildcard("#{dir}/*.done")) == size
  end

  defp wait_until(fun) do
    unless fun.() do
      Process.sleep(10)
      wait_until(fun)
    end
  end
end
