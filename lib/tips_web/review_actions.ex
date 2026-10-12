defmodule TipsWeb.ReviewActions do
  @moduledoc """
  The Delete events of `TipsWeb.Reader.review_card/1`, for each page that
  renders review cards.

  `attach/1` assigns `confirm_delete`, the id of the review whose confirmation
  is open, and handles `confirm_delete`, `cancel_delete` and `delete`. Delete
  acts only on the confirmed id. A confirmed or uncertain deletion reloads the
  page's `path` assign with a flash, so the page shows stored state; a refusal
  that changed nothing keeps the page and says why.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias Tips.Content
  alias TipsWeb.{AuthMailAdmission, UserAuth}

  def attach(socket) do
    socket
    |> assign(:confirm_delete, nil)
    |> attach_hook(:review_actions, :handle_event, &handle_event/3)
  end

  defp handle_event("confirm_delete", %{"id" => id}, socket),
    do: {:halt, assign(socket, :confirm_delete, String.to_integer(id))}

  defp handle_event("cancel_delete", _params, socket),
    do: {:halt, assign(socket, :confirm_delete, nil)}

  defp handle_event("delete", _params, %{assigns: %{confirm_delete: id}} = socket)
       when is_integer(id) do
    case Content.delete_content(socket.assigns.current_scope, :review, id) do
      {:ok, _receipt} ->
        reload(socket, :info, "Review deleted.")

      {:error, :not_found} ->
        reload(socket, :error, "This review is no longer available.")

      {:error, :outcome_unknown} ->
        reload(
          socket,
          :error,
          "We couldn't confirm the deletion. This page shows its current state."
        )

      {:error, :unauthenticated} ->
        {:halt, UserAuth.require_login(socket)}

      {:error, reason} ->
        {:halt, socket |> assign(:confirm_delete, nil) |> put_flash(:error, refusal(reason))}
    end
  end

  # A repeated click after the page closed the confirmation.
  defp handle_event("delete", _params, socket), do: {:halt, socket}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp reload(socket, kind, message),
    do:
      {:halt,
       socket |> put_flash(kind, message) |> push_navigate(to: socket.assigns.path, replace: true)}

  defp refusal({:rate_limited, seconds}),
    do:
      "Too many attempts, so nothing was deleted. Try again in #{AuthMailAdmission.retry_in(seconds)}."

  defp refusal({:capacity, seconds}),
    do:
      "Tips is busy, so nothing was deleted. Try again in #{AuthMailAdmission.retry_in(seconds)}."
end
