defmodule TipsWeb.VoteActions do
  @moduledoc """
  The Helpful / Not helpful events of `TipsWeb.UI.vote_control/1`, for each
  page that renders tips or reviews. See "Voting" in `Tips.Content`.

  `attach/2` assigns `vote_status`, the `pending` flag and `status` text of
  each `{kind, id}` target with a request in flight or a message, and handles
  `vote` events and their results. The page passes `update`, a function
  `(socket, {kind, id}, fun) -> socket` that applies `fun` to the displayed
  projection of that target, if it is still shown. A result therefore changes
  only that row and never reorders a list.

    * Each button sends the vote it asks for, never a toggle, so a click made
      before an earlier result showed cannot reverse it.
    * One request per target is in flight; its buttons ignore clicks until
      the result.
    * When the outcome is unknown, the target's current state is read before
      its buttons accept another click.
    * A signed-out click, or one whose session expired, goes to log in and
      returns to the target's permalink. Nothing is kept, so the reader clicks
      again.

  A URL change drops the messages and keeps the requests in flight.
  """
  use TipsWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView

  alias Tips.Content
  alias TipsWeb.{AuthMailAdmission, Reader, UserAuth}

  def attach(socket, update) do
    socket
    |> assign(:vote_status, %{})
    |> attach_hook(:vote_actions, :handle_event, &handle_event/3)
    |> attach_hook(:vote_actions, :handle_async, &handle_async(&1, &2, &3, update))
    |> attach_hook(:vote_actions, :handle_params, &handle_params/3)
  end

  @doc """
  The `TipsWeb.UI.vote_control/1` attrs of a `kind` projection, or `nil` for a
  placeholder or a signed-in viewer without the vote capability. Signed-out
  viewers get the control; their click leads to log in.
  """
  def control(kind, %{capabilities: %{vote: vote?}} = item, scope, vote_status)
      when vote? or is_nil(scope) do
    Map.merge(
      %{
        target: "#{kind}-#{item.id}",
        return: return(kind, item),
        selected: selected(item.viewer_vote),
        counts: %{helpful: item[:up_count], not_helpful: item[:down_count]},
        pending: false,
        status: nil
      },
      Map.get(vote_status, {kind, item.id}, %{})
    )
  end

  def control(_kind, _item, _scope, _vote_status), do: nil

  @doc "Applies `fun` to the row of `rows` with `id`."
  def update_row(rows, id, fun),
    do: Enum.map(rows, fn row -> if row.id == id, do: fun.(row), else: row end)

  defp return(:tip, tip), do: Reader.tip_path(tip)
  defp return(:review, review), do: Reader.review_path(review.id)

  defp selected(1), do: :helpful
  defp selected(-1), do: :not_helpful
  defp selected(nil), do: nil

  defp handle_event("vote", params, socket) do
    with {:ok, target} <- target(params["target"]),
         {:ok, vote} <- vote(params["vote"]),
         false <- pending?(socket, target) do
      case UserAuth.readmit(socket) do
        {:ok, socket} -> {:halt, save(socket, target, vote)}
        {:error, :unauthenticated} -> {:halt, log_in(socket, params["return"])}
      end
    else
      _ignored -> {:halt, socket}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp target(value) when is_binary(value) do
    with [kind, id] <- String.split(value, "-"),
         {:ok, kind} <- kind(kind),
         {id, ""} when id > 0 <- Integer.parse(id) do
      {:ok, {kind, id}}
    else
      _invalid -> :error
    end
  end

  defp target(_value), do: :error

  defp kind("tip"), do: {:ok, :tip}
  defp kind("review"), do: {:ok, :review}
  defp kind(_kind), do: :error

  defp vote("helpful"), do: {:ok, 1}
  defp vote("not_helpful"), do: {:ok, -1}
  defp vote("none"), do: {:ok, nil}
  defp vote(_vote), do: :error

  defp pending?(socket, target), do: match?(%{pending: true}, socket.assigns.vote_status[target])

  # The task captures plain values, never the socket.
  defp save(socket, {kind, id} = target, vote) do
    scope = socket.assigns.current_scope

    socket
    |> put_status(target, true, "Saving…")
    |> start_async({:vote, target}, fn -> Content.set_vote(scope, kind, id, vote) end)
  end

  defp log_in(socket, return) do
    to = UserAuth.with_return_to(~p"/users/log-in", UserAuth.allowed_return_to(return))
    socket |> put_flash(:info, "Log in to vote.") |> redirect(to: to)
  end

  defp handle_async({:vote, target}, {:ok, {:ok, receipt}}, socket, update) do
    confirmed = %{
      viewer_vote: receipt.vote,
      up_count: receipt.up_count,
      down_count: receipt.down_count,
      score: receipt.score
    }

    {:halt,
     socket |> show(target, confirmed, update) |> update(:vote_status, &Map.delete(&1, target))}
  end

  defp handle_async({:vote, target}, {:ok, {:error, :outcome_unknown}}, socket, _update),
    do: {:halt, check(socket, target)}

  defp handle_async({:vote, target}, {:exit, _reason}, socket, _update),
    do: {:halt, check(socket, target)}

  defp handle_async({:vote, _target}, {:ok, {:error, :unauthenticated}}, socket, _update),
    do: {:halt, UserAuth.require_login(socket)}

  defp handle_async({:vote, target}, {:ok, {:error, reason}}, socket, _update),
    do: {:halt, put_status(socket, target, false, refusal(reason))}

  defp handle_async({:vote_check, target}, {:ok, {:ok, current}}, socket, update) do
    message = "We couldn't confirm your vote. This shows its current state."
    {:halt, socket |> show(target, current, update) |> put_status(target, false, message)}
  end

  defp handle_async({:vote_check, target}, {:ok, {:error, :not_found}}, socket, _update),
    do: {:halt, put_status(socket, target, false, refusal(:not_found))}

  # Without the current state, the buttons stay unavailable.
  defp handle_async({:vote_check, target}, _failed, socket, _update) do
    message = "We couldn't confirm your vote. Reload the page to check it."
    {:halt, put_status(socket, target, true, message)}
  end

  defp handle_async(_name, _result, socket, _update), do: {:cont, socket}

  defp check(socket, {kind, id} = target) do
    viewer = UserAuth.viewer(socket)

    socket
    |> put_status(target, true, "Checking your vote…")
    |> start_async({:vote_check, target}, fn -> current(viewer, kind, id) end)
  end

  defp current(viewer, :tip, id) do
    case Content.get_tip_page(viewer, id) do
      {:ok, %{tip: %{state: :visible} = tip}} -> {:ok, tip}
      {:ok, _placeholder} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp current(viewer, :review, id) do
    case Content.get_review_page(viewer, id) do
      {:ok, %{review: {:visible, review}}} -> {:ok, review}
      {:ok, _unavailable} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # Copies only the vote fields the displayed row has; summaries have no counts.
  defp show(socket, target, state, update) do
    fields = Map.take(state, [:viewer_vote, :up_count, :down_count, :score])
    update.(socket, target, &Map.merge(&1, Map.take(fields, Map.keys(&1))))
  end

  defp put_status(socket, target, pending, status),
    do: update(socket, :vote_status, &Map.put(&1, target, %{pending: pending, status: status}))

  defp handle_params(_params, _uri, socket),
    do: {:cont, update(socket, :vote_status, &Map.filter(&1, fn {_target, s} -> s.pending end))}

  defp refusal(:not_found), do: "This is no longer available for voting."
  defp refusal(:unconfirmed), do: "Confirm your email address to vote."
  defp refusal(:forbidden), do: "Your account can't vote."

  defp refusal({:rate_limited, seconds}),
    do:
      "Too many attempts, so your vote wasn't saved. Try again in #{AuthMailAdmission.retry_in(seconds)}."

  defp refusal({:capacity, seconds}),
    do:
      "Tips is busy, so your vote wasn't saved. Try again in #{AuthMailAdmission.retry_in(seconds)}."
end
