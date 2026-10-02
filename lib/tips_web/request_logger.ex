defmodule TipsWeb.RequestLogger do
  @moduledoc """
  The endpoint's request lines, written only from what the router decided.

  Phoenix's endpoint logger prints the raw request path when the request
  starts, before routing. The magic-link and email-confirmation routes carry
  their token as a path segment, and any check made before routing can
  disagree with the router (HEAD handling, percent-decoding, empty segments).
  So the endpoint's `Plug.Telemetry` has `log: false` and this module logs:

      GET /users/log-in/:token
      Sent 200 in 12ms

  The first line is written when the router dispatches, from its own match:
  the route pattern when the route has a `token` path parameter, the request
  path otherwise. The method is the one the router matched, so a HEAD request
  logs as GET. The second line is written for every request. A request the
  router does not serve gets no path line: its path is never logged.

  Endpoint and router telemetry are unchanged.
  """

  require Logger

  @events [[:phoenix, :router_dispatch, :start], [:phoenix, :endpoint, :stop]]

  @doc "Attaches the logger. Call it once, when the application starts."
  def attach do
    :telemetry.attach_many(__MODULE__, @events, &__MODULE__.handle_event/4, nil)
  end

  @doc false
  def handle_event([:phoenix, :router_dispatch, :start], _measurements, metadata, _config) do
    %{conn: conn, route: route, path_params: path_params} = metadata
    Logger.info([conn.method, ?\s, logged_path(conn, route, path_params)])
  end

  def handle_event([:phoenix, :endpoint, :stop], %{duration: duration}, %{conn: conn}, _config) do
    Logger.info("Sent #{conn.status} in #{format_duration(duration)}")
  end

  defp logged_path(conn, route, path_params) do
    if Enum.any?(Map.keys(path_params), &String.contains?(&1, "token")),
      do: route,
      else: conn.request_path
  end

  defp format_duration(native) do
    case System.convert_time_unit(native, :native, :microsecond) do
      microseconds when microseconds >= 1000 -> "#{div(microseconds, 1000)}ms"
      microseconds -> "#{microseconds}µs"
    end
  end
end
