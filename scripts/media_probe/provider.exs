# Disposable real-provider probe for issue #61: Stream tus, signed playback, deadlines,
# R2 semantics and cleanup. Run through scripts/media_probe.sh with TIPS_REAL_PROVIDERS=1.
# Candidate client dependencies are pinned here, outside mix.exs/mix.lock.
Mix.install([{:req, "== 0.7.4"}, {:jose, "== 1.11.12"}, {:jason, "== 1.4.5"}])
Code.require_file("lib/tips/provider_config.ex")

defmodule MediaProbe.Ctx do
  @moduledoc false
  # Fixed destinations, one call at a time, no automatic retries, bounded call count.
  @max_calls 400

  def new(mode, out) do
    env_file = System.get_env("TIPS_PROVIDER_ENV_FILE", ".env")
    values = Tips.ProviderConfig.load(env_file, System.get_env())
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    run_id = "#{stamp}-#{Base.encode16(:crypto.strong_rand_bytes(2), case: :lower)}"
    File.mkdir_p!(Path.join(out, "inventory"))
    File.mkdir_p!(Path.join(out, "private"))

    ctx = %{
      mode: mode,
      out: out,
      env_file: env_file,
      values: values,
      run_id: run_id,
      inventory: Path.join([out, "inventory", "#{mode}-#{run_id}.jsonl"]),
      calls_log: Path.join([out, "private", "#{mode}-#{run_id}-calls.jsonl"])
    }

    :persistent_term.put(:probe_ctx, ctx)
    :counters.new(1, []) |> then(&:persistent_term.put(:probe_calls, &1))
    :persistent_term.put(:probe_secrets, secrets(values))
    :persistent_term.put(:probe_assertions, :ets.new(:assertions, [:ordered_set, :public]))
    :persistent_term.put(:probe_facts, :ets.new(:facts, [:ordered_set, :public]))
    ctx
  end

  def fetch!(name) do
    value = :persistent_term.get(:probe_ctx).values |> Map.get(name, "")
    if String.trim(value) == "", do: raise("#{name} is missing or blank"), else: value
  end

  def get(name), do: :persistent_term.get(:probe_ctx).values |> Map.get(name, "") |> String.trim()
  def ctx, do: :persistent_term.get(:probe_ctx)

  defp secrets(values) do
    ~w(CLOUDFLARE_STREAM_API_TOKEN R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY CLOUDFLARE_STREAM_SIGNING_KEY OPENROUTER_API_KEY)
    |> Enum.map(&Map.get(values, &1, ""))
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  def add_secret(value), do: :persistent_term.put(:probe_secrets, [value | :persistent_term.get(:probe_secrets)])
  def secrets, do: :persistent_term.get(:probe_secrets)

  def count_call! do
    ref = :persistent_term.get(:probe_calls)
    :counters.add(ref, 1, 1)
    if :counters.get(ref, 1) > @max_calls, do: raise("call budget #{@max_calls} exceeded")
  end

  def calls, do: :counters.get(:persistent_term.get(:probe_calls), 1)
  def max_calls, do: @max_calls

  # Written before a resource is requested, then again when its id is known, so a crash or
  # a lost response still leaves a cleanup record.
  def inventory(entry) do
    line = Jason.encode!(Map.put(entry, :at, now_iso()))
    File.write!(ctx().inventory, line <> "\n", [:append])
  end

  def fact(key, value), do: :ets.insert(:persistent_term.get(:probe_facts), {key, value})
  def facts, do: :ets.tab2list(:persistent_term.get(:probe_facts)) |> Map.new()

  def assert(experiment, name, required?, result, evidence \\ %{}) do
    status =
      case result do
        true -> "pass"
        false -> "fail"
        :unproven -> "unproven"
        :info -> "info"
      end

    tab = :persistent_term.get(:probe_assertions)
    :ets.insert(tab, {:erlang.unique_integer([:monotonic]), %{experiment: experiment, name: name, required: required?, status: status, evidence: evidence}})
    IO.puts("#{String.pad_trailing(status, 8)} #{experiment}/#{name}#{if required?, do: "", else: " (informational)"}")
    status == "pass"
  end

  def assertions, do: :ets.tab2list(:persistent_term.get(:probe_assertions)) |> Enum.map(&elem(&1, 1))

  def now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
  def now_ms, do: System.system_time(:millisecond)
end

defmodule MediaProbe.Redact do
  @moduledoc false
  alias MediaProbe.Ctx

  @jwt ~r/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/

  def upload_url(url), do: :persistent_term.put({:probe_upload, url}, true) |> then(fn _ -> Ctx.add_secret(url) end)

  def text(text) when is_binary(text) do
    text =
      Ctx.secrets()
      |> Enum.sort_by(&(-String.length(&1)))
      |> Enum.reduce(text, fn secret, acc -> String.replace(acc, secret, "<redacted>") end)

    text = Regex.replace(@jwt, text, "<signed-token>")
    text = Regex.replace(~r{https://upload\.[a-z0-9.-]+/[^\s"']+}, text, "<upload-url>")
    text = Regex.replace(~r{/tus/[A-Za-z0-9?=&%._-]+}, text, "/tus/<redacted>")
    text = replace_value(text, Ctx.get("CLOUDFLARE_STREAM_CUSTOMER_CODE"), "<customer-code>")
    text = replace_value(text, Ctx.get("CLOUDFLARE_ACCOUNT_ID"), "<account-id>")
    text = replace_value(text, Ctx.get("R2_PUBLIC_URL") |> String.trim_trailing("/"), "<r2-public-url>")
    text = replace_value(text, Ctx.get("R2_ENDPOINT") |> String.trim_trailing("/"), "<r2-endpoint>")
    replace_value(text, Ctx.get("R2_BUCKET"), "<r2-bucket>")
  end

  defp replace_value(text, "", _), do: text
  defp replace_value(text, value, label), do: String.replace(text, value, label)

  # Fails when any credential, signing material, upload endpoint or signed token survives.
  def leaks(text) do
    secret_hits = Enum.count(Ctx.secrets(), &String.contains?(text, &1))
    %{secret_values: secret_hits, jwt_like: length(Regex.scan(@jwt, text)), upload_urls: length(Regex.scan(~r{https://upload\.}, text))}
  end
end

defmodule MediaProbe.Http do
  @moduledoc false
  alias MediaProbe.{Ctx, Redact}

  @keep_headers ~w(stream-media-id location upload-offset upload-length upload-expires tus-resumable content-type content-length cache-control cf-cache-status etag last-modified date age cf-ray www-authenticate)

  # One bounded request: no retries, no redirects, fixed timeouts. The raw log is private
  # but already redacted of credentials.
  def request(label, opts) do
    Ctx.count_call!()
    opts = Keyword.merge([retry: false, redirect: false, decode_body: false, receive_timeout: 30_000, connect_options: [timeout: 10_000]], opts)
    started = System.monotonic_time(:millisecond)
    sent_at = Ctx.now_iso()

    result =
      try do
        Req.request(opts)
      rescue
        e -> {:error, e}
      end

    ms = System.monotonic_time(:millisecond) - started

    record =
      case result do
        {:ok, resp} ->
          %{label: label, method: opts[:method], url: opts[:url], status: resp.status, ms: ms, sent_at: sent_at, headers: keep(resp.headers), body: summarize(resp.body)}

        {:error, e} ->
          %{label: label, method: opts[:method], url: opts[:url], status: nil, ms: ms, sent_at: sent_at, error: Exception.message(e)}
      end

    File.write!(Ctx.ctx().calls_log, Redact.text(Jason.encode!(record)) <> "\n", [:append])
    {result, record}
  end

  defp keep(headers), do: headers |> Map.take(@keep_headers) |> Map.new(fn {k, v} -> {k, Enum.join(v, ",")} end)

  defp summarize(body) when is_binary(body) do
    cond do
      byte_size(body) == 0 -> ""
      String.valid?(body) and byte_size(body) <= 4000 -> body
      true -> %{bytes: byte_size(body), sha256: sha(body), head_hex: Base.encode16(binary_part(body, 0, min(8, byte_size(body))))}
    end
  end

  defp summarize(body), do: inspect(body)

  def sha(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)
  def header(resp, name), do: resp.headers |> Map.get(name, []) |> List.first()
end

defmodule MediaProbe.Stream do
  @moduledoc false
  alias MediaProbe.{Ctx, Http, Redact}

  @cap 1_000_000_000

  def base, do: "https://api.cloudflare.com/client/v4/accounts/#{Ctx.fetch!("CLOUDFLARE_ACCOUNT_ID")}/stream"
  defp auth, do: [{"authorization", "Bearer " <> Ctx.fetch!("CLOUDFLARE_STREAM_API_TOKEN")}]
  def host, do: "https://customer-#{Ctx.fetch!("CLOUDFLARE_STREAM_CUSTOMER_CODE")}.cloudflarestream.com"

  # The probe's stand-in for the Phoenix authorization step: only integers 1..1e9 reach Stream.
  def authorize_length(n) when is_integer(n) and n >= 1 and n <= @cap, do: :ok
  def authorize_length(_), do: {:error, :invalid_length}

  def metadata(expiry, label, opts \\ []) do
    pairs = [
      "maxDurationSeconds #{Base.encode64(Integer.to_string(Keyword.get(opts, :max_duration, 180)))}",
      "requiresignedurls",
      "expiry #{Base.encode64(DateTime.to_iso8601(DateTime.truncate(expiry, :second)))}",
      "name #{Base.encode64(name(label))}"
    ]

    Enum.join(pairs, ",")
  end

  def name(label), do: "tips-probe-61-#{Ctx.ctx().run_id}-#{label}"

  # Reservation: the server-side tus creation request. Recorded in the inventory before
  # sending and again with the uid; never retried.
  def reserve(label, length, expiry, opts \\ []) do
    Ctx.inventory(%{kind: "stream", label: label, name: name(label), phase: "requested"})

    headers =
      auth() ++
        [{"tus-resumable", "1.0.0"}, {"upload-length", to_string(length)}, {"upload-metadata", metadata(expiry, label, opts)}]

    req_opts = [method: :post, url: base() <> "?direct_user=true", headers: headers, body: ""]
    req_opts = if t = opts[:receive_timeout], do: Keyword.put(req_opts, :receive_timeout, t), else: req_opts
    {result, record} = Http.request("reserve:#{label}", req_opts)

    case result do
      {:ok, %{status: 201} = resp} ->
        uid = Http.header(resp, "stream-media-id")
        location = Http.header(resp, "location")
        Redact.upload_url(location)
        Ctx.inventory(%{kind: "stream", label: label, name: name(label), uid: uid, phase: "reserved"})
        {:ok, %{uid: uid, location: location, label: label, length: length, expiry: expiry, record: record}}

      _ ->
        {:error, record}
    end
  end

  def patch(r, offset, data, extra_headers \\ []) do
    headers = [{"tus-resumable", "1.0.0"}, {"upload-offset", to_string(offset)}, {"content-type", "application/offset+octet-stream"}] ++ extra_headers
    Http.request("patch:#{r.label}@#{offset}+#{byte_size(data)}", method: :patch, url: r.location, headers: headers, body: data, receive_timeout: 120_000)
  end

  def head(r), do: Http.request("head:#{r.label}", method: :head, url: r.location, headers: [{"tus-resumable", "1.0.0"}])

  def video(uid) do
    {result, record} = Http.request("video:#{uid}", method: :get, url: "#{base()}/#{uid}", headers: auth())

    case result do
      {:ok, %{status: 200, body: body}} -> {:ok, Jason.decode!(body)["result"], record}
      _ -> {:error, record}
    end
  end

  def delete(uid), do: Http.request("delete:#{uid}", method: :delete, url: "#{base()}/#{uid}", headers: auth())

  def search(term) do
    {result, record} = Http.request("search:#{term}", method: :get, url: base(), params: [search: term], headers: auth())

    case result do
      {:ok, %{status: 200, body: body}} -> {:ok, Jason.decode!(body)["result"], record}
      _ -> {:error, record}
    end
  end

  # Poll one video at a fixed 5 s interval until `done?` or the bounded attempt count.
  def poll(uid, done?, attempts \\ 60) do
    Enum.reduce_while(1..attempts, [], fn _, seen ->
      case video(uid) do
        {:ok, v, _} ->
          obs = observation(v)
          seen = seen ++ [obs]
          if done?.(v), do: {:halt, seen}, else: (Process.sleep(5_000) && {:cont, seen})

        {:error, _} ->
          Process.sleep(5_000)
          {:cont, seen}
      end
    end)
  end

  def observation(v) do
    %{
      observed_at: Ctx.now_iso(),
      state: get_in(v, ["status", "state"]),
      err: get_in(v, ["status", "errorReasonCode"]),
      uploaded: v["uploaded"],
      created: v["created"],
      modified: v["modified"],
      ready: v["readyToStream"],
      ready_at: v["readyToStreamAt"],
      upload_expiry: v["uploadExpiry"],
      duration: v["duration"],
      size: v["size"],
      require_signed: v["requireSignedURLs"],
      max_duration: v["maxDurationSeconds"]
    }
  end

  # --- signed playback ---------------------------------------------------------------

  def signing_jwk do
    case Ctx.get("CLOUDFLARE_STREAM_SIGNING_KEY") do
      "" -> nil
      b64 -> b64 |> Base.decode64!() |> Jason.decode!()
    end
  end

  def token(uid, jwk_map, opts \\ []) do
    exp = Keyword.get(opts, :exp, System.system_time(:second) + 3600)
    jwk = JOSE.JWK.from_map(jwk_map)
    claims = %{"sub" => uid, "kid" => jwk_map["kid"], "exp" => exp, "downloadable" => false}
    {_, token} = JOSE.JWT.sign(jwk, %{"alg" => "RS256", "kid" => jwk_map["kid"]}, claims) |> JOSE.JWS.compact()
    token
  end

  def cdn_get(label, path), do: Http.request(label, method: :get, url: host() <> path, receive_timeout: 30_000)
end

defmodule MediaProbe.Fixtures do
  @moduledoc false
  def videos(dir) do
    File.mkdir_p!(dir)

    specs = [
      {"small.mp4", ~w(-f lavfi -i testsrc=size=320x240:rate=25:duration=10 -f lavfi -i sine=frequency=440:duration=10 -c:v libx264 -pix_fmt yuv420p -preset veryfast -c:a aac -shortest -movflags +faststart)},
      {"two-chunk.mp4", ~w(-f lavfi -i testsrc2=size=1280x720:rate=30:duration=12 -c:v libx264 -pix_fmt yuv420p -preset veryfast -b:v 6M -maxrate 6M -bufsize 12M -movflags +faststart)},
      {"over-180s.mp4", ~w(-f lavfi -i testsrc=size=160x120:rate=5:duration=200 -c:v libx264 -pix_fmt yuv420p -preset veryfast -movflags +faststart)}
    ]

    Map.new(specs, fn {name, args} ->
      out = Path.join(dir, name)
      {_, 0} = System.cmd("ffmpeg", ~w(-hide_banner -loglevel error -y) ++ args ++ [out])
      bin = File.read!(out)
      {name, %{path: out, bytes: byte_size(bin), sha256: MediaProbe.Http.sha(bin), recipe: "ffmpeg " <> Enum.join(args, " ")}}
    end)
  end
end

defmodule MediaProbe.StreamRun do
  @moduledoc false
  alias MediaProbe.{Ctx, Http, Stream}

  # tus chunks must be multiples of 256 KiB and at least 5,242,880 bytes except the last.
  @chunk 5_242_880

  def run do
    fixtures = MediaProbe.Fixtures.videos(Path.join(Ctx.ctx().out, "video-fixtures"))
    Ctx.fact(:video_fixtures, Map.new(fixtures, fn {k, v} -> {k, Map.delete(v, :path)} end))
    jwk = Stream.signing_jwk()
    Ctx.fact(:signing_key_present, jwk != nil)
    owned = :ets.new(:owned, [:set, :public])
    :persistent_term.put(:probe_owned, owned)

    try do
      length_experiment(fixtures)
      {small, long} = private_experiment(fixtures, jwk)
      deadline_experiment(fixtures, small)
      delete_experiment(small, long, jwk)
    after
      cleanup_owned()
    end
  end

  defp own({:ok, r}), do: (:ets.insert(:persistent_term.get(:probe_owned), {r.uid, r.label}) && {:ok, r})
  defp own(other), do: other

  defp in_hour, do: DateTime.add(DateTime.utc_now(), 3600, :second)

  # --- stream_length -----------------------------------------------------------------

  defp length_experiment(fixtures) do
    e = "stream_length"

    before = Ctx.calls()
    refused = for n <- [0, -1, "abc", 1_000_000_001], do: {n, Stream.authorize_length(n)}
    Ctx.assert(e, "server_authorizer_refuses_invalid_and_over_cap_before_provider", true,
      Enum.all?(refused, fn {_, r} -> r == {:error, :invalid_length} end) and Ctx.calls() == before,
      %{inputs: Enum.map(refused, fn {n, r} -> %{length: inspect(n), result: inspect(r)} end), provider_calls: Ctx.calls() - before})

    # Provider behaviour when the authorizer is bypassed (informational: shows what Stream
    # itself enforces).
    provider_invalid =
      for {label, value} <- [{"len-zero", "0"}, {"len-negative", "-1"}, {"len-text", "abc"}] do
        headers = [{"authorization", "Bearer " <> Ctx.fetch!("CLOUDFLARE_STREAM_API_TOKEN")}, {"tus-resumable", "1.0.0"}, {"upload-length", value}, {"upload-metadata", Stream.metadata(in_hour(), label)}]
        Ctx.inventory(%{kind: "stream", label: label, name: Stream.name(label), phase: "requested"})
        {result, record} = Http.request("reserve:#{label}", method: :post, url: Stream.base() <> "?direct_user=true", headers: headers, body: "")

        with {:ok, %{status: 201} = resp} <- result do
          uid = Http.header(resp, "stream-media-id")
          MediaProbe.Redact.upload_url(Http.header(resp, "location"))
          Ctx.inventory(%{kind: "stream", label: label, name: Stream.name(label), uid: uid, phase: "reserved"})
          :ets.insert(:persistent_term.get(:probe_owned), {uid, label})
        end

        %{upload_length: value, status: record.status, body: record[:body]}
      end

    Ctx.assert(e, "provider_rejects_invalid_upload_length", false, if(Enum.all?(provider_invalid, &(&1.status in 400..499)), do: true, else: :info), %{responses: provider_invalid})

    small_len = fixtures["small.mp4"].bytes

    declared =
      for {label, n} <- [{"decl-small", small_len}, {"decl-200mb", 200_000_000}, {"decl-1gb", 1_000_000_000}] do
        :ok = Stream.authorize_length(n)

        case own(Stream.reserve(label, n, in_hour())) do
          {:ok, r} ->
            {{:ok, h}, _} = Stream.head(r)
            %{label: label, declared: n, status: 201, uid_header: r.uid != nil, head_length: Http.header(h, "upload-length"), head_offset: Http.header(h, "upload-offset"), r: r}

          {:error, rec} ->
            %{label: label, declared: n, status: rec.status, body: rec[:body]}
        end
      end

    Ctx.assert(e, "reservations_accept_small_200mb_and_1e9_declarations", true,
      Enum.all?(declared, &(&1.status == 201 and &1.uid_header and &1.head_length == to_string(&1.declared) and &1.head_offset == "0")),
      %{reservations: Enum.map(declared, &Map.delete(&1, :r)), bytes_transferred: 0})

    over =
      case own(Stream.reserve("decl-over-cap", 1_000_000_001, in_hour())) do
        {:ok, r} -> %{status: 201, note: "Stream accepted a length above the Tips cap; the cap is the server authorizer's job"} |> Map.put(:uid, r.uid)
        {:error, rec} -> %{status: rec.status, body: rec[:body]}
      end

    Ctx.assert(e, "provider_rejects_over_cap_declaration", false, if(over.status in 400..499, do: true, else: :info), over)

    # The browser only PATCHes the released endpoint; it cannot raise Upload-Length.
    r200 = Enum.find(declared, &(&1.label == "decl-200mb"))[:r]

    if r200 do
      {res, rec} = Stream.patch(r200, 0, "", [{"upload-length", "2000000000"}])
      {{:ok, h}, _} = Stream.head(r200)
      Ctx.assert(e, "patch_cannot_raise_declared_length", true, Http.header(h, "upload-length") == "200000000",
        %{patch_status: status(res), patch: Map.take(rec, [:status, :headers, :body]), head_length_after: Http.header(h, "upload-length")})
    else
      Ctx.assert(e, "patch_cannot_raise_declared_length", true, :unproven, %{reason: "200 MB reservation failed"})
    end

    overrun_experiment(e)
  end

  # Declare 262,144 bytes, then try to write more than that. Both writes are multiples of
  # 256 KiB so the chunk-alignment rule cannot be the reason for a rejection.
  defp overrun_experiment(e) do
    declared = 262_144
    data = :crypto.strong_rand_bytes(declared * 2)

    case own(Stream.reserve("overrun-single", declared, in_hour())) do
      {:ok, r} ->
        {res, rec} = Stream.patch(r, 0, data)
        {{:ok, h}, _} = Stream.head(r)
        offset = Http.header(h, "upload-offset")
        Ctx.assert(e, "patch_beyond_upload_length_rejected", true, status(res) in 400..499 and offset == "0",
          %{declared: declared, sent: byte_size(data), patch: Map.take(rec, [:status, :headers, :body]), head_offset_after: offset})

      {:error, rec} ->
        Ctx.assert(e, "patch_beyond_upload_length_rejected", true, :unproven, %{reservation: rec})
    end

    case own(Stream.reserve("overrun-after-complete", declared, in_hour())) do
      {:ok, r} ->
        {res1, rec1} = Stream.patch(r, 0, binary_part(data, 0, declared))
        {res2, rec2} = Stream.patch(r, declared, binary_part(data, declared, declared))
        {{:ok, h}, _} = Stream.head(r)
        offset = Http.header(h, "upload-offset")
        {:ok, v, _} = Stream.video(r.uid)

        # Stream may answer 204 here; the claim is that no byte beyond Upload-Length is stored.
        Ctx.assert(e, "bytes_after_complete_upload_not_stored", true,
          status(res1) == 204 and offset == to_string(declared) and status(res2) != nil and (rec2[:headers] || %{})["upload-offset"] in [nil, to_string(declared)],
          %{first: Map.take(rec1, [:status, :headers]), extra: Map.take(rec2, [:status, :headers, :body]), head_offset_after: offset, video_size: v["size"], bytes_transferred: declared * 2})

      {:error, rec} ->
        Ctx.assert(e, "bytes_after_complete_upload_not_stored", true, :unproven, %{reservation: rec})
    end
  end

  defp status({:ok, resp}), do: resp.status
  defp status(_), do: nil

  # --- stream_private ----------------------------------------------------------------

  defp private_experiment(fixtures, jwk) do
    e = "stream_private"
    small = upload_whole("private-small", fixtures["small.mp4"])
    long = upload_whole("private-over-180", fixtures["over-180s.mp4"])

    case small do
      {:ok, s} ->
        {:ok, v, _} = Stream.video(s.uid)
        expected_expiry = DateTime.to_iso8601(DateTime.truncate(s.expiry, :second))

        Ctx.assert(e, "reservation_metadata_applied", true,
          v["uid"] == s.uid and v["requireSignedURLs"] == true and v["maxDurationSeconds"] == 180 and same_instant?(v["uploadExpiry"], expected_expiry),
          %{uid_from_stream_media_id: v["uid"] == s.uid, requireSignedURLs: v["requireSignedURLs"], maxDurationSeconds: v["maxDurationSeconds"], uploadExpiry: v["uploadExpiry"], requested_expiry: expected_expiry, fields: Map.keys(v) |> Enum.sort()})

        seen = Stream.poll(s.uid, &(&1["readyToStream"] == true or get_in(&1, ["status", "state"]) == "error"))
        Ctx.fact(:small_observations, seen)
        last = List.last(seen) || %{}
        Ctx.assert(e, "small_fixture_ready_with_trusted_duration", true, last[:ready] == true and is_number(last[:duration]) and abs(last[:duration] - 10) <= 1, %{last: last})
        playback(e, s.uid, jwk, true)

      {:error, info} ->
        Ctx.assert(e, "reservation_metadata_applied", true, :unproven, info)
    end

    case long do
      {:ok, l} ->
        seen = Stream.poll(l.uid, &(&1["readyToStream"] == true or get_in(&1, ["status", "state"]) == "error"))
        Ctx.fact(:long_observations, seen)
        last = List.last(seen) || %{}
        Ctx.assert(e, "over_180s_fixture_rejected_by_max_duration", true, last[:state] == "error" and last[:ready] != true, %{last: last, fixture_seconds: 200})
        if jwk, do: playback(e, l.uid, jwk, false)

      {:error, info} ->
        Ctx.assert(e, "over_180s_fixture_rejected_by_max_duration", true, :unproven, info)
    end

    {ok_or_nil(small), ok_or_nil(long)}
  end

  defp ok_or_nil({:ok, r}), do: r
  defp ok_or_nil(_), do: nil

  defp same_instant?(nil, _), do: false

  defp same_instant?(a, b) do
    with {:ok, da, _} <- DateTime.from_iso8601(a), {:ok, db, _} <- DateTime.from_iso8601(b), do: DateTime.compare(da, db) == :eq
  end

  defp upload_whole(label, fx) do
    :ok = Stream.authorize_length(fx.bytes)
    reserve_started = Ctx.now_iso()

    with {:ok, r} <- own(Stream.reserve(label, fx.bytes, in_hour())) do
      data = File.read!(fx.path)
      start = Ctx.now_iso()
      {res, rec} = patch_all(r, data)
      finish = Ctx.now_iso()
      Ctx.fact({:transfer, label}, %{reserve_started: reserve_started, reserve_record_at: r.record.sent_at, transfer_start: start, transfer_end: finish, bytes: byte_size(data), final_status: status(res), final_headers: rec[:headers]})
      if status(res) == 204, do: {:ok, Map.merge(r, %{transfer_start: start, transfer_end: finish})}, else: {:error, %{transfer: rec}}
    end
  end

  # Chunks of 5,242,880 bytes (a multiple of 256 KiB); the final chunk may be shorter.
  defp patch_all(r, data, offset \\ 0) do
    rest = byte_size(data) - offset
    size = min(rest, @chunk)
    {res, rec} = Stream.patch(r, offset, binary_part(data, offset, size))

    if status(res) == 204 and offset + size < byte_size(data), do: patch_all(r, data, offset + size), else: {res, rec}
  end

  defp playback(e, uid, jwk, expect_ok?) do
    suffix = if expect_ok?, do: "", else: "_over_180s"
    {m, _} = Stream.cdn_get("unsigned-manifest", "/#{uid}/manifest/video.m3u8")
    {t, _} = Stream.cdn_get("unsigned-thumbnail", "/#{uid}/thumbnails/thumbnail.jpg")
    {i, irec} = Stream.cdn_get("unsigned-iframe", "/#{uid}/iframe")

    if expect_ok? do
      Ctx.assert(e, "unsigned_manifest_and_thumbnail_rejected", true, status(m) in 400..499 and status(t) in 400..499,
        %{manifest: status(m), thumbnail: status(t), iframe_status_informational: status(i), iframe_headers: irec[:headers]})
    end

    if jwk do
      signed_checks(e, uid, jwk, expect_ok?, suffix)
    else
      Ctx.assert(e, "signed_playback#{suffix}", true, :unproven, %{reason: "CLOUDFLARE_STREAM_SIGNING_KEY is not set"})
    end
  end

  defp signed_checks(e, uid, jwk, expect_ok?, suffix) do
    tok = Stream.token(uid, jwk)
    {m, mrec} = Stream.cdn_get("signed-manifest", "/#{tok}/manifest/video.m3u8")
    manifest = if status(m) == 200, do: elem(m, 1).body, else: ""

    if expect_ok? do
      segment = fetch_first_segment(manifest)
      {t, trec} = Stream.cdn_get("signed-thumbnail", "/#{tok}/thumbnails/thumbnail.jpg")
      thumb = if status(t) == 200, do: elem(t, 1).body, else: ""
      {i, irec} = Stream.cdn_get("signed-iframe", "/#{tok}/iframe")

      Ctx.assert(e, "signed_hls_manifest_and_segment_delivered", true, status(m) == 200 and String.starts_with?(manifest, "#EXTM3U") and segment[:ok] == true,
        %{manifest_status: status(m), manifest_type: mrec[:headers]["content-type"], segment: segment})

      Ctx.assert(e, "signed_poster_is_jpeg", true, status(t) == 200 and match?(<<0xFF, 0xD8, 0xFF, _::binary>>, thumb),
        %{status: status(t), content_type: trec[:headers]["content-type"], bytes: byte_size(thumb)})

      Ctx.assert(e, "signed_iframe_returns_player", false, if(status(i) == 200, do: :info, else: false),
        %{status: status(i), content_type: irec[:headers]["content-type"], note: "HTTP 200 alone proves neither playback nor privacy"})

      {x, _} = Stream.cdn_get("expired-token-manifest", "/#{Stream.token(uid, jwk, exp: System.system_time(:second) - 120)}/manifest/video.m3u8")
      wrong = JOSE.JWK.generate_key({:rsa, 2048}) |> JOSE.JWK.to_map() |> elem(1) |> Map.put("kid", jwk["kid"])
      {w, _} = Stream.cdn_get("wrong-key-manifest", "/#{Stream.token(uid, wrong)}/manifest/video.m3u8")
      Ctx.assert(e, "expired_and_wrong_key_tokens_rejected", true, status(x) in 400..499 and status(w) in 400..499, %{expired: status(x), wrong_key: status(w)})
    else
      Ctx.assert(e, "signed_manifest#{suffix}_not_playable", true, status(m) != 200, %{manifest_status: status(m)})
    end
  end

  defp fetch_first_segment(manifest) do
    with [variant | _] <- lines(manifest),
         {{:ok, %{status: 200, body: vbody}}, _} <- get_abs("signed-variant", variant),
         [seg | _] <- lines(vbody),
         {{:ok, %{status: 200, body: sbody}}, srec} <- get_abs("signed-segment", seg, variant) do
      %{ok: byte_size(sbody) > 0, bytes: byte_size(sbody), content_type: srec[:headers]["content-type"]}
    else
      other -> %{ok: false, detail: inspect(other) |> String.slice(0, 300)}
    end
  end

  defp lines(text), do: text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

  defp get_abs(label, ref, base \\ nil) do
    url =
      cond do
        String.starts_with?(ref, "http") -> ref
        base && String.starts_with?(base, "http") -> URI.merge(base, ref) |> to_string()
        String.starts_with?(ref, "/") -> Stream.host() <> ref
        base -> URI.merge(Stream.host() <> "/x/" <> base, ref) |> to_string()
        true -> Stream.host() <> "/" <> ref
      end

    Http.request(label, method: :get, url: url)
  end

  # --- stream_deadline ---------------------------------------------------------------

  defp deadline_experiment(fixtures, small) do
    e = "stream_deadline"
    completion_semantics(e, small)
    pause_resume(e, fixtures["two-chunk.mp4"])
    accelerated_expiry(e, fixtures["two-chunk.mp4"])
    lost_response(e)
    latency(e)
  end

  defp completion_semantics(e, nil), do: Ctx.assert(e, "readiness_is_separate_from_completion", true, :unproven, %{reason: "small upload failed"})

  defp completion_semantics(e, s) do
    obs = Ctx.facts()[:small_observations] || []
    {:ok, v, rec} = Stream.video(s.uid)
    delayed = Stream.observation(v)
    uploaded = v["uploaded"]
    server_date = rec.headers["date"]
    skew = skew_seconds(server_date, rec.sent_at)
    {:ok, up, _} = DateTime.from_iso8601(uploaded || "1970-01-01T00:00:00Z")
    {:ok, ts, _} = DateTime.from_iso8601(s.transfer_start)
    {:ok, te, _} = DateTime.from_iso8601(s.transfer_end)
    tol = 5 + abs(skew)
    within = DateTime.diff(up, ts, :millisecond) >= -tol * 1000 and DateTime.diff(up, te, :millisecond) <= tol * 1000
    stable = obs |> Enum.map(& &1.uploaded) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Kernel.++([uploaded]) |> Enum.uniq() |> length() == 1

    Ctx.assert(e, "small_transfer_uploaded_near_reservation_and_completion", false, if(uploaded != nil and within and stable, do: :info, else: false),
      %{created: v["created"], transfer: Ctx.facts()[{:transfer, "private-small"}], uploaded: uploaded, ready_at: v["readyToStreamAt"], delayed_observation: delayed,
        clock_skew_s: skew, tolerance_s: tol, uploaded_stable_across_observations: stable, observations: length(obs)})

    ready_after = v["readyToStreamAt"] && elem(DateTime.from_iso8601(v["readyToStreamAt"]), 1) |> DateTime.compare(up) != :lt
    Ctx.assert(e, "readiness_is_separate_from_completion", true, ready_after == true, %{uploaded: uploaded, ready_at: v["readyToStreamAt"]})
  end

  # True when ISO timestamp a is earlier than b by more than `slack_s` seconds of tolerance.
  defp before?(a, b, slack_s) do
    {:ok, da, _} = DateTime.from_iso8601(a)
    {:ok, db, _} = DateTime.from_iso8601(b)
    DateTime.diff(da, db, :millisecond) < slack_s * 1000
  end

  defp skew_seconds(nil, _), do: 0

  defp skew_seconds(http_date, sent_at) do
    with {:ok, d} <- parse_http_date(http_date), {:ok, s, _} <- DateTime.from_iso8601(sent_at), do: DateTime.diff(d, s), else: (_ -> 0)
  end

  defp parse_http_date(v) do
    case :httpd_util.convert_request_date(String.to_charlist(v)) do
      :bad_date -> :error
      erl -> {:ok, erl |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC")}
    end
  end

  defp pause_resume(e, fx) do
    data = File.read!(fx.path)
    true = byte_size(data) > @chunk

    case own(Stream.reserve("pause-resume", byte_size(data), in_hour())) do
      {:ok, r} ->
        {:ok, v0, _} = Stream.video(r.uid)
        {{:ok, h0}, _} = Stream.head(r)
        first_sent_at = Ctx.now_iso()
        {p1, _} = Stream.patch(r, 0, binary_part(data, 0, @chunk))
        {:ok, v1, _} = Stream.video(r.uid)
        {{:ok, h1}, _} = Stream.head(r)
        Process.sleep(20_000)
        {:ok, v2, _} = Stream.video(r.uid)
        final_sent_at = Ctx.now_iso()
        {p2, _} = Stream.patch(r, @chunk, binary_part(data, @chunk, byte_size(data) - @chunk))
        done_at = Ctx.now_iso()
        {:ok, v3, _} = Stream.video(r.uid)
        {h3res, _} = Stream.head(r)

        before = %{expiry: v0["uploadExpiry"], head_expires: Http.header(h0, "upload-expires"), uploaded: v0["uploaded"], created: v0["created"], modified: v0["modified"], state: get_in(v0, ["status", "state"])}
        mid = %{expiry: v1["uploadExpiry"], head_expires: Http.header(h1, "upload-expires"), offset: Http.header(h1, "upload-offset"), uploaded: v1["uploaded"], modified: v1["modified"], state: get_in(v1, ["status", "state"])}
        paused = %{expiry: v2["uploadExpiry"], uploaded: v2["uploaded"], modified: v2["modified"], state: get_in(v2, ["status", "state"])}
        after_ = %{expiry: v3["uploadExpiry"], uploaded: v3["uploaded"], modified: v3["modified"], state: get_in(v3, ["status", "state"]), head_status: status(h3res)}
        transfer = %{reserved_request_at: r.record.sent_at, first_chunk_sent_at: first_sent_at, final_chunk_sent_at: final_sent_at, final_chunk_acknowledged_at: done_at}

        Ctx.assert(e, "pause_resume_does_not_extend_expiry", true,
          status(p1) == 204 and status(p2) == 204 and before.expiry != nil and before.expiry == mid.expiry and mid.expiry == after_.expiry,
          %{before: before, after_first_chunk: mid, paused: paused, after_resume: after_, transfer: transfer})

        # The discriminating case: a 20 s pause separates reservation from the last byte.
        Ctx.assert(e, "uploaded_is_transfer_completion", true, after_.uploaded != nil and not before?(after_.uploaded, final_sent_at, -1),
          %{uploaded: after_.uploaded, created: before.created, transfer: transfer, uploaded_set_before_any_byte: before.uploaded != nil,
            uploaded_changed_after_completion: before.uploaded != after_.uploaded})

        Ctx.assert(e, "modified_moves_when_transfer_completes", false, :info,
          %{modified_before: before.modified, modified_paused: paused.modified, modified_after: after_.modified, state_after: after_.state,
            note: "modified is a general last-change field; later processing changes it again"})

      {:error, rec} ->
        Ctx.assert(e, "pause_resume_does_not_extend_expiry", true, :unproven, rec)
    end
  end

  # Shortest accepted expiry: late start and late finish after it has passed.
  defp accelerated_expiry(e, fx) do
    data = File.read!(fx.path)

    {window, probe} =
      Enum.reduce_while([60, 120, 130, 180, 300], {nil, []}, fn secs, {_, tried} ->
        exp = DateTime.add(DateTime.utc_now(), secs, :second)

        case own(Stream.reserve("expiry-late-finish-#{secs}", byte_size(data), exp)) do
          {:ok, r} -> {:halt, {{secs, exp, r}, tried ++ [%{seconds: secs, status: 201}]}}
          {:error, rec} -> {:cont, {nil, tried ++ [%{seconds: secs, status: rec.status, body: rec[:body]}]}}
        end
      end)

    Ctx.fact(:expiry_window_probe, probe)

    case window do
      nil ->
        Ctx.assert(e, "late_transfers_rejected_after_expiry", true, :unproven, %{tried: probe})

      {secs, exp, finish_r} ->
        start_r = own(Stream.reserve("expiry-late-start-#{secs}", byte_size(data), exp))
        {f1, _} = Stream.patch(finish_r, 0, binary_part(data, 0, @chunk))
        wait_ms = max(DateTime.diff(exp, DateTime.utc_now(), :millisecond) + 30_000, 0)
        Process.sleep(wait_ms)
        {f2, f2rec} = Stream.patch(finish_r, @chunk, binary_part(data, @chunk, byte_size(data) - @chunk))

        late_start =
          case start_r do
            {:ok, r} ->
              {s1, srec} = Stream.patch(r, 0, binary_part(data, 0, @chunk))
              {:ok, v, _} = Stream.video(r.uid)
              %{status: status(s1), headers: srec[:headers], body: srec[:body], video: Stream.observation(v)}

            {:error, rec} ->
              %{reservation_failed: rec.status}
          end

        {:ok, fv, _} = Stream.video(finish_r.uid)

        Ctx.assert(e, "late_transfers_rejected_after_expiry", true,
          status(f1) == 204 and status(f2) in 400..499 and late_start[:status] in 400..499 and get_in(fv, ["status", "state"]) == "pendingupload",
          %{expiry_seconds: secs, tried: probe, late_finish_first_chunk: status(f1), late_finish_final: Map.take(f2rec, [:status, :headers, :body]), late_finish_video: Stream.observation(fv), late_start: late_start,
            note: "accelerated expiry; does not by itself prove one-hour enforcement"})

        Ctx.assert(e, "one_hour_expiry_enforced", true, :unproven, %{reason: "run `stream-hour` for the full one-hour experiment", accepted_one_hour_metadata: true})
    end
  end

  # A creation whose response is lost: the client gives up almost immediately; no retry.
  defp lost_response(e) do
    before = Ctx.calls()
    result = Stream.reserve("lost-response", 1_048_576, in_hour(), receive_timeout: 1)
    attempts = Ctx.calls() - before
    Process.sleep(5_000)
    {:ok, found, _} = Stream.search(Stream.name("lost-response"))
    matches = Enum.filter(found || [], &(get_in(&1, ["meta", "name"]) == Stream.name("lost-response")))
    Enum.each(matches, &:ets.insert(:persistent_term.get(:probe_owned), {&1["uid"], "lost-response"}))
    Enum.each(matches, &Ctx.inventory(%{kind: "stream", label: "lost-response", name: Stream.name("lost-response"), uid: &1["uid"], phase: "discovered"}))

    Ctx.assert(e, "lost_creation_response_not_retried", true, attempts == 1 and match?({:error, _}, result),
      %{client_result: elem(result, 0), creation_attempts: attempts, provider_records_found_by_name: length(matches),
        provider_state: Enum.map(matches, &Stream.observation/1),
        note: "a reservation can exist at the provider with no uid known to the caller"})
  end

  defp latency(e) do
    reserves =
      Ctx.ctx().calls_log
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(String.starts_with?(&1["label"], "reserve:") and &1["status"] == 201))
      |> Enum.map(& &1["ms"])
      |> Enum.sort()

    Ctx.assert(e, "creation_latency_measured", false, :info, %{count: length(reserves), min_ms: List.first(reserves), p50_ms: Enum.at(reserves, div(length(reserves), 2)), max_ms: List.last(reserves)})
  end

  # --- deletion ends serving -----------------------------------------------------------

  defp delete_experiment(nil, _long, _jwk), do: :ok

  defp delete_experiment(s, _long, jwk) do
    e = "redaction_cleanup"
    {d1, _} = Stream.delete(s.uid)
    {_d2, d2rec} = Stream.delete(s.uid)
    {g, _} = Http.request("video-after-delete", method: :get, url: "#{Stream.base()}/#{s.uid}", headers: [{"authorization", "Bearer " <> Ctx.fetch!("CLOUDFLARE_STREAM_API_TOKEN")}])

    served =
      if jwk do
        Process.sleep(5_000)
        {m, _} = Stream.cdn_get("signed-manifest-after-delete", "/#{Stream.token(s.uid, jwk)}/manifest/video.m3u8")
        status(m)
      end

    :ets.delete(:persistent_term.get(:probe_owned), s.uid)
    Ctx.inventory(%{kind: "stream", label: s.label, uid: s.uid, phase: "deleted", status: status(d1)})

    Ctx.assert(e, "stream_delete_is_terminal_and_ends_signed_serving", true,
      status(d1) == 200 and status(g) == 404 and (served == nil or served != 200),
      %{first_delete: status(d1), repeated_delete: Map.take(d2rec, [:status, :body]), api_get_after: status(g), signed_manifest_after_delete: served || "unproven: no signing key"})

    if served == nil, do: Ctx.assert(e, "signed_serving_after_delete", true, :unproven, %{reason: "no signing key"})
  end

  def cleanup_owned do
    owned = :ets.tab2list(:persistent_term.get(:probe_owned))

    results =
      for {uid, label} <- owned do
        {d, _} = Stream.delete(uid)
        {g, _} = Http.request("confirm-deleted:#{uid}", method: :get, url: "#{Stream.base()}/#{uid}", headers: [{"authorization", "Bearer " <> Ctx.fetch!("CLOUDFLARE_STREAM_API_TOKEN")}])
        Ctx.inventory(%{kind: "stream", label: label, uid: uid, phase: "deleted", status: status(d), confirm: status(g)})
        %{uid: uid, label: label, delete: status(d), get_after: status(g)}
      end

    Ctx.fact(:inline_cleanup, results)
    Ctx.assert("redaction_cleanup", "stream_inline_cleanup", true, Enum.all?(results, &(&1.get_after == 404)), %{deleted: results})
  end
end

defmodule MediaProbe.HourRun do
  @moduledoc false
  alias MediaProbe.{Ctx, Stream}

  # Full one-hour enforcement: first chunk at once, final chunk 61 minutes later.
  def run do
    fx = MediaProbe.Fixtures.videos(Path.join(Ctx.ctx().out, "video-fixtures"))["two-chunk.mp4"]
    data = File.read!(fx.path)
    chunk = 5_242_880
    exp = DateTime.add(DateTime.utc_now(), 3600, :second)

    case Stream.reserve("hour-late-finish", byte_size(data), exp) do
      {:ok, r} ->
        {f1, _} = Stream.patch(r, 0, binary_part(data, 0, chunk))
        {:ok, v0, _} = Stream.video(r.uid)
        Process.sleep(max(DateTime.diff(exp, DateTime.utc_now(), :millisecond) + 60_000, 0))
        {f2, f2rec} = Stream.patch(r, chunk, binary_part(data, chunk, byte_size(data) - chunk))
        {:ok, v1, _} = Stream.video(r.uid)
        {d, _} = Stream.delete(r.uid)
        {g, _} = MediaProbe.Http.request("confirm-deleted", method: :get, url: "#{Stream.base()}/#{r.uid}", headers: [{"authorization", "Bearer " <> Ctx.fetch!("CLOUDFLARE_STREAM_API_TOKEN")}])
        Ctx.inventory(%{kind: "stream", label: r.label, uid: r.uid, phase: "deleted", status: elem(f2, 0), confirm: MediaProbe.Http.header(elem(g, 1), "date")})

        Ctx.assert("stream_deadline", "one_hour_expiry_enforced", true,
          match?({:ok, %{status: 204}}, f1) and match?({:ok, %{status: s}} when s in 400..499, f2) and get_in(v1, ["status", "state"]) == "pendingupload",
          %{requested_expiry: DateTime.to_iso8601(exp), provider_expiry: v0["uploadExpiry"], first_chunk: elem(f1, 1).status, final_after_expiry: Map.take(f2rec, [:status, :headers, :body]), video_after: Stream.observation(v1)})

        Ctx.assert("redaction_cleanup", "hour_fixture_deleted", true, match?({:ok, %{status: 404}}, g), %{delete: elem(d, 1).status})

      {:error, rec} ->
        Ctx.assert("stream_deadline", "one_hour_expiry_enforced", true, :unproven, rec)
    end
  end
end

defmodule MediaProbe.R2Run do
  @moduledoc false
  alias MediaProbe.{Ctx, Http}

  defp sigv4, do: [access_key_id: Ctx.fetch!("R2_ACCESS_KEY_ID"), secret_access_key: Ctx.fetch!("R2_SECRET_ACCESS_KEY"), service: :s3, region: "auto"]
  defp s3_url(key), do: "#{String.trim_trailing(Ctx.fetch!("R2_ENDPOINT"), "/")}/#{Ctx.fetch!("R2_BUCKET")}/#{key}"
  defp public_url(key), do: "#{String.trim_trailing(Ctx.fetch!("R2_PUBLIC_URL"), "/")}/#{key}"
  def prefix, do: "media/probe-61/"

  def s3(label, method, key, opts \\ []), do: Http.request(label, [method: method, url: s3_url(key), aws_sigv4: sigv4()] ++ opts)

  def list(prefix) do
    {res, _} = Http.request("s3-list", method: :get, url: "#{String.trim_trailing(Ctx.fetch!("R2_ENDPOINT"), "/")}/#{Ctx.fetch!("R2_BUCKET")}", params: ["list-type": 2, prefix: prefix], aws_sigv4: sigv4())
    {:ok, %{status: 200, body: body}} = res
    Regex.scan(~r{<Key>([^<]+)</Key>}, body, capture: :all_but_first) |> List.flatten()
  end

  def run do
    e = "r2_roundtrip"
    run_prefix = "#{prefix()}#{Ctx.ctx().run_id}/"
    {png, gif} = fixtures()
    objects = [{"#{run_prefix}#{uuid()}.png", png, "image/png"}, {"#{run_prefix}#{uuid()}.gif", gif, "image/gif"}]
    Ctx.fact(:r2_objects, Enum.map(objects, fn {k, b, t} -> %{key: k, bytes: byte_size(b), sha256: Http.sha(b), content_type: t} end))

    try do
      for {key, bin, type} <- objects, do: roundtrip(e, key, bin, type)
      remaining = list(run_prefix)
      Ctx.assert(e, "list_prefix_empty_after_delete", true, remaining == [], %{prefix: run_prefix, remaining: remaining})
    after
      for key <- list(run_prefix) do
        s3("cleanup-delete", :delete, key)
        Ctx.inventory(%{kind: "r2", key: key, phase: "deleted-in-cleanup"})
      end
    end
  end

  defp fixtures do
    dir = Path.join(Ctx.ctx().out, "r2-fixtures")
    File.mkdir_p!(dir)
    src = ~w(-f lavfi -i testsrc=size=64x48:rate=5:duration=1)

    for {name, extra} <- [{"static.png", ~w(-frames:v 1)}, {"animated.gif", ~w(-loop 0)}] do
      {_, 0} = System.cmd("ffmpeg", ~w(-hide_banner -loglevel error -y) ++ src ++ extra ++ [Path.join(dir, name)])
    end

    Ctx.fact(:r2_fixture_recipes, %{"static.png" => "ffmpeg testsrc 64x48 -frames:v 1", "animated.gif" => "ffmpeg testsrc 64x48 5 fps 1 s -loop 0"})
    {File.read!(Path.join(dir, "static.png")), File.read!(Path.join(dir, "animated.gif"))}
  end

  # Server-generated key shape from the data model: media/{uuid}.{ext}, under the probe prefix.
  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e]) |> to_string()
  end

  defp roundtrip(e, key, bin, type) do
    Ctx.inventory(%{kind: "r2", key: key, phase: "requested"})
    {put, _} = s3("s3-put", :put, key, body: bin, headers: [{"content-type", type}])
    {get, grec} = s3("s3-get", :get, key)
    {pub1, p1} = Http.request("public-get-1", method: :get, url: public_url(key))
    {pub2, p2} = Http.request("public-get-2", method: :get, url: public_url(key))
    body_ok = fn r -> match?({:ok, %{status: 200}}, r) and elem(r, 1).body == bin end

    Ctx.assert(e, "put_then_s3_and_public_reads_return_trusted_bytes_and_type:#{Path.extname(key)}", true,
      match?({:ok, %{status: 200}}, put) and body_ok.(get) and body_ok.(pub1) and grec.headers["content-type"] == type and p1.headers["content-type"] == type,
      %{key: key, sha256: Http.sha(bin), s3_get: Map.take(grec, [:status, :headers]), public_get_1: Map.take(p1, [:status, :headers]), public_get_2: Map.take(p2, [:status, :headers]), public_second_ok: body_ok.(pub2)})

    {del1, d1} = s3("s3-delete", :delete, key)
    Ctx.inventory(%{kind: "r2", key: key, phase: "deleted", status: d1.status})
    {get_after, ga} = s3("s3-get-after-delete", :get, key)
    {pub_after, pa} = Http.request("public-get-after-delete", method: :get, url: public_url(key))
    Process.sleep(3_000)
    {pub_after2, pa2} = Http.request("public-get-after-delete-3s", method: :get, url: public_url(key))
    {del2, d2} = s3("s3-delete-repeat", :delete, key)

    Ctx.assert(e, "delete_is_immediate_at_origin_and_public_dev_url:#{Path.extname(key)}", true,
      match?({:ok, %{status: 204}}, del1) and match?({:ok, %{status: 404}}, get_after) and match?({:ok, %{status: 404}}, pub_after) and match?({:ok, %{status: 404}}, pub_after2),
      %{delete: d1.status, s3_get_after: ga.status, public_after: Map.take(pa, [:status, :headers]), public_after_3s: Map.take(pa2, [:status, :headers])})

    Ctx.assert(e, "repeated_delete_is_idempotent:#{Path.extname(key)}", true, match?({:ok, %{status: 204}}, del2), %{repeat_delete: d2.status})
  end
end

defmodule MediaProbe.CleanupRun do
  @moduledoc false
  alias MediaProbe.{Ctx, Http, Stream, R2Run}

  # Reconciles every inventory record from every run: owned Stream uids, reservations
  # discovered by name, and the R2 probe prefix.
  def run do
    entries =
      Path.wildcard(Path.join([Ctx.ctx().out, "inventory", "*.jsonl"]))
      |> Enum.flat_map(fn f -> f |> File.stream!() |> Enum.map(&Jason.decode!/1) end)

    uids = entries |> Enum.filter(&(&1["kind"] == "stream" and &1["uid"])) |> Enum.map(& &1["uid"]) |> Enum.uniq()
    {:ok, named, _} = Stream.search("tips-probe-61-")
    named_uids = named |> Enum.filter(&String.starts_with?(get_in(&1, ["meta", "name"]) || "", "tips-probe-61-")) |> Enum.map(& &1["uid"])
    all = Enum.uniq(uids ++ named_uids)

    stream =
      for uid <- all do
        {g, _} = get(uid)

        if status(g) == 404 do
          %{uid: uid, result: "already_deleted"}
        else
          {d, _} = Stream.delete(uid)
          {g2, _} = get(uid)
          %{uid: uid, result: if(status(g2) == 404, do: "deleted", else: "still_present"), delete: status(d), get_after: status(g2)}
        end
      end

    {:ok, leftover, _} = Stream.search("tips-probe-61-")
    leftover = Enum.filter(leftover, &String.starts_with?(get_in(&1, ["meta", "name"]) || "", "tips-probe-61-"))

    r2_before = R2Run.list(R2Run.prefix())
    for key <- r2_before, do: R2Run.s3("cleanup-delete", :delete, key)
    r2_after = R2Run.list(R2Run.prefix())
    requested_names = entries |> Enum.filter(&(&1["kind"] == "stream")) |> Enum.map(& &1["name"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Ctx.assert("redaction_cleanup", "every_owned_stream_uid_deleted", true, Enum.all?(stream, &(&1.result in ["already_deleted", "deleted"])) and leftover == [],
      %{inventory_files: length(Path.wildcard(Path.join([Ctx.ctx().out, "inventory", "*.jsonl"]))), requested_reservations: length(requested_names), uids: stream, remaining_by_name: Enum.map(leftover, & &1["uid"])})

    Ctx.assert("redaction_cleanup", "r2_probe_prefix_empty", true, r2_after == [], %{prefix: R2Run.prefix(), deleted_now: r2_before, remaining: r2_after})
  end

  defp get(uid), do: Http.request("cleanup-get:#{uid}", method: :get, url: "#{Stream.base()}/#{uid}", headers: [{"authorization", "Bearer " <> Ctx.fetch!("CLOUDFLARE_STREAM_API_TOKEN")}])
  defp status({:ok, r}), do: r.status
  defp status(_), do: nil
end

defmodule MediaProbe.SigningKey do
  @moduledoc false
  alias MediaProbe.{Ctx, Http, Stream}

  # Creates one Stream signing key and stores its base64 JWK in the owner's env file as
  # CLOUDFLARE_STREAM_SIGNING_KEY. Refuses before creating a key when it cannot store it.
  def run do
    file = Ctx.ctx().env_file

    cond do
      Ctx.get("CLOUDFLARE_STREAM_SIGNING_KEY") != "" ->
        Ctx.assert("stream_private", "signing_key_available", true, true, %{created: false, reason: "already set"})

      not writable?(file) ->
        Ctx.assert("stream_private", "signing_key_available", true, :unproven, %{created: false, reason: "secret store #{Path.basename(file)} is not writable; no key created"})

      true ->
        {res, rec} = Http.request("create-signing-key", method: :post, url: Stream.base() <> "/keys", headers: [{"authorization", "Bearer " <> Ctx.fetch!("CLOUDFLARE_STREAM_API_TOKEN")}])

        with {:ok, %{status: 200, body: body}} <- res do
          %{"id" => id, "jwk" => jwk, "pem" => pem} = Jason.decode!(body)["result"]
          Ctx.add_secret(jwk)
          Ctx.add_secret(pem)
          File.write!(file, "\n# Cloudflare Stream signing key #{id} (created #{Date.utc_today()} by the #61 probe)\nCLOUDFLARE_STREAM_SIGNING_KEY=#{jwk}\n", [:append])
          Ctx.assert("stream_private", "signing_key_available", true, true, %{created: true, key_id: id, stored_in: Path.basename(file)})
        else
          _ -> Ctx.assert("stream_private", "signing_key_available", true, false, %{status: rec.status, body: rec[:body]})
        end
    end
  end

  defp writable?(file) do
    case File.stat(file) do
      {:ok, %{access: access}} -> access in [:write, :read_write]
      _ -> false
    end
  end
end

defmodule MediaProbe.Main do
  @moduledoc false
  alias MediaProbe.{Ctx, Redact}

  def main([mode, out]) do
    ctx = Ctx.new(mode, out)
    IO.puts("run #{ctx.run_id} mode=#{mode}")

    crashed =
      try do
        case mode do
          "stream" -> MediaProbe.StreamRun.run()
          "stream-hour" -> MediaProbe.HourRun.run()
          "r2" -> MediaProbe.R2Run.run()
          "cleanup" -> MediaProbe.CleanupRun.run()
          "signing-key" -> MediaProbe.SigningKey.run()
        end

        nil
      rescue
        e -> Exception.format(:error, e, __STACKTRACE__)
      end

    if crashed, do: Ctx.assert("probe", "completed_without_crash", true, false, %{error: crashed})
    report(ctx)
  end

  defp report(ctx) do
    assertions = Ctx.assertions()
    required_bad = Enum.filter(assertions, &(&1.required and &1.status in ["fail", "unproven"]))

    report = %{
      issue: 61,
      mode: ctx.mode,
      run_id: ctx.run_id,
      git_sha: git_sha(),
      finished_at: Ctx.now_iso(),
      versions: %{elixir: System.version(), otp: System.otp_release(), req: "0.7.4", jose: "1.11.12", tus: "1.0.0", stream_api: "client/v4 (unversioned)"},
      bounds: %{provider_calls: Ctx.calls(), max_calls: Ctx.max_calls(), concurrency: 1, retries: 0, receive_timeout_ms: 30_000, connect_timeout_ms: 10_000},
      facts: Ctx.facts() |> Map.new(fn {k, v} -> {inspect(k), v} end),
      assertions: assertions,
      verdict: if(required_bad == [], do: "pass", else: "fail")
    }

    json = report |> Jason.encode!(pretty: true) |> Redact.text()
    leaks = Redact.leaks(json)
    ok_redaction = leaks == %{secret_values: 0, jwt_like: 0, upload_urls: 0}
    path = Path.join(ctx.out, "#{ctx.mode}-#{ctx.run_id}.json")
    File.write!(path, json)
    IO.puts("redaction check: #{inspect(leaks)}")
    IO.puts("#{ctx.mode}: #{report.verdict}; #{length(required_bad)} required fail/unproven; report #{path}")
    System.halt(if report.verdict == "pass" and ok_redaction, do: 0, else: 1)
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"]) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end
end

MediaProbe.Main.main(System.argv())
