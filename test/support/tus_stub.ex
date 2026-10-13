defmodule Tips.TusStub do
  @moduledoc """
  A tus endpoint and Stream API stub for browser tests (D14).

  `TipsWeb.Endpoint` mounts this plug under the `:sql_sandbox` compile flag
  at `/tus-stub/:uid`, on the page's own origin:

    * `HEAD` answers the upload's `Upload-Offset` and `Upload-Length`.
    * `PATCH` reads the chunk, waits `?hold=<ms>`, then appends the chunk's
      `content-length`, at most `?cap=<bytes>`, when its `Upload-Offset` is
      the stored one (otherwise 409), and answers the new offset. A capped
      chunk makes tus send the rest in another PATCH.

  `stub_stream/1` answers the shared `Req.Test` Stream stub: a reservation
  registers its uid and declared length here and points `location` at this
  plug; a status read says `pendingupload` until every byte arrived, then
  `ready` with a duration of 2 s. Start the state with
  `start_supervised!(Tips.TusStub)`.
  """
  @behaviour Plug

  use Agent

  import Plug.Conn

  alias Tips.Content.Media.CloudflareStream

  @typedoc "One reservation: its declared length, stored offset and PATCH counts."
  @type upload :: %{
          length: pos_integer(),
          offset: non_neg_integer(),
          patches: non_neg_integer(),
          answered: non_neg_integer()
        }

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "The upload `uid`, or `nil`."
  @spec upload(String.t()) :: upload() | nil
  def upload(uid), do: Agent.get(__MODULE__, & &1[uid])

  @doc """
  Stubs Stream for every process. Reservations are reported to the calling
  process as `{:reserved, uid}`; `params` (`hold`, `cap`) go on the endpoint.
  """
  @spec stub_stream(keyword()) :: :ok
  def stub_stream(params \\ []) do
    test = self()
    query = if params == [], do: "", else: "?" <> URI.encode_query(params)

    Req.Test.stub(CloudflareStream, fn
      %{method: "POST"} = conn ->
        uid = "uid#{System.unique_integer([:positive])}"
        [length] = get_req_header(conn, "upload-length")
        upload = %{length: String.to_integer(length), offset: 0, patches: 0, answered: 0}
        Agent.update(__MODULE__, &Map.put(&1, uid, upload))
        send(test, {:reserved, uid})

        conn
        |> put_resp_header("location", "#{TipsWeb.Endpoint.url()}/tus-stub/#{uid}#{query}")
        |> put_resp_header("stream-media-id", uid)
        |> send_resp(201, "")

      %{method: "GET", request_path: "/client/v4/accounts/synthetic-account/stream/" <> uid} =
          conn ->
        %{length: length, offset: offset} = upload(uid)
        state = if offset == length, do: "ready", else: "pendingupload"
        video = %{"status" => %{"state" => state}, "readyToStream" => state == "ready"}
        body = JSON.encode!(%{"result" => Map.put(video, "duration", 2)})

        conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    end)
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{path_info: ["tus-stub", uid]} = conn, _opts) do
    conn = fetch_query_params(conn)

    case {conn.method, upload(uid)} do
      {_method, nil} ->
        conn |> send_resp(404, "") |> halt()

      {"HEAD", upload} ->
        conn |> tus(upload.offset, upload.length) |> send_resp(200, "") |> halt()

      {"PATCH", _upload} ->
        conn |> patch(uid) |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp patch(conn, uid) do
    {bytes, conn} = read_all(conn, 0)
    count(uid, :patches)
    Process.sleep(String.to_integer(conn.query_params["hold"] || "0"))

    offset = conn |> get_req_header("upload-offset") |> hd() |> String.to_integer()
    cap = String.to_integer(conn.query_params["cap"] || "#{bytes}")

    # A chunk held past its test finds another test's uploads.
    stored =
      Agent.get_and_update(__MODULE__, fn
        %{^uid => %{offset: ^offset} = upload} = uploads ->
          upload = %{upload | offset: offset + min(bytes, cap), answered: upload.answered + 1}
          {{:appended, upload}, Map.put(uploads, uid, upload)}

        %{^uid => upload} = uploads ->
          {:conflict, Map.put(uploads, uid, %{upload | answered: upload.answered + 1})}

        uploads ->
          {:gone, uploads}
      end)

    case stored do
      {:appended, upload} -> conn |> tus(upload.offset, upload.length) |> send_resp(204, "")
      :conflict -> send_resp(conn, 409, "")
      :gone -> send_resp(conn, 404, "")
    end
  end

  defp count(uid, key) do
    Agent.update(__MODULE__, fn
      %{^uid => _upload} = uploads -> update_in(uploads[uid][key], &(&1 + 1))
      uploads -> uploads
    end)
  end

  defp read_all(conn, total) do
    case read_body(conn, length: 8_000_000) do
      {:ok, chunk, conn} -> {total + byte_size(chunk), conn}
      {:more, chunk, conn} -> read_all(conn, total + byte_size(chunk))
    end
  end

  defp tus(conn, offset, length) do
    conn
    |> put_resp_header("tus-resumable", "1.0.0")
    |> put_resp_header("upload-offset", Integer.to_string(offset))
    |> put_resp_header("upload-length", Integer.to_string(length))
    |> put_resp_header("cache-control", "no-store")
  end
end
