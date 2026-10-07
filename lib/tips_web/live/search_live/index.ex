defmodule TipsWeb.SearchLive.Index do
  @moduledoc """
  The search page, `/search?q=…&technique=…&model=…&environment=…&page=…`.

  The URL is the only search state. `handle_params/3` normalizes it into a
  request and runs `Tips.Content.search_tips/3` synchronously on the
  disconnected and the first connected render; an unchanged request does no
  new search. Later parameter changes and Retry go through `begin_results/1`:
  it cancels the previous `:results` task, shows loading under the new
  heading and starts a new one. LiveView drops the result or exit of a task
  that a newer `start_async/3` replaced, so stale pages never render.

  `TipsWeb.Discovery` normalizes the URL. A missing or blank `q` shows the
  empty form and searches nothing. Pages past the bounded search window, and
  empty pages after the first, are out of range: they offer Previous and
  First page.

  Submitting the search form or changing a filter only patches the URL, and
  both reset to page 1. A blank submit shows the shared message and keeps the
  URL, heading and results. Typing does nothing.

  `TipsWeb.VoteActions` handles each row's vote control. A confirmed vote
  updates only that row's net score and selection, in place. A vote result
  that arrives while results load starts the search again: the running one
  predates the result.
  """
  use TipsWeb, :live_view

  alias Tips.Content
  alias TipsWeb.{Discovery, UI, VoteActions}

  @page_size 20
  # Search ranks a window of at most 200 tips: pages 1 to 10.
  @last_page 10
  @sources %{body: "Review", prompt: "Prompt", result: "Result", setup: "Reviewer setup"}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} unread={@unread_notifications}>
      <h1 :if={!@request.q} class="sr-only">Search tips</h1>
      <UI.search_form value={@request.q} error={@search_error} action={~p"/search"} />
      <UI.filter_bar
        id="filters"
        active={Discovery.filtered?(@request.filters)}
        clear_href={path(%{@request | filters: Discovery.no_filters(), page: 1})}
        note={Discovery.filter_note()}
        phx-change="filter"
      >
        <Discovery.filter_selects options={@options} filters={@request.filters} />
      </UI.filter_bar>
      <section
        :if={@request.q}
        id="results"
        class="grid gap-4"
        aria-labelledby="results-heading"
        phx-hook=".RestoreScroll"
      >
        <h1 id="results-heading" class="text-xl font-semibold">
          Results for “{@request.q}”
          <span class="text-sm font-normal text-muted-foreground">
            {Discovery.heading_details(@request, @options)}
          </span>
        </h1>
        <.results
          result={@result}
          request={@request}
          current_scope={@current_scope}
          vote_status={@vote_status}
        />
      </section>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".RestoreScroll">
        // LiveView restores a history entry's scroll position when a Back patch
        // replies, while only the loading notice shows. Apply it again once the
        // rows arrive. A link or filter patch shows loading before it pushes its
        // new URL, so a changed URL means there is no position to restore.
        export default {
          updated() {
            const loading = this.el.querySelector("#results-loading") !== null
            if (loading && !this.loading) {
              this.from = {href: location.href, scroll: history.state?.scroll}
            }
            const {href, scroll} = this.from || {}
            if (!loading && this.loading && href === location.href && typeof scroll === "number") {
              requestAnimationFrame(() => window.scrollTo(0, scroll))
            }
            this.loading = loading
          }
        }
      </script>
    </Layouts.app>
    """
  end

  attr :result, :any, required: true
  attr :request, :map, required: true
  attr :current_scope, :any, required: true
  attr :vote_status, :map, required: true

  defp results(%{result: :loading} = assigns) do
    ~H"""
    <UI.notice id="results-loading" role="status">Loading results…</UI.notice>
    """
  end

  defp results(%{result: {:ok, %{entries: []}}} = assigns) do
    ~H"""
    <UI.notice id="results-empty">
      {if Discovery.filtered?(@request.filters),
        do: "No tips match these filters",
        else: "No tips match this search"}
    </UI.notice>
    """
  end

  defp results(%{result: {:ok, page}} = assigns) do
    assigns = assign(assigns, :page, page)

    ~H"""
    <ol id="result-rows">
      <UI.tip_row
        :for={entry <- @page.entries}
        tip={Discovery.row(entry.tip, @request, &path/1)}
        vote={VoteActions.control(:tip, entry.tip, @current_scope, @vote_status)}
      >
        <:excerpt
          :if={entry.excerpt}
          source={Map.fetch!(sources(), entry.excerpt.source)}
          href={~p"/reviews/#{entry.matched_review_id}"}
        >
          {entry.excerpt.text}
        </:excerpt>
      </UI.tip_row>
    </ol>
    <UI.page_nav
      page={@request.page}
      prev_href={@request.page > 1 && path(%{@request | page: @request.page - 1})}
      next_href={@page.has_more && path(%{@request | page: @request.page + 1})}
      first_href={path(%{@request | page: 1})}
    />
    """
  end

  defp results(%{result: :out_of_range} = assigns) do
    ~H"""
    <UI.notice id="results-empty">No results on page {@request.page}.</UI.notice>
    <UI.page_nav
      page={@request.page}
      prev_href={path(%{@request | page: min(@request.page - 1, last_page())})}
      first_href={path(%{@request | page: 1})}
      out_of_range
    />
    """
  end

  defp results(%{result: {:error, :query_too_long}} = assigns) do
    ~H"""
    <UI.notice id="results-error" tone="error" role="alert">
      This search is too long. Shorten it and search again.
    </UI.notice>
    """
  end

  defp results(%{result: {:error, _reason}} = assigns) do
    ~H"""
    <UI.notice id="results-error" tone="error" role="alert">
      Couldn't load this page of results.
      <:actions>
        <UI.button id="retry" type="button" phx-click="retry">Retry</UI.button>
      </:actions>
    </UI.notice>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       options: Discovery.filter_options(),
       request: nil,
       result: nil,
       search_error: nil
     )
     |> VoteActions.attach(&update_vote/2)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case request(params, socket.assigns.options) do
      request when request == socket.assigns.request ->
        {:noreply, socket}

      request ->
        {:noreply,
         socket
         |> clear_error(request)
         |> assign(request: request, page_title: page_title(request))
         |> load_results(socket.assigns.request)}
    end
  end

  # The first request of this LiveView process searches synchronously, so the
  # disconnected render and the first connected render, also after a
  # reconnect, have their rows. Later requests load asynchronously.
  defp load_results(socket, nil = _previous) do
    assign(socket, result: search(socket.assigns.current_scope, socket.assigns.request))
  end

  defp load_results(socket, _previous), do: begin_results(socket)

  # Cancelling the previous task stops its work; replacing it alone would only
  # drop its result. The task captures plain values, never the socket.
  defp begin_results(socket) do
    %{current_scope: scope, request: request} = socket.assigns

    socket
    |> cancel_async(:results)
    |> assign(result: :loading)
    |> start_async(:results, fn -> search(scope, request) end)
  end

  # Only a new submitted query clears the blank-search message. Clearing it on
  # a filter or page change rerenders the search field and replaces text the
  # reader is still editing.
  defp clear_error(%{assigns: %{request: %{q: q}}} = socket, %{q: q}), do: socket
  defp clear_error(socket, _request), do: assign(socket, search_error: nil)

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    request = socket.assigns.request

    case Discovery.normalize_query(q) do
      nil -> {:noreply, assign(socket, search_error: Discovery.blank_message())}
      q when q == request.q -> {:noreply, assign(socket, search_error: nil)}
      q -> {:noreply, push_patch(socket, to: path(%{request | q: q, page: 1}))}
    end
  end

  def handle_event("filter", params, socket) do
    request = socket.assigns.request

    case Discovery.filters(params, socket.assigns.options) do
      filters when filters == request.filters -> {:noreply, socket}
      filters -> {:noreply, push_patch(socket, to: path(%{request | filters: filters, page: 1}))}
    end
  end

  def handle_event("retry", _params, socket), do: {:noreply, begin_results(socket)}

  @impl true
  def handle_async(:results, {:ok, result}, socket),
    do: {:noreply, assign(socket, result: result)}

  # A cancelled task is not a failure.
  def handle_async(:results, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:results, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, result: {:error, :unavailable})}

  defp update_vote(%{assigns: %{result: {:ok, %{entries: entries} = page}}} = socket, fun) do
    entries = Enum.map(entries, &%{&1 | tip: fun.(:tip, &1.tip)})
    assign(socket, :result, {:ok, %{page | entries: entries}})
  end

  defp update_vote(%{assigns: %{result: :loading}} = socket, _fun), do: begin_results(socket)

  defp update_vote(socket, _fun), do: socket

  defp page_title(%{q: nil}), do: "Search"
  defp page_title(%{q: q}), do: "#{q} · Search"

  defp search(_scope, %{q: nil}), do: nil
  defp search(_scope, %{page: page}) when page > @last_page, do: :out_of_range

  defp search(scope, %{q: q, filters: filters, page: page}) do
    opts = [offset: (page - 1) * @page_size] ++ Discovery.content_filters(filters)

    case Content.search_tips(scope, q, opts) do
      {:ok, %{entries: []}} when page > 1 -> :out_of_range
      result -> result
    end
  end

  ## URL state

  defp request(params, options) do
    %{
      q: Discovery.normalize_query(params["q"]),
      filters: Discovery.filters(params, options),
      page: Discovery.page(params)
    }
  end

  defp path(request), do: Discovery.search_path(request)

  defp sources, do: @sources
  defp last_page, do: @last_page
end
