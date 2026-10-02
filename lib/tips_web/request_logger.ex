defmodule TipsWeb.RequestLogger do
  @moduledoc """
  Endpoint request lines for routes that carry a credential in the path.

  Phoenix's endpoint logger prints the full request path. The magic-link and
  email-confirmation routes carry their token as a path segment, so for any
  route with a `token` path parameter `level/1` turns that logger off and this
  one logs the route pattern in place of the path:

      GET /users/log-in/:token
      Sent 200 in 12ms

  Every other request keeps Phoenix's own lines. Endpoint telemetry is
  unchanged for all requests.
  """

  require Logger

  @events [[:phoenix, :endpoint, :start], [:phoenix, :endpoint, :stop]]

  @doc "Attaches the logger. Call it once, when the application starts."
  def attach do
    :telemetry.attach_many(__MODULE__, @events, &__MODULE__.handle_event/4, nil)
  end

  @doc """
  The `Plug.Telemetry` `:log` option of the endpoint: `false` for a request
  this module logs, `:info` otherwise.
  """
  @spec level(Plug.Conn.t()) :: Logger.level() | false
  def level(conn), do: if(credential_route(conn), do: false, else: :info)

  @doc false
  def handle_event([:phoenix, :endpoint, :start], _measurements, %{conn: conn}, _config) do
    if route = credential_route(conn), do: Logger.info([conn.method, ?\s, route])
  end

  def handle_event([:phoenix, :endpoint, :stop], %{duration: duration}, %{conn: conn}, _config) do
    if credential_route(conn) do
      milliseconds = System.convert_time_unit(duration, :native, :millisecond)
      Logger.info("Sent #{conn.status} in #{milliseconds}ms")
    end
  end

  # The route pattern when a path parameter of the matched route is a token.
  defp credential_route(%Plug.Conn{method: method, request_path: path, host: host}) do
    with %{route: route, path_params: path_params} <-
           Phoenix.Router.route_info(TipsWeb.Router, method, path, host),
         true <- Enum.any?(Map.keys(path_params), &String.contains?(&1, "token")) do
      route
    else
      _no_route_or_no_token -> nil
    end
  end
end
