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

  # Slow PATCH start and end, in seconds relative to uploadExpiry. Every case first sends
  # unthrottled 5 MiB chunks. `final` then sends the last chunk slowly; `nonfinal` sends
  # the second 5 MiB chunk slowly, then the last chunk at once if Stream stored it.
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

  # Cases run one after another, each with its own reservation and expiry. Any unexpected
  # result stops the run before the next reservation; the partial report is kept and every
  # reservation this run made is deleted.
  defp run(ctx) do
    fixture = fixture()
    data = File.read!(fixture.path)
    {results, stopped} = run_cases(ctx, @cases, data, [])
    deleted = Enum.map(reserved_uids(ctx), &delete_confirmed(ctx, &1))

    assertions =
      [assertion("run_not_stopped", true, stopped == nil, %{stopped: stopped})] ++
        assertions(results, deleted)

    %{
      fixture: Map.delete(fixture, :path),
      cases: results,
      deleted: deleted,
      assertions: assertions,
      verdict: verdict(assertions)
    }
  end

  defp run_cases(_ctx, [], _data, done), do: {Enum.reverse(done), nil}

  defp run_cases(ctx, [c | rest], data, done) do
    result = guarded(c.label, fn -> run_case(ctx, c, data) end)

    case unexpected(result) do
      nil -> run_cases(ctx, rest, data, [result | done])
      reason -> {Enum.reverse([result | done]), %{case: c.label, reason: reason}}
    end
  end

  # A crash still returns a result, so the report and the deletions survive it.
  defp guarded(label, fun) do
    fun.()
  rescue
    e -> %{case: label, crashed: Exception.message(e)}
  end

  # The control must complete. Boundary requests may succeed or be refused for expiry
  # (400, code 10017); anything else is an unexplained provider error.
  defp unexpected(%{crashed: message}), do: "crashed: " <> message

  defp unexpected(%{case: "before", lead_acknowledged: true} = result) do
    if result.spanning_patch.status == 204 and completed?(result),
      do: nil,
      else: "control did not complete: " <> describe(result.spanning_patch)
  end

  defp unexpected(%{lead_acknowledged: true} = result) do
    case Enum.reject([result.spanning_patch | result.tail_patches || []], &expected_boundary?/1) do
      [] -> nil
      [record | _rest] -> "unexpected response: " <> describe(record)
    end
  end

  defp unexpected(%{lead_acknowledged: false, lead_chunks: lead}),
    do: "chunk not acknowledged: " <> describe(List.last(lead))

  defp unexpected(%{reservation: record}), do: "reservation failed: " <> describe(record)

  defp expected_boundary?(%{status: 204}), do: true

  defp expected_boundary?(%{status: 400, body: body}) when is_binary(body),
    do: match?({:ok, %{"errors" => [%{"code" => 10_017} | _]}}, Jason.decode(body))

  defp expected_boundary?(_record), do: false

  defp describe(record), do: inspect(Map.take(record, [:label, :status, :error, :body]))

  defp reserved_uids(ctx) do
    ctx.inventory
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["phase"] == "reserved"))
    |> Enum.map(& &1["uid"])
  end

  defp run_case(ctx, c, data) do
    expiry = DateTime.utc_now() |> DateTime.add(@expiry_s) |> DateTime.truncate(:second)

    case reserve(ctx, c.label, byte_size(data), expiry) do
      {:ok, r} -> upload_case(ctx, c, r, data, expiry)
      {:error, record} -> %{case: c.label, expiry: iso(expiry), reservation: record}
    end
  end

  # A lead chunk that is not acknowledged stops the case: no valid unfinished transfer exists.
  defp upload_case(ctx, c, r, data, expiry) do
    slow_from = if c.kind == :final, do: last_chunk_offset(data), else: @chunk
    {lead, lead_ok?} = send_chunks(ctx, r, data, 0, slow_from)
    {:ok, reserved} = video(ctx, r.uid)

    base = %{
      case: c.label,
      uid: r.uid,
      expiry: iso(expiry),
      planned: Map.take(c, [:start, :finish, :kind]),
      reservation: r.record,
      reserved_video: observation(reserved),
      lead_chunks: lead,
      lead_acknowledged: lead_ok?
    }

    if lead_ok?, do: Map.merge(base, slow_case(ctx, c, r, data, expiry, slow_from)), else: base
  end

  defp slow_case(ctx, c, r, data, expiry, from) do
    sleep_until(expiry, c.start)
    size = if c.kind == :final, do: byte_size(data) - from, else: @chunk
    slow = patch(ctx, r, from, binary_part(data, from, size), (c.finish - c.start) * 1000)
    after_slow = observe(ctx, r)
    to = from + size

    tail =
      if to < byte_size(data) and after_slow.head_offset == to,
        do: ctx |> send_chunks(r, data, to, byte_size(data)) |> elem(0)

    %{
      spanning_patch: slow,
      after_spanning_patch: after_slow,
      tail_patches: tail,
      observations: poll(ctx, r, 24),
      final_video: last_video(ctx, r.uid)
    }
  end

  # Sends data[offset, to) unthrottled in chunks of at most 5 MiB, like the #61 client.
  # Stops at the first chunk not acknowledged with 204 and the advanced offset.
  defp send_chunks(ctx, r, data, offset, to, sent \\ [])

  defp send_chunks(_ctx, _r, _data, offset, to, sent) when offset >= to,
    do: {Enum.reverse(sent), true}

  defp send_chunks(ctx, r, data, offset, to, sent) do
    size = min(@chunk, to - offset)
    record = patch(ctx, r, offset, binary_part(data, offset, size), 0)

    if acknowledged?(record, offset + size),
      do: send_chunks(ctx, r, data, offset + size, to, [record | sent]),
      else: {Enum.reverse([record | sent]), false}
  end

  defp last_chunk_offset(data), do: div(byte_size(data) - 1, @chunk) * @chunk

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

  defp assertions(results, deleted) do
    by = Map.new(results, &{&1.case, &1})
    before = by["before"]

    [
      assertion(
        "lead_chunks_acknowledged",
        true,
        Enum.all?(results, &(&1[:lead_acknowledged] == true)),
        Map.new(results, &{&1.case, lead_evidence(&1[:lead_chunks])})
      ),
      assertion("before_finished_before_expiry", true, before?(before, :response_at), %{
        response_at: get_in(before, [:spanning_patch, :response_at]),
        expiry: before[:expiry]
      }),
      assertion("before_expiry_completes", true, completed?(before), %{
        patch_status: get_in(before, [:spanning_patch, :status]),
        final_state: get_in(before, [:final_video, "status", "state"])
      }),
      assertion("uploaded_is_reservation_time", true, uploaded_before_first_byte?(before), %{
        uploaded: get_in(before, [:reserved_video, :uploaded]),
        first_chunk_sent_at: first_sent_at(before)
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
      Enum.flat_map(
        ["span-10", "span-60", "nonfinal-span-10"],
        &span_assertions(by[&1] || %{case: &1})
      ) ++
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
  defp span_assertions(result) do
    spans? =
      before?(result, :sent_at) and not before?(result, :body_done_at) and
        get_in(result, [:spanning_patch, :body_done_at]) != nil

    [
      assertion("#{result.case}_spans_expiry", true, spans?, %{
        sent_at: get_in(result, [:spanning_patch, :sent_at]),
        body_done_at: get_in(result, [:spanning_patch, :body_done_at]),
        expiry: result[:expiry]
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
      tail_statuses: Enum.map(result[:tail_patches] || [], & &1.status),
      final_state: get_in(result, [:final_video, "status", "state"]),
      completed: completed?(result)
    })
  end

  defp acknowledged?(%{status: 204, headers: %{"upload-offset" => offset}}, expected),
    do: offset == Integer.to_string(expected)

  defp acknowledged?(_record, _expected), do: false

  defp before?(result, key) do
    case {get_in(result, [:spanning_patch, key]), result[:expiry]} do
      {at, expiry} when is_binary(at) and is_binary(expiry) -> before_iso?(at, expiry)
      _missing -> false
    end
  end

  defp lead_evidence(nil), do: []
  defp lead_evidence(records), do: Enum.map(records, &Map.take(&1, [:label, :status, :headers]))

  defp first_sent_at(%{lead_chunks: [first | _rest]}), do: first.sent_at
  defp first_sent_at(_result), do: nil

  defp completed?(%{final_video: %{"status" => %{"state" => state}}}),
    do: state not in ["pendingupload"]

  defp completed?(_result), do: false

  defp uploaded_before_first_byte?(%{reserved_video: %{uploaded: uploaded}} = result)
       when is_binary(uploaded),
       do: before_iso?(uploaded, first_sent_at(result))

  defp uploaded_before_first_byte?(_result), do: false

  defp before_iso?(a, b) do
    {:ok, a, _} = DateTime.from_iso8601(a)
    {:ok, b, _} = DateTime.from_iso8601(b)
    DateTime.before?(a, b)
  end

  ## Diagnose

  # Two uploads far from expiry, sent like the #61 client: 5 MiB chunks, then the last
  # chunk unthrottled; then the same with the last chunk throttled over 20 s like the
  # `before` control. The second is reserved only if the first completes.
  @diagnose_expiry_s 900

  defp diagnose(ctx) do
    fixture = fixture()
    data = File.read!(fixture.path)
    expiry = DateTime.utc_now() |> DateTime.add(@diagnose_expiry_s) |> DateTime.truncate(:second)
    first = guarded("unthrottled", fn -> diagnose_case(ctx, "unthrottled", data, expiry, 0) end)

    second =
      if completed?(first),
        do:
          guarded("throttled-20s", fn ->
            diagnose_case(ctx, "throttled-20s", data, expiry, 20_000)
          end),
        else: %{case: "throttled-20s", skipped: "unthrottled upload did not complete"}

    deleted = Enum.map(reserved_uids(ctx), &delete_confirmed(ctx, &1))

    assertions = [
      assertion("unthrottled_completes", true, completed?(first), diagnose_evidence(first)),
      assertion("throttled_completes", true, completed?(second), diagnose_evidence(second)),
      assertion(
        "every_reservation_deleted",
        true,
        Enum.all?(deleted, &(&1.get_after == 404)),
        %{deleted: deleted}
      )
    ]

    %{
      fixture: Map.delete(fixture, :path),
      requested_expiry: iso(expiry),
      cases: [first, second],
      deleted: deleted,
      assertions: assertions,
      verdict: verdict(assertions)
    }
  end

  defp diagnose_case(ctx, label, data, expiry, duration_ms) do
    case reserve(ctx, label, byte_size(data), expiry) do
      {:ok, r} ->
        last = last_chunk_offset(data)
        {lead, lead_ok?} = send_chunks(ctx, r, data, 0, last)
        base = %{case: label, uid: r.uid, lead_chunks: lead, lead_acknowledged: lead_ok?}

        if lead_ok? do
          final =
            patch(ctx, r, last, binary_part(data, last, byte_size(data) - last), duration_ms)

          Map.merge(base, %{
            spanning_patch: final,
            after_spanning_patch: observe(ctx, r),
            observations: poll(ctx, r, 24),
            final_video: last_video(ctx, r.uid)
          })
        else
          base
        end

      {:error, record} ->
        %{case: label, reservation: record}
    end
  end

  defp diagnose_evidence(result) do
    %{
      lead_statuses: Enum.map(result[:lead_chunks] || [], & &1.status),
      final_status: get_in(result, [:spanning_patch, :status]),
      final_sent_at: get_in(result, [:spanning_patch, :sent_at]),
      final_body_done_at: get_in(result, [:spanning_patch, :body_done_at]),
      final_response_at: get_in(result, [:spanning_patch, :response_at]),
      final_body: get_in(result, [:spanning_patch, :body]),
      head_offset_after: get_in(result, [:after_spanning_patch, :head_offset]),
      final_state: get_in(result, [:final_video, "status", "state"]),
      skipped: result[:skipped],
      crashed: result[:crashed]
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

  # An unthrottled body goes as one binary, as in the #61 client. A throttled body is a
  # stream of 50 pieces with an explicit Content-Length. Its last-callback runs only when
  # the client asks for more after the last piece, so `body_done_at` stays unset when a
  # transport error halts the body early.
  defp patch(ctx, r, offset, data, duration_ms) do
    done = :atomics.new(1, [])

    {body, length} =
      if duration_ms > 0,
        do: {throttled(data, duration_ms, done), [{"content-length", "#{byte_size(data)}"}]},
        else: {data, []}

    {_result, record} =
      request(ctx, "patch:#{r.label}@#{offset}+#{byte_size(data)}",
        method: :patch,
        url: r.location,
        headers:
          [
            {"tus-resumable", "1.0.0"},
            {"upload-offset", Integer.to_string(offset)},
            {"content-type", "application/offset+octet-stream"}
          ] ++ length,
        body: body,
        receive_timeout: @patch_receive_timeout
      )

    Map.put(record, :body_done_at, done_at(done))
  end

  @pieces 50

  defp throttled(data, duration_ms, done) do
    data
    |> chunks(div(byte_size(data) + @pieces - 1, @pieces))
    |> Stream.with_index()
    |> Stream.transform(
      fn -> nil end,
      fn {bytes, i}, acc ->
        if i > 0, do: Process.sleep(div(duration_ms, @pieces))
        {[bytes], acc}
      end,
      fn acc ->
        :atomics.put(done, 1, System.system_time(:millisecond))
        {[], acc}
      end,
      fn _acc -> :ok end
    )
  end

  defp chunks(<<>>, _size), do: []

  defp chunks(data, size) when byte_size(data) <= size, do: [data]

  defp chunks(data, size),
    do: [
      binary_part(data, 0, size) | chunks(binary_part(data, size, byte_size(data) - size), size)
    ]

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

  # The #61 two-chunk recipe (720p, 30 fps, no audio, 6 Mbit/s for 12 s) at 10 s and
  # 10 Mbit/s: about 13 MB, so two 5 MiB non-final chunks and a shorter final one.
  defp fixture do
    dir = Path.join(@out, "fixtures")
    File.mkdir_p!(dir)
    path = Path.join(dir, "clip-10s.mp4")

    args =
      ~w(-f lavfi -i testsrc2=size=1280x720:rate=30:duration=10 -c:v libx264 -pix_fmt yuv420p
         -preset veryfast -b:v 10M -maxrate 10M -bufsize 20M -movflags +faststart)

    {_out, 0} = System.cmd("ffmpeg", ~w(-hide_banner -loglevel error -y) ++ args ++ [path])
    bin = File.read!(path)

    unless byte_size(bin) > 2 * @chunk and byte_size(bin) <= 3 * @chunk,
      do:
        raise("fixture has #{byte_size(bin)} bytes; need two full chunks and a shorter final one")

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
  defp iso(at), do: DateTime.to_iso8601(at)
end

StreamCompletionProbe.main(System.argv())
