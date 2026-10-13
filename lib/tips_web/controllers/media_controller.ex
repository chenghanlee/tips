defmodule TipsWeb.MediaController do
  @moduledoc """
  Redirects an authorized request to a freshly signed Stream destination.

  Each request decides access from current rows (`Tips.Content.get_media_access/2`);
  every denial is a 404. Responses are never cached, and signed URLs, tokens and
  uids are never logged.
  """

  use TipsWeb, :controller

  require Logger

  alias Tips.Content
  alias Tips.Content.Media.StreamSigner
  alias TipsWeb.UserAuth

  def watch(conn, %{"id" => id}), do: signed_redirect(conn, id, :iframe)

  def thumbnail(conn, %{"id" => id}), do: signed_redirect(conn, id, :thumbnail)

  defp signed_redirect(conn, id, kind) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")

    case Content.get_media_access(UserAuth.viewer(conn), id) do
      {:ok, %{stream_uid: uid}} -> redirect_to_stream(conn, id, kind, uid)
      {:error, :not_found} -> error_page(conn, 404)
    end
  end

  defp redirect_to_stream(conn, id, kind, uid) do
    redirect(conn, external: StreamSigner.destination(kind, uid, DateTime.utc_now()))
  rescue
    error in StreamSigner.ConfigError ->
      Logger.error("Media #{id}: signing unavailable: #{Exception.message(error)}")
      error_page(conn, 500)
  end

  defp error_page(conn, status) do
    conn
    |> put_status(status)
    |> put_root_layout(false)
    |> put_view(html: TipsWeb.ErrorHTML)
    |> render(:"#{status}")
  end
end
