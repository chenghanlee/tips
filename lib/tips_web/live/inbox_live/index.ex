defmodule TipsWeb.InboxLive.Index do
  @moduledoc """
  The signed-in reader's inbox, `/inbox?page=…`: twenty notifications per
  page, newest activity first. See "Inbox" in `Tips.Content`.

  The disconnected render only reads. The first page load of each connected
  visit also marks every unread notification it captured, on all pages, then
  refreshes the header badge. Later page changes in the visit only read; a
  remount is a new visit and marks again. Rows of the marking visit render
  unread, from the snapshot; later pages render their current state. Every
  page load, after any marking, recounts the header badge, so it includes
  later arrivals.
  """
  use TipsWeb, :live_view

  alias Tips.Content
  alias TipsWeb.{Discovery, Reader, UserAuth}

  @page_size 20
  # Postgres offsets are bigints; later pages cannot be requested.
  @last_page div(9_223_372_036_854_775_807, @page_size)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} unread={@unread_notifications}>
      <section id="inbox" class="grid gap-4" aria-labelledby="inbox-heading">
        <div class="grid gap-1">
          <h1 id="inbox-heading" class="text-xl font-semibold">Inbox</h1>
          <p class="text-sm text-muted-foreground">
            Recent activity on your tips and reviews. Opening this page clears the unread badge.
          </p>
        </div>
        <.notifications result={@result} page={@page} />
      </section>
    </Layouts.app>
    """
  end

  attr :result, :any, required: true
  attr :page, :integer, required: true

  defp notifications(%{result: :out_of_range} = assigns) do
    ~H"""
    <UI.notice id="notifications-empty">No notifications on page {@page}.</UI.notice>
    <UI.page_nav page={@page} prev_href={path(@page - 1)} first_href={path(1)} out_of_range />
    """
  end

  defp notifications(%{result: %{entries: []}} = assigns) do
    ~H"""
    <UI.notice id="notifications-empty">No notifications yet.</UI.notice>
    """
  end

  defp notifications(assigns) do
    ~H"""
    <ol id="notifications" class="grid divide-y">
      <li :for={entry <- @result.entries} id={"notification-#{entry.id}"} class="grid gap-1 py-3">
        <p data-role="message" class="font-medium">{message(entry)}</p>
        <p class="flex flex-wrap gap-x-3 text-sm">
          <.link navigate={Reader.tip_path(entry.tip)}>{entry.tip.title}</.link>
          <.link :if={entry.review_id} navigate={~p"/reviews/#{entry.review_id}"}>
            {review_link(entry.type)}
          </.link>
        </p>
        <p class="flex flex-wrap gap-x-2 text-sm text-muted-foreground">
          <span :if={entry.unread} data-role="unread" class="font-medium text-foreground">
            Unread
          </span>
          <time datetime={DateTime.to_iso8601(entry.updated_at)}>
            {Discovery.age(entry.updated_at)}
          </time>
        </p>
      </li>
    </ol>
    <UI.page_nav
      page={@page}
      prev_href={@page > 1 && path(@page - 1)}
      next_href={@result.has_more && path(@page + 1)}
      first_href={path(1)}
    />
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page: nil, result: nil, marked: false, page_title: "Inbox")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = Discovery.page(params)
    mark? = connected?(socket) and not socket.assigns.marked

    if page == socket.assigns.page and not mark?,
      do: {:noreply, socket},
      else: {:noreply, load(socket, page, mark?)}
  end

  defp load(socket, page, mark?) do
    offset = if page > @last_page, do: 0, else: (page - 1) * @page_size

    case Content.get_inbox(UserAuth.viewer(socket), offset: offset, mark_read: mark?) do
      {:ok, result} ->
        socket
        |> assign(
          page: page,
          result: result(result, page),
          marked: socket.assigns.marked or mark?,
          unread_notifications: Content.count_unread_notifications(socket.assigns.current_scope)
        )

      {:error, :unauthenticated} ->
        UserAuth.require_login(socket)
    end
  end

  defp result(_result, page) when page > @last_page, do: :out_of_range
  defp result(%{entries: []}, page) when page > 1, do: :out_of_range
  defp result(result, _page), do: result

  defp message(%{type: :tip_upvoted}), do: "Your tip got new helpful votes"
  defp message(%{type: :review_upvoted}), do: "Your review got new helpful votes"

  defp message(%{type: :tip_reviewed, actor: %{handle: handle}}),
    do: "#{handle} reviewed your tip"

  defp message(%{type: :tip_reviewed, actor: :deleted_account}), do: "[deleted] reviewed your tip"
  defp message(%{type: :tip_reviewed, actor: nil}), do: "Your tip got a review"

  defp review_link(:review_upvoted), do: "Your review"
  defp review_link(:tip_reviewed), do: "Read the review"

  defp path(1), do: ~p"/inbox"
  defp path(page), do: ~p"/inbox?#{[page: page]}"
end
