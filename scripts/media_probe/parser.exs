# Disposable parser-selection probe for issue #61 (parser_formats_bounds).
# Run through `bash scripts/media_probe.sh parser`. Candidate dependencies are pinned
# here with Mix.install so they stay out of mix.exs/mix.lock until one is selected.
Mix.install([{:vix, "== 0.41.0"}, {:jason, "== 1.4.5"}])

defmodule MediaProbe.Parser do
  @moduledoc false
  alias Vix.Vips.{Image, Operation}

  # Proposed #62 bounds. Checked before decoding (bytes, header dimensions, frames)
  # or enforced by the parent process (deadline). Memory is measured, not capped.
  @limits %{
    max_bytes: 10_000_000,
    max_side: 8192,
    max_frame_pixels: 40_000_000,
    max_frames: 300,
    max_total_pixels: 100_000_000,
    deadline_ms: 5_000
  }

  @formats %{png: "pngload", jpeg: "jpegload", webp: "webpload", gif: "gifload"}

  def limits, do: @limits

  # --- child: classify one file and print one JSON line ---------------------------

  def one("vix", path) do
    Vix.Vips.cache_set_max(0)
    started = System.monotonic_time(:microsecond)
    result = classify_vix(path)
    elapsed = System.monotonic_time(:microsecond) - started

    emit(
      Map.merge(result, %{
        elapsed_us: elapsed,
        vips_highwater_bytes: Vix.Vips.tracked_get_mem_highwater()
      })
    )
  end

  def one("ffprobe", path) do
    started = System.monotonic_time(:microsecond)
    result = classify_ffprobe(path)
    emit(Map.put(result, :elapsed_us, System.monotonic_time(:microsecond) - started))
  end

  defp emit(map), do: IO.puts("RESULT " <> Jason.encode!(map))

  def classify_vix(path) do
    with {:ok, size} <- size(path),
         bytes = File.read!(path),
         {:ok, format} <- sniff(bytes),
         {:ok, header} <- load(format, bytes, n: 1),
         {:ok, frames} <- frames(header),
         {:ok, w, h} <- page_size(header, frames),
         :ok <- bounds(w, h, frames),
         {:ok, all} <-
           load(format, bytes,
             n: -1,
             "fail-on": :VIPS_FAIL_ON_ERROR,
             access: :VIPS_ACCESS_SEQUENTIAL
           ),
         {:ok, _avg} <- decode(all) do
      %{
        verdict: "accept",
        format: format,
        animated: frames > 1,
        width: w,
        height: h,
        frames: frames,
        bytes: size
      }
    else
      {:reject, reason} -> %{verdict: "reject", reason: reason}
    end
  end

  defp size(path) do
    %{size: size} = File.stat!(path)
    if size <= @limits.max_bytes, do: {:ok, size}, else: {:reject, "bytes_over_limit"}
  end

  # Magic bytes choose one allowed loader; no other libvips loader ever sees the input.
  defp sniff(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>), do: {:ok, :png}
  defp sniff(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, :jpeg}
  defp sniff(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {:ok, :webp}
  defp sniff(<<"GIF8", v, "a", _::binary>>) when v in [?7, ?9], do: {:ok, :gif}
  defp sniff(_), do: {:reject, "unclassifiable"}

  # Vix 0.41.0 silently ignores unknown option names: `fail_on:` is dropped, while the
  # libvips name `"fail-on"` is applied. Probe runs with `fail_on:` accepted truncated files.
  defp load(format, bytes, opts) do
    opts = if format in [:png, :jpeg], do: Keyword.delete(opts, :n), else: opts

    result =
      case format do
        :png -> Operation.pngload_buffer(bytes, opts)
        :jpeg -> Operation.jpegload_buffer(bytes, opts)
        :webp -> Operation.webpload_buffer(bytes, opts)
        :gif -> Operation.gifload_buffer(bytes, opts)
      end

    case result do
      {:ok, {img, _flags}} -> check_loader(img, format)
      {:ok, img} -> check_loader(img, format)
      {:error, _} -> {:reject, "malformed"}
    end
  end

  defp check_loader(img, format) do
    loader = @formats[format]

    # Buffer loads report e.g. "pngload_buffer".
    case Image.header_value(img, "vips-loader") do
      {:ok, name} when name in [loader, loader <> "_buffer"] -> {:ok, img}
      _ -> {:reject, "loader_mismatch"}
    end
  end

  defp frames(img) do
    case Image.header_value(img, "n-pages") do
      {:ok, n} when is_integer(n) and n >= 1 -> {:ok, n}
      {:error, _} -> {:ok, 1}
      _ -> {:reject, "bad_frame_count"}
    end
  end

  defp page_size(img, _frames) do
    h =
      case Image.header_value(img, "page-height") do
        {:ok, ph} when is_integer(ph) and ph > 0 -> ph
        _ -> Image.height(img)
      end

    {:ok, Image.width(img), h}
  end

  defp bounds(w, h, frames) do
    cond do
      w > @limits.max_side or h > @limits.max_side -> {:reject, "dimensions_over_limit"}
      w * h > @limits.max_frame_pixels -> {:reject, "frame_pixels_over_limit"}
      frames > @limits.max_frames -> {:reject, "frames_over_limit"}
      w * h * frames > @limits.max_total_pixels -> {:reject, "total_pixels_over_limit"}
      true -> :ok
    end
  end

  # Averaging every pixel forces a full sequential decode, so truncation and corrupt
  # data fail here instead of being accepted from a valid header.
  defp decode(img) do
    case Operation.avg(img) do
      {:ok, avg} -> {:ok, avg}
      {:error, _} -> {:reject, "malformed"}
    end
  end

  # ffprobe decodes every frame (-count_frames); the same header bounds apply after.
  def classify_ffprobe(path) do
    args =
      ~w(-v error -count_frames -show_entries stream=codec_name,width,height,nb_read_frames -of json) ++
        [path]

    with {:ok, size} <- size(path),
         {out, 0} <- System.cmd("ffprobe", args),
         {:ok, %{"streams" => [s | _]}} <- Jason.decode(out),
         {:ok, format} <- ffprobe_format(s["codec_name"]),
         frames when is_integer(frames) and frames > 0 <- parse_int(s["nb_read_frames"]),
         w when is_integer(w) and w > 0 <- s["width"],
         :ok <- bounds(w, s["height"], frames) do
      %{
        verdict: "accept",
        format: format,
        animated: frames > 1,
        width: w,
        height: s["height"],
        frames: frames,
        bytes: size
      }
    else
      {:reject, reason} -> %{verdict: "reject", reason: reason}
      _ -> %{verdict: "reject", reason: "malformed"}
    end
  end

  defp ffprobe_format(codec) when codec in ~w(png apng), do: {:ok, :png}
  defp ffprobe_format("mjpeg"), do: {:ok, :jpeg}
  defp ffprobe_format("webp"), do: {:ok, :webp}
  defp ffprobe_format("gif"), do: {:ok, :gif}
  defp ffprobe_format(_), do: {:reject, "unclassifiable"}

  defp parse_int(nil), do: nil
  defp parse_int(v) when is_integer(v), do: v
  defp parse_int(v), do: v |> Integer.parse() |> elem(0)

  # --- parent: fixtures, measurement and report ------------------------------------

  def main(dir) do
    fixtures_dir = Path.join(dir, "fixtures")
    File.rm_rf!(fixtures_dir)
    File.mkdir_p!(fixtures_dir)
    fixtures = MediaProbe.Fixtures.build(fixtures_dir)

    results =
      for fx <- fixtures, candidate <- ~w(vix ffprobe) do
        measured = measure(candidate, fx.path)

        Map.merge(%{fixture: fx.name, candidate: candidate, expected: fx.expected}, measured)
        |> Map.put(:pass, pass?(fx.expected, measured))
      end

    candidates =
      for c <- ~w(vix ffprobe) do
        rows = Enum.filter(results, &(&1.candidate == c))
        failed = rows |> Enum.reject(& &1.pass) |> Enum.map(& &1.fixture)
        %{candidate: c, fixtures: length(rows), failed: failed, selectable: failed == []}
      end

    report = %{
      experiment: "parser_formats_bounds",
      retrieved: Date.utc_today() |> Date.to_iso8601(),
      versions: versions(),
      limits: @limits,
      memory_bound:
        "measured only: pre-decode pixel/frame budgets bound decode work; no OS memory cap is applied in this probe",
      fixtures: Enum.map(fixtures, &Map.take(&1, [:name, :recipe, :bytes, :sha256, :expected])),
      results: results,
      candidates: candidates,
      selected: Enum.find_value(candidates, fn c -> c.selectable && c.candidate end),
      verdict: if(Enum.any?(candidates, & &1.selectable), do: "pass", else: "blocked")
    }

    File.write!(Path.join(dir, "parser-report.json"), Jason.encode!(report, pretty: true))

    for c <- candidates do
      IO.puts(
        "#{c.candidate}: #{c.fixtures - length(c.failed)}/#{c.fixtures} fixtures pass; failed=#{inspect(c.failed)}"
      )
    end

    IO.puts(
      "parser_formats_bounds: #{report.verdict} (report #{Path.join(dir, "parser-report.json")})"
    )

    if report.verdict == "pass", do: 0, else: 1
  end

  defp pass?(%{verdict: "accept"} = e, %{verdict: "accept"} = m),
    do: m.animated == e.animated and to_string(m.format) == e.format

  # Invalid input may be reported as malformed or unclassifiable; bounds must match.
  defp pass?(%{verdict: "reject"} = e, %{verdict: "reject"} = m),
    do: reject_class(e.reason) == reject_class(m.reason)

  defp pass?(_e, _m), do: false

  defp reject_class(reason) when reason in ~w(malformed unclassifiable loader_mismatch),
    do: "invalid"

  defp reject_class(reason), do: reason

  # Each classification runs in a fresh OS process under /usr/bin/time so peak RSS
  # covers native allocations; the parent kills it at the deadline.
  defp measure(candidate, path) do
    script = __ENV__.file
    args = ["-l", "elixir", script, "--one", candidate, path]

    port =
      Port.open({:spawn_executable, "/usr/bin/time"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    deadline = @limits.deadline_ms + 10_000
    started = System.monotonic_time(:millisecond)
    collect(port, os_pid, "", started, deadline)
  end

  # The child's own elapsed_us times only the classification; the extra parent budget
  # covers BEAM startup and is not part of the enforced parse deadline.
  defp collect(port, os_pid, acc, started, deadline) do
    remaining = max(deadline - (System.monotonic_time(:millisecond) - started), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, os_pid, acc <> data, started, deadline)

      {^port, {:exit_status, status}} ->
        parse_child(acc, status)
    after
      remaining ->
        System.cmd("kill", ["-9", Integer.to_string(os_pid)])
        %{verdict: "reject", reason: "deadline", exit_status: :killed}
    end
  end

  defp parse_child(out, status) do
    rss =
      case Regex.run(~r/(\d+)\s+maximum resident set size/, out) do
        [_, n] -> String.to_integer(n)
        _ -> nil
      end

    base =
      case Regex.run(~r/^RESULT (.*)$/m, out) do
        [_, json] -> json |> Jason.decode!(keys: :atoms)
        _ -> %{verdict: "reject", reason: "child_crash"}
      end

    base
    |> Map.put(:peak_rss_bytes, rss)
    |> Map.put(:exit_status, status)
    |> then(fn m ->
      if m[:elapsed_us] && m.elapsed_us > @limits.deadline_ms * 1000,
        do: %{m | verdict: "reject"} |> Map.put(:reason, "deadline"),
        else: m
    end)
  end

  defp versions do
    {ff, 0} = System.cmd("ffprobe", ["-version"])

    %{
      elixir: System.version(),
      otp: System.otp_release(),
      vix: "0.41.0",
      libvips: Vix.Vips.version(),
      ffprobe: ff |> String.split("\n") |> hd(),
      os: :os.type() |> Tuple.to_list() |> Enum.join("/")
    }
  end
end

defmodule MediaProbe.Fixtures do
  @moduledoc false
  alias Vix.Vips.{Image, Operation}

  # Synthetic fixtures only. Recipes are recorded with hashes; encoder output can differ
  # across FFmpeg/libvips versions, so hashes identify this run's bytes, not a standard.
  def build(dir) do
    p = &Path.join(dir, &1)

    ff = fn out, args ->
      {_, 0} = System.cmd("ffmpeg", ~w(-hide_banner -loglevel error -y) ++ args ++ [out])
      "ffmpeg " <> Enum.join(args, " ")
    end

    src = "testsrc=size=64x48:rate=5:duration=1"

    specs = [
      {"static.png", fn o -> ff.(o, ["-f", "lavfi", "-i", src, "-frames:v", "1"]) end,
       accept("png", false)},
      {"animated.apng",
       fn o -> ff.(o, ["-f", "lavfi", "-i", src, "-plays", "0", "-f", "apng"]) end,
       accept("png", true)},
      {"single-frame.apng",
       fn o -> ff.(o, ["-f", "lavfi", "-i", src, "-frames:v", "1", "-f", "apng"]) end,
       accept("png", false)},
      {"static.jpg", fn o -> ff.(o, ["-f", "lavfi", "-i", src, "-frames:v", "1"]) end,
       accept("jpeg", false)},
      {"static.gif", fn o -> ff.(o, ["-f", "lavfi", "-i", src, "-frames:v", "1"]) end,
       accept("gif", false)},
      {"animated.gif", fn o -> ff.(o, ["-f", "lavfi", "-i", src, "-loop", "0"]) end,
       accept("gif", true)},
      {"static.webp", fn o -> vips_save(p.("static.png"), o, 1) end, accept("webp", false)},
      {"animated.webp", fn o -> vips_save(p.("animated.gif"), o, -1) end, accept("webp", true)},
      {"spoofed-jpeg-as.png", fn o -> copy(p.("static.jpg"), o) end, accept("jpeg", false)},
      {"spoofed-text-as.gif", fn o -> write(o, "GIF is not here, just text\n") end,
       reject("unclassifiable")},
      {"svg-as.png",
       fn o -> write(o, ~s(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>)) end,
       reject("unclassifiable")},
      {"bmp.bmp", fn o -> ff.(o, ["-f", "lavfi", "-i", src, "-frames:v", "1"]) end,
       reject("unclassifiable")},
      {"tiff.tif", fn o -> ff.(o, ["-f", "lavfi", "-i", src, "-frames:v", "1"]) end,
       reject("unclassifiable")},
      {"empty.png", fn o -> write(o, "") end, reject("unclassifiable")},
      {"random.bin", fn o -> write(o, :crypto.hash(:sha512, "tips-61") |> :binary.copy(64)) end,
       reject("unclassifiable")},
      {"png-signature-garbage.png",
       fn o -> write(o, <<0x89, "PNG\r\n", 0x1A, "\n">> <> :binary.copy(<<7>>, 512)) end,
       reject("malformed")},
      {"truncated.png", fn o -> truncate(p.("static.png"), o) end, reject("malformed")},
      {"truncated.jpg", fn o -> truncate(p.("static.jpg"), o) end, reject("malformed")},
      {"truncated.gif", fn o -> truncate(p.("animated.gif"), o) end, reject("malformed")},
      {"truncated.webp", fn o -> truncate(p.("animated.webp"), o) end, reject("malformed")},
      {"truncated.apng", fn o -> truncate(p.("animated.apng"), o) end, reject("malformed")},
      {"corrupt-idat.png", fn o -> corrupt(p.("static.png"), o) end, reject("malformed")},
      {"huge-dimensions.png", fn o -> vips_black(o, 20_000, 20_000) end,
       reject("dimensions_over_limit")},
      {"frame-pixels-over.png", fn o -> vips_black(o, 8000, 8000) end,
       reject("frame_pixels_over_limit")},
      {"at-pixel-budget.png", fn o -> vips_black(o, 6000, 6000) end, accept("png", false)},
      {"many-frames.gif",
       fn o ->
         ff.(o, ["-f", "lavfi", "-i", "color=c=red:size=16x16:rate=50:duration=20", "-loop", "0"])
       end, reject("frames_over_limit")},
      {"total-pixels-over.gif",
       fn o ->
         ff.(o, ["-f", "lavfi", "-i", "testsrc=size=2000x2000:rate=10:duration=3", "-loop", "0"])
       end, reject("total_pixels_over_limit")},
      {"over-10mb.png", fn o -> noise_png(o) end, reject("bytes_over_limit")}
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
        expected: expected
      }
    end
  end

  defp accept(format, animated), do: %{verdict: "accept", format: format, animated: animated}
  defp reject(reason), do: %{verdict: "reject", reason: reason}

  defp write(out, data) do
    File.write!(out, data)
    "write #{byte_size(data)} synthetic bytes"
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

  # Flip one byte in the middle of the first IDAT payload; the chunk CRC no longer matches.
  defp corrupt(from, out) do
    data = File.read!(from)
    {pos, _} = :binary.match(data, "IDAT")
    at = pos + 4 + 10
    <<pre::binary-size(at), b, post::binary>> = data
    File.write!(out, <<pre::binary, Bitwise.bxor(b, 0xFF), post::binary>>)
    "#{Path.basename(from)} with byte #{at} inverted inside IDAT"
  end

  defp vips_save(from, out, n) do
    {:ok, img} = Image.new_from_file(from, n: n)
    :ok = Image.write_to_file(img, out)
    "libvips #{Vix.Vips.version()} webpsave of #{Path.basename(from)} (n=#{n})"
  end

  defp vips_black(out, w, h) do
    {:ok, img} = Operation.black(w, h)
    :ok = Operation.pngsave(img, out, compression: 9)
    "libvips black #{w}x#{h} 1-band pngsave compression=9"
  end

  defp noise_png(out) do
    {:ok, img} = Operation.gaussnoise(2400, 2400, sigma: 60.0)
    {:ok, img} = Operation.cast(img, :VIPS_FORMAT_UCHAR)
    {:ok, img} = Operation.bandjoin([img, img, img])
    :ok = Operation.pngsave(img, out, compression: 0)
    "libvips gaussnoise 2400x2400 sigma=60 3-band pngsave compression=0 (seeded by libvips)"
  end
end

case System.argv() do
  ["--one", candidate, path] -> MediaProbe.Parser.one(candidate, path)
  [dir] -> System.halt(MediaProbe.Parser.main(dir))
end
