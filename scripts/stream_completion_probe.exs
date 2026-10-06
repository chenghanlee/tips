# Real-provider probe for #243: what Stream does with a tus PATCH that is still sending
# when the upload expiry passes, and which fields a completed upload carries.
# See docs/development/stream-completion-probe.md.
#
#     TIPS_REAL_PROVIDERS=1 mix run --no-start scripts/stream_completion_probe.exs run
#     TIPS_REAL_PROVIDERS=1 mix run --no-start scripts/stream_completion_probe.exs diagnose
#     TIPS_REAL_PROVIDERS=1 mix run --no-start scripts/stream_completion_probe.exs cleanup
#
# Every mode refuses a dirty checkout. `run` makes four reservations with one 10 s clip
# each and `diagnose` two; both delete them at the end. `cleanup` deletes every reservation named in tmp/ inventories or
# found by the `tips-probe-243-` name prefix. Output goes to tmp/stream-completion-probe/.
defmodule StreamCompletionProbe do
  @out "tmp/stream-completion-probe"
  @prefix "tips-probe-243-"
  # Stream's minimum non-final tus chunk; non-final chunks must also be 256 KiB multiples.
  @chunk 5_242_880
  @max_calls 120
  # The production envelope for server-side Stream API calls: create, status read, delete.
  @api_timeouts [receive_timeout: 5_000, connect_options: [timeout: 5_000]]
  # PATCH belongs to the browser's tus client; the probe only needs it to outlast the case.
  @patch_receive_timeout 180_000
  @expiry_s 130

  # Slow PATCH start and end, in seconds relative to uploadExpiry. `final` sends the rest
  # of the file; `nonfinal` sends one more 5 MiB chunk across expiry, then the rest at once.
  @cases [
    %{label: "before", start: -40, finish: -20, kind: :final},
    %{label: "span-10", start: -10, finish: 10, kind: :final},
    %{label: "span-60", start: -10, finish: 60, kind: :final},
    %{label: "nonfinal-span-10", start: -10, finish: 10, kind: :nonfinal}
  ]

  def main(["run"]), do: guard(fn -> report("run", &run/1) end)
  def main(["diagnose"]), do: guard(fn -> report("diagnose", &diagnose/1) end)
  def main(["cleanup"]), do: guard(fn -> report("cleanup", &cleanup/1) end)
  def main(_argv), do: refuse("usage: run | diagnose | cleanup")

  defp guard(fun) do
    {dirty, 0} = System.cmd("git", ["status", "--porcelain", "--untracked-files=no"])

    cond do
      System.get_env("TIPS_REAL_PROVIDERS") != "1" -> refuse("set TIPS_REAL_PROVIDERS=1")
      dirty != "" -> refuse("the checkout has tracked changes")
      true -> Application.ensure_all_started(:req) && fun.()
    end
  end

  defp refuse(message) do
    IO.puts(:stderr, "refused: " <> message)
    System.halt(2)
  end

  ## Run

  defp run(ctx) do
    fixture = fixture()
    data = File.read!(fixture.path)
    expiry = DateTime.utc_now() |> DateTime.add(@expiry_s) |> DateTime.truncate(:second)

    reservations =
      Enum.map(@cases, fn c -> {c, reserve(ctx, c.label, byte_size(data), expiry)} end)

    results =
      reservations
      |> Enum.map(fn {c, r} -> Task.async(fn -> run_case(ctx, c, r, data, expiry) end) end)
      |> Task.await_many(:timer.minutes(10))

    deleted = Enum.map(owned(reservations), &delete_confirmed(ctx, &1))
    assertions = assertions(results, deleted, expiry)

    %{
      fixture: Map.delete(fixture, :path),
      requested_expiry: DateTime.to_iso8601(expiry),
      cases: results,
      deleted: deleted,
      assertions: assertions,
      verdict: verdict(assertions)
    }
  end

  defp run_case(_ctx, c, {:error, record}, _data, _expiry),
    do: %{case: c.label, reservation: record}

  # A rejected first chunk means no unfinished transfer exists, so the case stops there.
  defp run_case(ctx, c, {:ok, r}, data, expiry) do
    first = patch(ctx, r, 0, binary_part(data, 0, @chunk), 0)
    {:ok, reserved} = video(ctx, r.uid)

    if acknowledged?(first, @chunk),
      do: span_case(ctx, c, r, data, expiry, first, reserved),
      else: %{
        case: c.label,
        uid: r.uid,
        first_chunk: first,
        reserved_video: observation(reserved)
      }
  end

  defp span_case(ctx, c, r, data, expiry, first, reserved) do
    sleep_until(expiry, c.start)

    {body_size, rest} =
      case c.kind do
        :final -> {byte_size(data) - @chunk, nil}
        :nonfinal -> {@chunk, 2 * @chunk}
      end

    spanning =
      patch(ctx, r, @chunk, binary_part(data, @chunk, body_size), (c.finish - c.start) * 1000)

    after_span = observe(ctx, r)

    tail =
      if rest && after_span.head_offset == rest,
        do: patch(ctx, r, rest, binary_part(data, rest, byte_size(data) - rest), 0)

    observations = poll(ctx, r, 24)

    %{
      case: c.label,
      planned: Map.take(c, [:start, :finish, :kind]),
      uid: r.uid,
      length: byte_size(data),
      reservation: r.record,
      reserved_video: observation(reserved),
      first_chunk: first,
      spanning_patch: spanning,
      after_spanning_patch: after_span,
      tail_patch: tail,
      observations: observations,
      final_video: last_video(ctx, r.uid)
    }
  end

  defp sleep_until(expiry, offset_s) do
    at = DateTime.add(expiry, offset_s)
    Process.sleep(max(DateTime.diff(at, DateTime.utc_now(), :millisecond), 0))
  end

  defp observe(ctx, r) do
    {head, _record} = head(ctx, r)
    {:ok, v} = video(ctx, r.uid)

    %{
      observed_at: now(),
      head_status: status(head),
      head_offset: header_int(head, "upload-offset"),
      video: observation(v)
    }
  end

  # Five-second polls until the video is ready or failed, or stays in pendingupload.
  defp poll(ctx, r, attempts) do
    Enum.reduce_while(1..attempts, [], fn n, seen ->
      {:ok, v} = video(ctx, r.uid)
      seen = [observation(v) | seen]
      state = get_in(v, ["status", "state"])

      if state in ["ready", "error"] or (state == "pendingupload" and n >= 3) do
        {:halt, Enum.reverse(seen)}
      else
        Process.sleep(5_000)
        {:cont, seen}
      end
    end)
  end

  defp last_video(ctx, uid) do
    case video(ctx, uid) do
      {:ok, v} -> v
      {:error, record} -> record
    end
  end

  defp observation(v) do
    %{
      observed_at: now(),
      state: get_in(v, ["status", "state"]),
      error: get_in(v, ["status", "errorReasonCode"]),
      uploaded: v["uploaded"],
      created: v["created"],
      modified: v["modified"],
      ready_to_stream_at: v["readyToStreamAt"],
      upload_expiry: v["uploadExpiry"],
      size: v["size"],
      duration: v["duration"]
    }
  end

  defp assertions(results, deleted, expiry) do
    by = Map.new(results, &{&1.case, &1})
    before = by["before"]

    [
      assertion(
        "first_chunks_acknowledged",
        true,
        Enum.all?(results, &acknowledged?(&1[:first_chunk], @chunk)),
        Map.new(
          results,
          &{&1.case, Map.take(&1[:first_chunk] || %{}, [:status, :headers, :body])}
        )
      ),
      assertion("before_finished_before_expiry", true, before?(before, :response_at, expiry), %{
        response_at: get_in(before, [:spanning_patch, :response_at]),
        expiry: DateTime.to_iso8601(expiry)
      }),
      assertion("before_expiry_completes", true, completed?(before), %{
        patch_status: get_in(before, [:spanning_patch, :status]),
        final_state: get_in(before, [:final_video, "status", "state"])
      }),
      assertion("uploaded_is_reservation_time", true, uploaded_before_first_byte?(before), %{
        uploaded: get_in(before, [:reserved_video, :uploaded]),
        first_chunk_sent_at: get_in(before, [:first_chunk, :sent_at])
      }),
      assertion(
        "completed_video_timestamps",
        false,
        :info,
        Map.take(
          before[:final_video] || %{},
          ~w(created uploaded modified readyToStreamAt uploadExpiry)
        )
      )
    ] ++
      Enum.flat_map(["span-10", "span-60", "nonfinal-span-10"], &span_assertions(by[&1], expiry)) ++
      [
        assertion(
          "every_reservation_deleted",
          true,
          Enum.all?(deleted, &(&1.get_after == 404)),
          %{
            deleted: deleted
          }
        )
      ]
  end

  # A case measures the boundary only if its PATCH started before expiry and was still
  # handing body bytes to the socket after it.
  defp span_assertions(result, expiry) do
    spans? =
      before?(result, :sent_at, expiry) and not before?(result, :body_done_at, expiry) and
        get_in(result, [:spanning_patch, :body_done_at]) != nil

    [
      assertion("#{result.case}_spans_expiry", true, spans?, %{
        sent_at: get_in(result, [:spanning_patch, :sent_at]),
        body_done_at: get_in(result, [:spanning_patch, :body_done_at]),
        expiry: DateTime.to_iso8601(expiry)
      }),
      span_outcome(result)
    ]
  end

  defp span_outcome(result) do
    assertion("#{result.case}_outcome", false, :info, %{
      patch_sent_at: get_in(result, [:spanning_patch, :sent_at]),
      body_done_at: get_in(result, [:spanning_patch, :body_done_at]),
      response_at: get_in(result, [:spanning_patch, :response_at]),
      status: get_in(result, [:spanning_patch, :status]),
      response_offset: get_in(result, [:spanning_patch, :headers, "upload-offset"]),
      head_offset_after: get_in(result, [:after_spanning_patch, :head_offset]),
      tail_status: get_in(result, [:tail_patch, :status]),
      final_state: get_in(result, [:final_video, "status", "state"]),
      completed: completed?(result)
    })
  end

  defp acknowledged?(%{status: 204, headers: %{"upload-offset" => offset}}, expected),
    do: offset == Integer.to_string(expected)

  defp acknowledged?(_record, _expected), do: false

  defp before?(result, key, expiry) do
    case get_in(result, [:spanning_patch, key]) do
      nil -> false
      at -> before_iso?(at, DateTime.to_iso8601(expiry))
    end
  end

  defp completed?(%{final_video: %{"status" => %{"state" => state}}}),
    do: state not in ["pendingupload"]

  defp completed?(_result), do: false

  defp uploaded_before_first_byte?(%{reserved_video: %{uploaded: uploaded}, first_chunk: first})
       when is_binary(uploaded),
       do: before_iso?(uploaded, first.sent_at)

  defp uploaded_before_first_byte?(_result), do: false

  defp before_iso?(a, b) do
    {:ok, a, _} = DateTime.from_iso8601(a)
    {:ok, b, _} = DateTime.from_iso8601(b)
    DateTime.before?(a, b)
  end

  ## Diagnose

  # Two uploads far from expiry: the rest of the file in one unthrottled PATCH, then the
  # same throttled over 20 s like the `before` control. The second runs only if the first
  # completes, so a plain-upload failure stops the probe.
  @diagnose_expiry_s 900

  defp diagnose(ctx) do
    fixture = fixture()
    data = File.read!(fixture.path)
    expiry = DateTime.utc_now() |> DateTime.add(@diagnose_expiry_s) |> DateTime.truncate(:second)

    reservations =
      Enum.map(["unthrottled", "throttled-20s"], &{&1, reserve(ctx, &1, byte_size(data), expiry)})

    [{_label, unthrottled}, {_label2, throttled}] = reservations
    first = diagnose_case(ctx, unthrottled, data, 0)

    second =
      if completed?(first),
        do: diagnose_case(ctx, throttled, data, 20_000),
        else: %{case: "throttled-20s", skipped: "unthrottled upload did not complete"}

    deleted = for {_label, {:ok, r}} <- reservations, do: delete_confirmed(ctx, r.uid)

    assertions = [
      assertion("unthrottled_completes", true, completed?(first), diagnose_evidence(first)),
      assertion("throttled_completes", true, completed?(second), diagnose_evidence(second)),
      assertion("every_reservation_deleted", true, Enum.all?(deleted, &(&1.get_after == 404)), %{
        deleted: deleted
      })
    ]

    %{
      fixture: Map.delete(fixture, :path),
      requested_expiry: DateTime.to_iso8601(expiry),
      cases: [first, second],
      deleted: deleted,
      assertions: assertions,
      verdict: verdict(assertions)
    }
  end

  defp diagnose_case(_ctx, {:error, record}, _data, _duration_ms),
    do: %{case: "reservation", reservation: record}

  defp diagnose_case(ctx, {:ok, r}, data, duration_ms) do
    first = patch(ctx, r, 0, binary_part(data, 0, @chunk), 0)

    if acknowledged?(first, @chunk) do
      rest =
        patch(ctx, r, @chunk, binary_part(data, @chunk, byte_size(data) - @chunk), duration_ms)

      %{
        case: r.label,
        uid: r.uid,
        first_chunk: first,
        spanning_patch: rest,
        after_spanning_patch: observe(ctx, r),
        observations: poll(ctx, r, 24),
        final_video: last_video(ctx, r.uid)
      }
    else
      %{case: r.label, uid: r.uid, first_chunk: first}
    end
  end

  defp diagnose_evidence(result) do
    %{
      first_chunk_status: get_in(result, [:first_chunk, :status]),
      rest_status: get_in(result, [:spanning_patch, :status]),
      rest_sent_at: get_in(result, [:spanning_patch, :sent_at]),
      rest_body_done_at: get_in(result, [:spanning_patch, :body_done_at]),
      rest_response_at: get_in(result, [:spanning_patch, :response_at]),
      rest_body: get_in(result, [:spanning_patch, :body]),
      head_offset_after: get_in(result, [:after_spanning_patch, :head_offset]),
      final_state: get_in(result, [:final_video, "status", "state"]),
      skipped: result[:skipped]
    }
  end

  ## Cleanup

  defp cleanup(ctx) do
    inventory =
      Path.wildcard(Path.join([@out, "inventory", "*.jsonl"]))
      |> Enum.flat_map(&(&1 |> File.stream!() |> Enum.map(fn l -> Jason.decode!(l) end)))
      |> Enum.map(& &1["uid"])
      |> Enum.reject(&is_nil/1)

    named = search(ctx)
    deleted = (inventory ++ named) |> Enum.uniq() |> Enum.map(&delete_confirmed(ctx, &1))
    remaining = search(ctx)

    assertions = [
      assertion("every_probe_reservation_deleted", true, remaining == [], %{
        deleted: deleted,
        remaining_by_name: remaining
      })
    ]

    %{assertions: assertions, verdict: verdict(assertions)}
  end

  defp search(ctx) do
    {result, _record} =
      request(ctx, "search",
        method: :get,
        url: base(),
        params: [search: @prefix],
        headers: auth()
      )

    {:ok, %{status: 200, body: body}} = result

    body
    |> Jason.decode!()
    |> Map.fetch!("result")
    |> Enum.filter(&String.starts_with?(get_in(&1, ["meta", "name"]) || "", @prefix))
    |> Enum.map(& &1["uid"])
  end

  defp owned(reservations), do: for({_c, {:ok, r}} <- reservations, do: r.uid)

  defp delete_confirmed(ctx, uid) do
    {d, _record} =
      request(ctx, "delete", method: :delete, url: "#{base()}/#{uid}", headers: auth())

    {g, _record} =
      request(ctx, "get-after-delete", method: :get, url: "#{base()}/#{uid}", headers: auth())

    inventory(ctx, %{uid: uid, phase: "deleted", get_after: status(g)})
    %{uid: uid, delete: status(d), get_after: status(g)}
  end

  ## Stream

  defp base,
    do:
      "https://api.cloudflare.com/client/v4/accounts/" <>
        Tips.ProviderConfig.fetch!("CLOUDFLARE_ACCOUNT_ID") <> "/stream"

  defp auth,
    do: [
      {"authorization", "Bearer " <> Tips.ProviderConfig.fetch!("CLOUDFLARE_STREAM_API_TOKEN")}
    ]

  # The tus creation request Phoenix will send: private, 180 s, fixed expiry. Never retried.
  defp reserve(ctx, label, length, expiry) do
    name = @prefix <> ctx.run_id <> "-" <> label
    inventory(ctx, %{label: label, name: name, phase: "requested"})

    metadata =
      Enum.join(
        [
          "maxDurationSeconds " <> Base.encode64("180"),
          "requiresignedurls",
          "expiry " <> Base.encode64(DateTime.to_iso8601(expiry)),
          "name " <> Base.encode64(name)
        ],
        ","
      )

    headers =
      auth() ++
        [
          {"tus-resumable", "1.0.0"},
          {"upload-length", Integer.to_string(length)},
          {"upload-metadata", metadata}
        ]

    {result, record} =
      request(ctx, "reserve:#{label}",
        method: :post,
        url: base() <> "?direct_user=true",
        headers: headers
      )

    case result do
      {:ok, %{status: 201} = resp} ->
        location = header(resp, "location")
        add_secret(location)
        uid = header(resp, "stream-media-id")
        inventory(ctx, %{label: label, name: name, uid: uid, phase: "reserved"})
        {:ok, %{uid: uid, label: label, location: location, record: record}}

      _other ->
        {:error, record}
    end
  end

  # Sends `data` at `offset`, spread evenly over `duration_ms` when it is positive.
  defp patch(ctx, r, offset, data, duration_ms) do
    pieces = if duration_ms > 0, do: 50, else: 1
    piece = div(byte_size(data) + pieces - 1, pieces)
    done = :atomics.new(1, [])

    body =
      data
      |> chunks(piece)
      |> Stream.with_index()
      |> Stream.map(fn {bytes, i} ->
        if i > 0, do: Process.sleep(div(duration_ms, pieces))
        bytes
      end)
      |> Stream.concat(Stream.map([nil], fn _ -> mark_done(done) end))

    {_result, record} =
      request(ctx, "patch:#{r.label}@#{offset}+#{byte_size(data)}",
        method: :patch,
        url: r.location,
        headers: [
          {"tus-resumable", "1.0.0"},
          {"upload-offset", Integer.to_string(offset)},
          {"content-type", "application/offset+octet-stream"},
          {"content-length", Integer.to_string(byte_size(data))}
        ],
        body: body,
        receive_timeout: @patch_receive_timeout
      )

    Map.put(record, :body_done_at, done_at(done))
  end

  defp chunks(<<>>, _size), do: []

  defp chunks(data, size) when byte_size(data) <= size, do: [data]

  defp chunks(data, size),
    do: [
      binary_part(data, 0, size) | chunks(binary_part(data, size, byte_size(data) - size), size)
    ]

  # An empty iodata element marks the instant the last body byte was handed to the socket.
  defp mark_done(done) do
    :atomics.put(done, 1, System.system_time(:millisecond))
    ""
  end

  defp done_at(done) do
    case :atomics.get(done, 1) do
      0 -> nil
      ms -> ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
    end
  end

  defp head(ctx, r),
    do:
      request(ctx, "head:#{r.label}",
        method: :head,
        url: r.location,
        headers: [{"tus-resumable", "1.0.0"}]
      )

  defp video(ctx, uid) do
    {result, record} =
      request(ctx, "video", method: :get, url: "#{base()}/#{uid}", headers: auth())

    case result do
      {:ok, %{status: 200, body: body}} -> {:ok, Jason.decode!(body)["result"]}
      _other -> {:error, record}
    end
  end

  ## HTTP, redaction and records

  @keep_headers ~w(stream-media-id upload-offset upload-length upload-expires tus-resumable date cf-ray)

  defp request(ctx, label, opts) do
    :counters.add(ctx.calls, 1, 1)
    if :counters.get(ctx.calls, 1) > @max_calls, do: raise("call budget #{@max_calls} exceeded")

    opts =
      Keyword.merge([retry: false, redirect: false, decode_body: false] ++ @api_timeouts, opts)

    sent_at = now()
    started = System.monotonic_time(:millisecond)
    result = Req.request(opts)

    record =
      Map.merge(
        %{label: label, method: opts[:method], sent_at: sent_at, response_at: now()},
        response_record(result)
      )
      |> Map.put(:ms, System.monotonic_time(:millisecond) - started)

    File.write!(ctx.calls_log, redact(Jason.encode!(record)) <> "\n", [:append])
    {result, record}
  end

  defp response_record({:ok, resp}) do
    body = resp.body

    %{
      status: resp.status,
      headers:
        resp.headers
        |> Map.take(@keep_headers)
        |> Map.new(fn {k, v} -> {k, Enum.join(v, ",")} end),
      body:
        if(is_binary(body) and byte_size(body) <= 4_000,
          do: body,
          else: %{bytes: byte_size(body)}
        )
    }
  end

  defp response_record({:error, e}), do: %{status: nil, error: Exception.message(e)}

  defp add_secret(value), do: :persistent_term.put(:probe_secrets, [value | secrets()])
  defp secrets, do: :persistent_term.get(:probe_secrets, [])

  defp redact(text) do
    text =
      secrets()
      |> Enum.sort_by(&(-String.length(&1)))
      |> Enum.reduce(text, &String.replace(&2, &1, "<redacted>"))

    text = Regex.replace(~r{https://upload\.[a-z0-9.-]+/[^\s"'\\]+}, text, "<upload-url>")
    String.replace(text, Tips.ProviderConfig.fetch!("CLOUDFLARE_ACCOUNT_ID"), "<account-id>")
  end

  defp leaks(text) do
    Enum.count(secrets(), &String.contains?(text, &1)) +
      length(Regex.scan(~r{https://upload\.}, text))
  end

  defp inventory(ctx, entry) do
    line = Jason.encode!(Map.put(entry, :at, now()))
    File.write!(ctx.inventory, line <> "\n", [:append])
  end

  defp assertion(name, required?, result, evidence) do
    status =
      case result do
        true -> "pass"
        false -> "fail"
        :info -> "info"
      end

    IO.puts("#{String.pad_trailing(status, 5)} #{name}")
    %{name: name, required: required?, status: status, evidence: evidence}
  end

  defp verdict(assertions),
    do:
      if(Enum.any?(assertions, &(&1.required and &1.status != "pass")), do: "fail", else: "pass")

  defp report(mode, fun) do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
    run_id = stamp <> "-" <> Base.encode16(:crypto.strong_rand_bytes(2), case: :lower)
    File.mkdir_p!(Path.join(@out, "inventory"))
    File.mkdir_p!(Path.join(@out, "private"))

    :persistent_term.put(:probe_secrets, [
      Tips.ProviderConfig.fetch!("CLOUDFLARE_STREAM_API_TOKEN"),
      Tips.ProviderConfig.fetch!("CLOUDFLARE_STREAM_CUSTOMER_CODE")
    ])

    ctx = %{
      run_id: run_id,
      calls: :counters.new(1, []),
      inventory: Path.join([@out, "inventory", "#{mode}-#{run_id}.jsonl"]),
      calls_log: Path.join([@out, "private", "#{mode}-#{run_id}-calls.jsonl"])
    }

    IO.puts("#{mode} #{run_id}")
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    {tracked, 0} = System.cmd("git", ["status", "--porcelain", "--untracked-files=no"])
    started_at = now()
    result = fun.(ctx)

    report =
      Map.merge(
        %{
          issue: 243,
          mode: mode,
          run_id: run_id,
          git_sha: String.trim(sha),
          git_tracked_changes: tracked |> String.split("\n", trim: true) |> length(),
          started_at: started_at,
          finished_at: now(),
          versions: %{elixir: System.version(), otp: System.otp_release(), tus: "1.0.0"},
          bounds: %{
            provider_calls: :counters.get(ctx.calls, 1),
            max_calls: @max_calls,
            api_receive_timeout_ms: @api_timeouts[:receive_timeout],
            api_connect_timeout_ms: @api_timeouts[:connect_options][:timeout],
            patch_receive_timeout_ms: @patch_receive_timeout,
            retries: 0
          }
        },
        result
      )

    json = report |> Jason.encode!(pretty: true) |> redact()
    path = Path.join(@out, "#{mode}-#{run_id}.json")
    File.write!(path, json)
    leaked = leaks(json)
    IO.puts("#{mode}: #{report.verdict}; leaks #{leaked}; report #{path}")
    System.halt(if report.verdict == "pass" and leaked == 0, do: 0, else: 1)
  end

  # A 10 s 720p clip of about 15 MB: noise keeps the constant bitrate full, so the file
  # holds two 5 MiB non-final chunks and a final one.
  defp fixture do
    dir = Path.join(@out, "fixtures")
    File.mkdir_p!(dir)
    path = Path.join(dir, "clip-10s.mp4")

    args =
      ~w(-f lavfi -i testsrc2=size=1280x720:rate=30:duration=10 -f lavfi -i sine=frequency=440:duration=10
         -vf noise=alls=40:allf=t+u -c:v libx264 -pix_fmt yuv420p -preset veryfast -b:v 12M -minrate 12M
         -maxrate 12M -bufsize 12M -x264-params nal-hrd=cbr -c:a aac -shortest -movflags +faststart)

    {_out, 0} = System.cmd("ffmpeg", ~w(-hide_banner -loglevel error -y) ++ args ++ [path])
    bin = File.read!(path)

    if byte_size(bin) <= 2 * @chunk,
      do: raise("fixture has #{byte_size(bin)} bytes; need over #{2 * @chunk}")

    %{
      path: path,
      bytes: byte_size(bin),
      sha256: Base.encode16(:crypto.hash(:sha256, bin), case: :lower),
      recipe: "ffmpeg " <> Enum.join(args, " ")
    }
  end

  defp status({:ok, resp}), do: resp.status
  defp status(_error), do: nil

  defp header({:ok, resp}, name), do: header(resp, name)
  defp header({:error, _reason}, _name), do: nil
  defp header(%Req.Response{} = resp, name), do: resp.headers |> Map.get(name, []) |> List.first()

  defp header_int(result, name) do
    case header(result, name) do
      nil -> nil
      value -> String.to_integer(value)
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end

StreamCompletionProbe.main(System.argv())
