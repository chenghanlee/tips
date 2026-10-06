# Disposable image-parser probe for issue #244. Run through scripts/image_parser_probe.sh,
# which runs this file inside the probe container. Writes fixtures, then the fixture
# manifest, then classifies each fixture and runs the enforcement experiments.

defmodule ParserProbe.Child do
  @moduledoc false
  # The command #62 would run. `timeout` kills the parser at the wall deadline even
  # if the caller dies; `prlimit` caps its address space. prlimit execs Python, so
  # timeout's direct child is the parser itself.
  @python "/opt/parser/venv/bin/python"
  @script Path.expand("classify.py", __DIR__)

  def limits, do: %{deadline_s: 5, address_space_bytes: 1_073_741_824}

  def argv(path, limits) do
    ["--signal=KILL", Float.to_string(limits.deadline_s / 1), "prlimit"] ++
      ["--as=#{limits.address_space_bytes}", "--", @python, "-I", @script, path]
  end

  def run(path, limits \\ limits()) do
    started = System.monotonic_time(:microsecond)
    {out, status} = System.cmd("timeout", argv(path, limits))
    elapsed_ms = (System.monotonic_time(:microsecond) - started) / 1000

    result =
      case {status, String.split(out, "\n", trim: true)} do
        {0, [line]} -> JSON.decode!(line)
        {137, _} -> %{"verdict" => "reject", "reason" => "deadline"}
        {_, _} -> %{"verdict" => "reject", "reason" => "child_failed"}
      end

    Map.merge(result, %{"exit_status" => status, "elapsed_ms" => Float.round(elapsed_ms, 1)})
  end
end

defmodule ParserProbe.Png do
  @moduledoc false
  # Minimal PNG writer for fixtures libvips/ffmpeg cannot produce deterministically.

  def write(path, width, height, {color_type, depth}, row_fun, level \\ 9) do
    bytes_per_pixel = %{0 => 1, 2 => 3, 6 => 4}[color_type] * div(depth, 8)
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, level)

    idat =
      Enum.map(0..(height - 1), fn y ->
        :zlib.deflate(z, [0, row_fun.(y, width * bytes_per_pixel)])
      end)

    idat = IO.iodata_to_binary([idat, :zlib.deflate(z, [], :finish)])
    :zlib.close(z)

    ihdr = <<width::32, height::32, depth, color_type, 0, 0, 0>>
    File.write!(path, [signature(), chunk("IHDR", ihdr), chunk("IDAT", idat), chunk("IEND", "")])
  end

  def signature, do: <<0x89, "PNG\r\n", 0x1A, "\n">>

  def chunk(type, data),
    do: <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>

  def chunks(<<0x89, "PNG\r\n", 0x1A, "\n", rest::binary>>), do: chunks(rest, [])

  defp chunks(<<>>, acc), do: Enum.reverse(acc)

  defp chunks(
         <<len::32, type::binary-size(4), data::binary-size(len), _crc::32, rest::binary>>,
         acc
       ),
       do: chunks(rest, [{type, data} | acc])

  def assemble(chunks),
    do: IO.iodata_to_binary([signature() | Enum.map(chunks, fn {t, d} -> chunk(t, d) end)])
end

defmodule ParserProbe.Fixtures do
  @moduledoc false
  alias ParserProbe.Png

  # Every fixture is built from a recorded recipe. Encoder output can differ across
  # tool versions; the manifest hashes identify this run's bytes.
  def build(dir) do
    p = &Path.join(dir, &1)
    src = "testsrc=size=64x48:rate=5:duration=1"

    ff = fn out, args ->
      {_, 0} =
        System.cmd("ffmpeg", ~w(-hide_banner -loglevel error -y -bitexact) ++ args ++ [out])

      "ffmpeg 5.1 -bitexact " <> Enum.join(args, " ")
    end

    specs = [
      {"static.png", &ff.(&1, ["-f", "lavfi", "-i", src, "-frames:v", "1"]),
       accept("png", false)},
      {"animated.apng", &ff.(&1, ["-f", "lavfi", "-i", src, "-plays", "0", "-f", "apng"]),
       accept("png", true)},
      {"single-frame.apng", &first_apng_frame(p.("animated.apng"), &1), accept("png", false)},
      {"static.jpg", &ff.(&1, ["-f", "lavfi", "-i", src, "-frames:v", "1"]),
       accept("jpeg", false)},
      {"static.gif", &ff.(&1, ["-f", "lavfi", "-i", src, "-frames:v", "1"]),
       accept("gif", false)},
      {"animated.gif", &ff.(&1, ["-f", "lavfi", "-i", src, "-loop", "0"]), accept("gif", true)},
      {"static.webp", &cwebp(p.("static.png"), &1), accept("webp", false)},
      {"animated.webp", &img2webp(dir, src, 5, &1), accept("webp", true)},
      {"single-frame.webp", &img2webp(dir, src, 1, &1), accept("webp", false)},
      {"spoofed-jpeg-as.png", &copy(p.("static.jpg"), &1), accept("jpeg", false)},
      {"spoofed-text-as.gif", &write(&1, "GIF is not here, just text\n"),
       reject("unclassifiable")},
      {"svg-as.png",
       &write(&1, ~s(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>)),
       reject("unclassifiable")},
      {"bmp.bmp", &ff.(&1, ["-f", "lavfi", "-i", src, "-frames:v", "1"]),
       reject("unclassifiable")},
      {"tiff.tif", &ff.(&1, ["-f", "lavfi", "-i", src, "-frames:v", "1"]),
       reject("unclassifiable")},
      {"empty.png", &write(&1, ""), reject("unclassifiable")},
      {"random.bin", &write(&1, :crypto.hash(:sha512, "tips-244") |> :binary.copy(64)),
       reject("unclassifiable")},
      {"png-signature-garbage.png", &write(&1, Png.signature() <> :binary.copy(<<7>>, 512)),
       reject("malformed")},
      {"truncated.png", &truncate(p.("static.png"), &1), reject("malformed")},
      {"truncated.jpg", &truncate(p.("static.jpg"), &1), reject("malformed")},
      {"truncated.gif", &truncate(p.("animated.gif"), &1), reject("malformed")},
      {"truncated.webp", &truncate(p.("animated.webp"), &1), reject("malformed")},
      {"truncated.apng", &truncate(p.("animated.apng"), &1), reject("malformed")},
      {"corrupt-idat.png", &corrupt_idat(p.("static.png"), &1), reject("malformed")},
      {"png-crc-mismatch.png", &flip_idat_crc(p.("static.png"), &1), reject("malformed")},
      {"png-iend-missing.png", &drop_iend(p.("static.png"), &1), reject("malformed")},
      {"gif-trailer-missing.gif", &drop_gif_trailer(p.("animated.gif"), &1), reject("malformed")},
      # Spoofed motion metadata.
      {"apng-actl-overcount.png", &set_actl_frames(p.("animated.apng"), &1, +1),
       reject("malformed")},
      {"apng-actl-undercount.png", &set_actl_frames(p.("animated.apng"), &1, :one),
       reject("malformed")},
      {"apng-frame-outside-canvas.png", &shift_second_fctl(p.("animated.apng"), &1),
       reject("malformed")},
      {"webp-anim-flag-unset.webp", &clear_webp_anim_flag(p.("animated.webp"), &1),
       reject("malformed")},
      # A later frame far outside a small canvas: Pillow would grow the canvas to
      # 9064x9043 and allocate it on decode.
      {"gif-frame-outside-canvas.gif", &move_last_gif_frame(p.("animated.gif"), &1),
       reject("malformed")},
      # Resource bounds.
      {"huge-dimensions.png", &black_png(&1, 20_000, 20_000, {0, 8}),
       reject("dimensions_over_limit")},
      {"frame-pixels-over.png", &black_png(&1, 8000, 8000, {0, 8}),
       reject("frame_pixels_over_limit")},
      {"at-frame-pixel-limit-rgba.png", &black_png(&1, 8000, 5000, {6, 8}), accept("png", false)},
      {"at-frame-pixel-limit-rgba16.png", &black_png(&1, 8000, 5000, {6, 16}),
       accept("png", false)},
      # Two 40 MP frames: the largest decode the frame and total limits allow.
      {"at-frame-pixel-limit-2-frames.gif",
       &ff.(&1, ["-f", "lavfi", "-i", "testsrc2=size=8000x5000:rate=2:duration=1", "-loop", "0"]),
       accept("gif", true)},
      {"at-frame-pixel-limit-2-frames.webp",
       &img2webp(dir, "testsrc2=size=8000x5000:rate=2:duration=1", 2, &1), accept("webp", true)},
      {"many-frames.gif",
       &ff.(&1, ["-f", "lavfi", "-i", "color=c=red:size=16x16:rate=50:duration=20", "-loop", "0"]),
       reject("frames_over_limit")},
      {"at-total-pixel-limit.gif",
       &ff.(&1, ["-f", "lavfi", "-i", "testsrc2=size=2000x2000:rate=25:duration=1", "-loop", "0"]),
       accept("gif", true)},
      {"at-total-pixel-limit.webp",
       &img2webp(dir, "testsrc2=size=2000x2000:rate=25:duration=1", 25, &1),
       accept("webp", true)},
      {"at-total-pixel-limit-4-frames.webp",
       &img2webp(dir, "testsrc2=size=5000x5000:rate=4:duration=1", 4, &1), accept("webp", true)},
      {"total-pixels-over.gif",
       &ff.(&1, ["-f", "lavfi", "-i", "testsrc=size=2000x2000:rate=10:duration=3", "-loop", "0"]),
       reject("total_pixels_over_limit")},
      {"over-10mb.png", &stored_png(&1), reject("bytes_over_limit")}
    ]

    for {name, recipe, expected} <- specs do
      out = p.(name)
      how = recipe.(out)
      bytes = File.read!(out)

      %{
        name: name,
        path: out,
        recipe: how,
        bytes: byte_size(bytes),
        sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
        expected: List.wrap(expected)
      }
    end
  end

  defp accept(format, animated), do: %{verdict: "accept", format: format, animated: animated}
  defp reject(reason), do: %{verdict: "reject", reason: reason}

  defp write(out, data) do
    File.write!(out, data)
    "write #{byte_size(data)} fixed bytes"
  end

  defp copy(from, out) do
    File.cp!(from, out)
    "copy #{Path.basename(from)}"
  end

  defp truncate(from, out) do
    data = File.read!(from)
    File.write!(out, binary_part(data, 0, div(byte_size(data) * 6, 10)))
    "first 60% of #{Path.basename(from)}"
  end

  defp cwebp(from, out) do
    {_, 0} = System.cmd("cwebp", ["-quiet", "-lossless", from, "-o", out])
    "cwebp 1.2.4 -lossless #{Path.basename(from)}"
  end

  # img2webp from PNG frames extracted with ffmpeg.
  defp img2webp(dir, src, frames, out) do
    frames_dir = Path.join(dir, "frames-" <> Path.basename(out))
    File.mkdir_p!(frames_dir)
    pattern = Path.join(frames_dir, "%03d.png")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-hide_banner -loglevel error -y -bitexact -f lavfi -i) ++
          [src, "-frames:v", "#{frames}", pattern]
      )

    inputs = frames_dir |> File.ls!() |> Enum.sort() |> Enum.map(&Path.join(frames_dir, &1))

    {_, 0} =
      System.cmd(
        "img2webp",
        ["-loop", "0", "-lossy", "-q", "50", "-d", "200"] ++ inputs ++ ["-o", out]
      )

    File.rm_rf!(frames_dir)
    "img2webp 1.2.4 -lossy -q 50 of #{frames} ffmpeg frames from #{src}"
  end

  # Invert one byte inside the first IDAT payload; its CRC no longer matches.
  defp corrupt_idat(from, out) do
    data = File.read!(from)
    {pos, _} = :binary.match(data, "IDAT")
    at = pos + 4 + 10
    <<pre::binary-size(^at), b, post::binary>> = data
    File.write!(out, <<pre::binary, Bitwise.bxor(b, 0xFF), post::binary>>)
    "#{Path.basename(from)} with byte #{at} inverted inside IDAT"
  end

  # Rewrite acTL num_frames with a valid CRC.
  defp set_actl_frames(from, out, change) do
    chunks =
      from
      |> File.read!()
      |> Png.chunks()
      |> Enum.map(fn
        {"acTL", <<n::32, plays::32>>} ->
          n = if change == :one, do: 1, else: n + change
          {"acTL", <<n::32, plays::32>>}

        other ->
          other
      end)

    File.write!(out, Png.assemble(chunks))
    "#{Path.basename(from)} with acTL num_frames set #{inspect(change)}, CRC recomputed"
  end

  # Move the second fcTL frame so it extends past the canvas, with a valid CRC.
  defp shift_second_fctl(from, out) do
    {chunks, _} =
      from
      |> File.read!()
      |> Png.chunks()
      |> Enum.map_reduce(0, fn
        {"fcTL", <<seq::32, w::32, h::32, _x::32, y::32, rest::binary>>}, 1 ->
          {{"fcTL", <<seq::32, w::32, h::32, 32::32, y::32, rest::binary>>}, 2}

        {"fcTL", _} = c, n ->
          {c, n + 1}

        c, n ->
          {c, n}
      end)

    File.write!(out, Png.assemble(chunks))
    "#{Path.basename(from)} with second fcTL x_offset 32, CRC recomputed"
  end

  # VP8X flags byte: bit 1 marks animation.
  defp clear_webp_anim_flag(from, out) do
    data = File.read!(from)
    {pos, _} = :binary.match(data, "VP8X")
    at = pos + 8
    <<pre::binary-size(^at), flags, post::binary>> = data
    File.write!(out, <<pre::binary, Bitwise.band(flags, Bitwise.bnot(0x02)), post::binary>>)
    "#{Path.basename(from)} with the VP8X animation flag cleared"
  end

  # Flip one byte of the first IDAT chunk's CRC; the data is unchanged.
  defp flip_idat_crc(from, out) do
    data = File.read!(from)
    {pos, _} = :binary.match(data, "IDAT")
    <<len::32>> = binary_part(data, pos - 4, 4)
    at = pos + 4 + len
    <<pre::binary-size(^at), b, post::binary>> = data
    File.write!(out, <<pre::binary, Bitwise.bxor(b, 0xFF), post::binary>>)
    "#{Path.basename(from)} with IDAT CRC byte #{at} inverted"
  end

  defp drop_iend(from, out) do
    data = File.read!(from)
    size = byte_size(data) - 12
    <<body::binary-size(^size), 0::32, "IEND", _crc::32>> = data
    File.write!(out, body)
    "#{Path.basename(from)} without its final 12-byte IEND chunk"
  end

  # A genuine one-frame APNG: acTL num_frames 1, the first fcTL and the IDAT default
  # image; later fcTL and fdAT chunks are dropped.
  defp first_apng_frame(from, out) do
    {chunks, _} =
      from
      |> File.read!()
      |> Png.chunks()
      |> Enum.flat_map_reduce(0, fn
        {"acTL", <<_n::32, plays::32>>}, n -> {[{"acTL", <<1::32, plays::32>>}], n}
        {"fcTL", _} = c, 0 -> {[c], 1}
        {"fcTL", _}, n -> {[], n + 1}
        {"fdAT", _}, n -> {[], n}
        c, n -> {[c], n}
      end)

    File.write!(out, Png.assemble(chunks))
    "#{Path.basename(from)} reduced to acTL num_frames 1, its first fcTL and IDAT"
  end

  # Set the last image descriptor's left and top offsets to 9000.
  defp move_last_gif_frame(from, out) do
    data = File.read!(from)
    <<_header::binary-size(10), flags, _::binary>> = data
    at = last_gif_descriptor(data, 13 + color_table_size(flags), nil) + 1
    <<pre::binary-size(^at), _left::16, _top::16, post::binary>> = data
    File.write!(out, <<pre::binary, 9000::little-16, 9000::little-16, post::binary>>)
    "#{Path.basename(from)} with the last image descriptor's offsets set to 9000,9000"
  end

  defp last_gif_descriptor(data, pos, last) do
    case binary_part(data, pos, 1) do
      ";" ->
        last

      "!" ->
        last_gif_descriptor(data, skip_sub_blocks(data, pos + 2), last)

      "," ->
        flags = :binary.at(data, pos + 9)
        data_start = pos + 10 + color_table_size(flags) + 1
        last_gif_descriptor(data, skip_sub_blocks(data, data_start), pos)
    end
  end

  defp skip_sub_blocks(data, pos) do
    case :binary.at(data, pos) do
      0 -> pos + 1
      len -> skip_sub_blocks(data, pos + 1 + len)
    end
  end

  defp color_table_size(flags) when Bitwise.band(flags, 0x80) == 0, do: 0
  defp color_table_size(flags), do: 3 * Bitwise.bsl(2, Bitwise.band(flags, 7))

  defp drop_gif_trailer(from, out) do
    data = File.read!(from)
    size = byte_size(data) - 1
    <<body::binary-size(^size), 0x3B>> = data
    File.write!(out, body)
    "#{Path.basename(from)} without its final 0x3B trailer byte"
  end

  defp black_png(out, w, h, {color_type, depth} = format) do
    zero_row = fn _y, n -> :binary.copy(<<0>>, n) end
    ParserProbe.Png.write(out, w, h, format, zero_row)
    "Elixir PNG writer #{w}x#{h} color type #{color_type} depth #{depth}, zero rows, zlib level 9"
  end

  # 12,000,000 deterministic pseudo-random bytes stored without compression.
  defp stored_png(out) do
    row = fn y, n ->
      seed = :crypto.hash(:sha256, <<y::32>>)
      binary_part(:binary.copy(seed, div(n, 32) + 1), 0, n)
    end

    ParserProbe.Png.write(out, 2000, 2000, {2, 8}, row, 0)
    "Elixir PNG writer 2000x2000 RGB, rows of repeated SHA-256(row index), zlib level 0"
  end
end

defmodule ParserProbe do
  @moduledoc false
  alias ParserProbe.Child

  def main(dir) do
    fixtures_dir = Path.join(dir, "fixtures")
    File.rm_rf!(fixtures_dir)
    File.mkdir_p!(fixtures_dir)
    fixtures = ParserProbe.Fixtures.build(fixtures_dir)

    # Manifest before any classification.
    manifest = Enum.map(fixtures, &Map.take(&1, [:name, :recipe, :bytes, :sha256, :expected]))
    File.write!(Path.join(dir, "fixtures.json"), JSON.encode!(manifest))

    results =
      for fx <- fixtures do
        measured = Child.run(fx.path)
        pass = Enum.any?(fx.expected, &pass?(&1, measured))
        line(pass, fx.name, measured)
        Map.merge(%{fixture: fx.name, expected: fx.expected, pass: pass}, measured)
      end

    enforcement = enforcement(fixtures_dir)

    failed =
      for(r <- results, not r.pass, do: r.fixture) ++
        for(e <- enforcement, not e.pass, do: e.experiment)

    report = %{
      issue: 244,
      revision: System.get_env("PROBE_REVISION"),
      tracked_changes_at_launch: System.get_env("PROBE_TRACKED_CHANGES"),
      versions: versions(),
      limits: Child.limits(),
      results: results,
      enforcement: enforcement,
      failed: failed,
      verdict: if(failed == [], do: "pass", else: "fail")
    }

    File.write!(Path.join(dir, "report.json"), JSON.encode!(report))
    IO.puts("verdict: #{report.verdict}; failed=#{inspect(failed)}")
    if failed == [], do: 0, else: 1
  end

  defp pass?(%{verdict: "accept"} = e, %{"verdict" => "accept"} = m),
    do: m["format"] == e.format and m["animated"] == e.animated

  defp pass?(%{verdict: "reject", reason: r}, %{"verdict" => "reject", "reason" => r}), do: true

  # Invalid input may be reported as malformed or unclassifiable.
  defp pass?(%{verdict: "reject", reason: e}, %{"verdict" => "reject", "reason" => m})
       when e in ~w(malformed unclassifiable) and m in ~w(malformed unclassifiable),
       do: true

  defp pass?(_e, _m), do: false

  defp line(pass, name, m) do
    status = if pass, do: "pass", else: "FAIL"
    got = m["reason"] || "#{m["format"]} animated=#{m["animated"]} frames=#{m["frames"]}"

    IO.puts(
      "#{status} #{name}: #{m["verdict"]} #{got} #{m["elapsed_ms"]} ms rss=#{m["peak_rss_kib"]} KiB"
    )
  end

  # Each experiment tightens one ceiling below what a legitimate at-limit fixture
  # needs, so the ceiling, not the parser's own checks, must stop the work.
  defp enforcement(dir) do
    slow = Path.join(dir, "at-total-pixel-limit.gif")
    big = Path.join(dir, "at-frame-pixel-limit-2-frames.webp")

    [
      deadline_kills_parser(slow),
      address_space_stops_parser(big),
      parser_stops_without_caller(slow)
    ]
    |> tap(
      &Enum.each(&1, fn e ->
        IO.puts("#{if e.pass, do: "pass", else: "FAIL"} #{e.experiment}: #{e.observed}")
      end)
    )
  end

  defp deadline_kills_parser(path) do
    limits = %{Child.limits() | deadline_s: 0.2}
    m = Child.run(path, limits)
    left = parsers_running()

    %{
      experiment: "deadline_kills_parser",
      fixture: Path.basename(path),
      limits: limits,
      observed: "exit #{m["exit_status"]} after #{m["elapsed_ms"]} ms; parsers left: #{left}",
      pass: m["reason"] == "deadline" and m["elapsed_ms"] < 400 and left == 0
    }
  end

  defp address_space_stops_parser(path) do
    limits = %{Child.limits() | address_space_bytes: 512 * 1024 * 1024}
    m = Child.run(path, limits)

    %{
      experiment: "address_space_stops_parser",
      fixture: Path.basename(path),
      limits: limits,
      observed: "#{m["verdict"]} #{m["reason"]} exit #{m["exit_status"]}",
      pass:
        m["verdict"] == "reject" and m["reason"] in ["memory_limit", "malformed", "child_failed"]
    }
  end

  # The caller is killed right after starting the parser. `timeout` still ends the
  # parser at the deadline, so no work continues past it.
  defp parser_stops_without_caller(path) do
    deadline_s = 0.5
    argv = Child.argv(path, %{Child.limits() | deadline_s: deadline_s})
    cmd = Enum.map_join(["timeout" | argv], " ", &shell_quote/1)

    # sh starts the command in the background, prints its pid, and is then killed.
    {out, 0} = System.cmd("sh", ["-c", "#{cmd} >/dev/null 2>&1 & echo $!"])
    timeout_pid = String.trim(out)
    Process.sleep(100)
    running_early = parsers_running()
    Process.sleep(round(deadline_s * 1000) + 300)
    left = parsers_running()

    %{
      experiment: "parser_stops_without_caller",
      fixture: Path.basename(path),
      limits: %{deadline_s: deadline_s},
      observed:
        "caller exited at once (timeout pid #{timeout_pid}); parsers at 100 ms: #{running_early}; after deadline + 300 ms: #{left}",
      pass: running_early == 1 and left == 0
    }
  end

  defp parsers_running do
    # Match the parser process only, not the `timeout` process whose argv names it.
    case System.cmd("pgrep", ["-f", "^/opt/parser/venv/bin/python -I .*classify.py"]) do
      {out, 0} -> out |> String.split("\n", trim: true) |> length()
      {_, 1} -> 0
    end
  end

  defp shell_quote(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"

  defp versions do
    {py, 0} =
      System.cmd("/opt/parser/venv/bin/python", [
        "-I",
        "-c",
        "import sys, PIL.features as f; print(sys.version.split()[0], f.version('pil'), f.version('webp'), f.version('jpg'), f.version('zlib'))"
      ])

    [python, pillow, webp, jpeg, zlib] = String.split(py)
    {os, 0} = System.cmd("sh", ["-c", "uname -sm; . /etc/os-release; echo $PRETTY_NAME"])

    %{
      python: python,
      pillow: pillow,
      pillow_libwebp: webp,
      pillow_libjpeg: jpeg,
      pillow_zlib: zlib,
      elixir: System.version(),
      otp: System.otp_release(),
      os: os |> String.split("\n", trim: true) |> Enum.join("; ")
    }
  end
end

[dir] = System.argv()
System.halt(ParserProbe.main(dir))
