defmodule TipsWeb.InboxBadge do
  @moduledoc """
  Assigns `unread_notifications`, the header bell's badge, on every LiveView
  mount after `TipsWeb.UserAuth` admits the viewer. Anonymous viewers get 0.
  Pages pass it to `TipsWeb.Layouts.app/1` as `unread`.
  """

  alias Tips.Accounts.Scope
  alias Tips.Content

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     Phoenix.Component.assign(socket, :unread_notifications, count(socket.assigns.current_scope))}
  end

  defp count(%Scope{} = scope), do: Content.count_unread_notifications(scope)
  defp count(nil), do: 0
end
