defmodule Tips.R2Stub do
  @moduledoc """
  A `Req.Test` stub of the R2 bucket for listing and deletion.

  `pages` maps a continuation token (`nil` for the first page) to
  `{[{key, last_modified}], next_token}`, an HTTP status, `:block`, which
  holds the request until it is killed, or a function the request calls for
  one of those. `delete` returns the status for a key, or `:block`. Each
  request is reported to the test process as
  `{:list, query_params, pid}` or `{:delete, key, pid}`, and each blocked
  request as `{:blocked, pid}`.
  """

  alias Tips.Content.Media.R2

  def stub(pages, delete \\ fn _key -> 204 end) do
    test = self()

    Req.Test.stub(R2, fn
      %{method: "GET"} = conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test, {:list, conn.query_params, self()})

        respond(conn, Map.fetch!(pages, conn.query_params["continuation-token"]), test)

      %{method: "DELETE", request_path: "/tips-test/" <> key} = conn ->
        send(test, {:delete, key, self()})

        case delete.(key) do
          :block -> block(test)
          status -> Plug.Conn.send_resp(conn, status, "")
        end
    end)
  end

  @doc "The keys deleted since the last call, in request order."
  def deletes do
    receive do
      {:delete, key, _pid} -> [key | deletes()]
    after
      0 -> []
    end
  end

  def image_key(prefix \\ "media/"), do: "#{prefix}#{Ecto.UUID.generate()}.png"

  defp respond(conn, page, test) when is_function(page, 0), do: respond(conn, page.(), test)

  defp respond(conn, {objects, next}, _test),
    do: Plug.Conn.send_resp(conn, 200, listing(objects, next))

  defp respond(_conn, :block, test), do: block(test)
  defp respond(conn, status, _test), do: Plug.Conn.send_resp(conn, status, "")

  defp block(test) do
    send(test, {:blocked, self()})
    Process.sleep(:infinity)
  end

  defp listing(objects, next) do
    contents =
      for {key, at} <- objects do
        "<Contents><Key>#{key}</Key><LastModified>#{DateTime.to_iso8601(at)}</LastModified>" <>
          "<Size>1</Size></Contents>"
      end

    token = if next, do: "<NextContinuationToken>#{next}</NextContinuationToken>", else: ""

    ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
      ~s(<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">) <>
      "<Name>tips-test</Name><IsTruncated>#{next != nil}</IsTruncated>" <>
      "#{contents}#{token}</ListBucketResult>"
  end
end
