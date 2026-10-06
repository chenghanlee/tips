defmodule Tips.Content.Media.ImageParserTest do
  use ExUnit.Case, async: true

  alias Tips.Content.Media.ImageParser

  @fixtures Path.expand("../../../fixtures/images", __DIR__)

  defp fixture(name), do: Path.join(@fixtures, name)

  test "classifies each format and its motion from content" do
    for {name, format, animated} <- [
          {"static.png", :png, false},
          {"animated.png", :png, true},
          {"static.jpg", :jpeg, false},
          {"static.gif", :gif, false},
          {"animated.gif", :gif, true},
          {"static.webp", :webp, false},
          {"animated.webp", :webp, true}
        ] do
      assert {:ok, %{format: ^format, animated: ^animated, width: 16, height: 12}} =
               ImageParser.classify(fixture(name)),
             name
    end
  end

  @tag :tmp_dir
  test "rejects other content, truncated files and oversized headers", %{tmp_dir: dir} do
    write = fn name, bytes -> dir |> Path.join(name) |> tap(&File.write!(&1, bytes)) end
    gif = File.read!(fixture("animated.gif"))
    jpeg_as_png = write.("photo.png", File.read!(fixture("static.jpg")))

    assert {:ok, %{format: :jpeg}} = ImageParser.classify(jpeg_as_png)
    assert {:error, :unsupported} = ImageParser.classify(write.("svg.png", "<svg/>"))
    assert {:error, :unsupported} = ImageParser.classify(write.("empty.png", ""))

    assert {:error, :invalid} =
             ImageParser.classify(write.("cut.gif", binary_part(gif, 0, div(byte_size(gif), 2))))

    assert {:error, :too_large} = ImageParser.classify(write.("wide.png", png_header(9000, 10)))

    assert {:error, :too_large} =
             ImageParser.classify(write.("big.png", :binary.copy("x", 10_000_001)))
  end

  test "the deadline kills the parser" do
    assert {:error, :invalid} = ImageParser.classify(fixture("static.png"), deadline_ms: 1)
  end

  @tag :tmp_dir
  @tag :linux
  test "the address-space ceiling stops a large decode", %{tmp_dir: dir} do
    # A 40 MP RGBA frame decodes to 160 MB.
    path = Path.join(dir, "large.png")
    File.write!(path, blank_png(8000, 5000))
    ceiling = 96 * 1024 * 1024

    assert {:ok, %{format: :png}} = ImageParser.classify(path)

    assert {:ok, %{format: :png}} =
             ImageParser.classify(fixture("static.png"), address_space: ceiling)

    assert {:error, :invalid} = ImageParser.classify(path, address_space: ceiling)
  end

  # A valid PNG whose header declares the given size; its pixel data is never read.
  defp png_header(width, height) do
    png([chunk("IHDR", <<width::32, height::32, 8, 2, 0, 0, 0>>), chunk("IEND", "")])
  end

  # An RGBA PNG of zeros, so a large frame stays small on disk.
  defp blank_png(width, height) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, 9)
    row = :binary.copy(<<0>>, width * 4 + 1)
    data = for(_ <- 1..height, do: :zlib.deflate(z, row)) ++ [:zlib.deflate(z, "", :finish)]
    :zlib.close(z)

    png([
      chunk("IHDR", <<width::32, height::32, 8, 6, 0, 0, 0>>),
      chunk("IDAT", IO.iodata_to_binary(data)),
      chunk("IEND", "")
    ])
  end

  defp png(chunks), do: IO.iodata_to_binary([<<137, "PNG", 13, 10, 26, 10>> | chunks])

  defp chunk(type, body) do
    [<<byte_size(body)::32>>, type, body, <<:erlang.crc32([type, body])::32>>]
  end
end
