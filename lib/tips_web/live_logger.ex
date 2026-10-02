defmodule TipsWeb.LiveLogger do
  @moduledoc """
  Debug log lines for LiveView callbacks, without session or payload values.

  LiveView's own logger prints the whole mount session, which holds the
  session bearer token, so `TipsWeb.live_view/0` turns it off. This logger
  keeps the useful part: which view mounted and which event it handled.
  Params and event payloads are left out so a credential-shaped value cannot
  reach the log.
  """

  require Logger

  @events for callback <- [:mount, :handle_params, :handle_event],
              do: [:phoenix, :live_view, callback, :start]

  @doc "Attaches the logger. Call it once, when the application starts."
  def attach do
    :telemetry.attach_many(__MODULE__, @events, &__MODULE__.handle_event/4, nil)
  end

  @doc false
  def handle_event([:phoenix, :live_view, callback, :start], _measurements, metadata, _config) do
    %{socket: socket} = metadata

    if Phoenix.LiveView.connected?(socket) do
      Logger.debug(fn -> [label(callback, metadata), inspect(socket.view)] end)
    end
  end

  defp label(:mount, _metadata), do: "MOUNT "
  defp label(:handle_params, _metadata), do: "HANDLE PARAMS in "
  defp label(:handle_event, %{event: event}), do: ["HANDLE EVENT ", inspect(event), " in "]
end
