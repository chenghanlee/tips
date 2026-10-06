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

  Normalization:

    * `q` has its whitespace trimmed and collapsed; a missing or blank `q`
      shows the empty form and searches nothing.
    * A filter value that is not an active curated id is All.
    * A `page` that is not a positive integer is 1. Pages past the bounded
      search window, and empty pages after the first, are out of range: they
      offer Previous and First page.

  Submitting the search form or changing a filter only patches the URL, and
  both reset to page 1. A blank submit shows the shared message and keeps the
  URL, heading and results. Typing does nothing.

  Rows render without the vote control until voting (P10) wires it.
  """
  use TipsWeb, :live_view

  alias Tips.Content
  alias TipsWeb.{Reader, UI}

  @page_size 20
  # Search ranks a window of at most 200 tips: pages 1 to 10.
  @last_page 10
  @blank_message "Enter a task or keywords to search."
  @filters [:technique, :model, :environment]
  @filter_labels %{technique: "Technique", model: "Model", environment: "Environment"}
  @search_options %{technique: :tag_id, model: :model_id, environment: :environment_id}
  @sources %{body: "Review", prompt: "Prompt", result: "Result", setup: "Reviewer setup"}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <h1 :if={!@request.q} class="sr-only">Search tips</h1>
      <UI.search_form value={@request.q} error={@search_error} action={~p"/search"} />
      <UI.filter_bar
        id="filters"
        active={filtered?(@request)}
        clear_href={path(%{@request | filters: no_filters(), page: 1})}
        note="Changing a selection updates the list. Model and Environment match the tip author's setup."
        phx-change="filter"
      >
        <UI.filter_select
          :for={filter <- filters()}
          id={Atom.to_string(filter)}
          name={Atom.to_string(filter)}
          label={filter_label(filter)}
          options={[{"All", ""} | Enum.map(@options[filter], &{&1.label, &1.id})]}
          value={@request.filters[filter]}
        />
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
            {heading_details(@request, @options)}
          </span>
        </h1>
        <.results result={@result} request={@request} />
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

  defp results(%{result: :loading} = assigns) do
    ~H"""
    <UI.notice id="results-loading" role="status">Loading results…</UI.notice>
    """
  end

  defp results(%{result: {:ok, %{entries: []}}} = assigns) do
    ~H"""
    <UI.notice id="results-empty">
      {if filtered?(@request), do: "No tips match these filters", else: "No tips match this search"}
    </UI.notice>
    """
  end

  defp results(%{result: {:ok, page}} = assigns) do
    assigns = assign(assigns, :page, page)

    ~H"""
    <ol id="result-rows">
      <UI.tip_row :for={entry <- @page.entries} tip={row(entry.tip, @request)}>
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
    options = Content.list_filter_choices()

    {:ok,
     assign(socket,
       options: %{
         technique: options.tags,
         model: options.models,
         environment: options.environments
       },
       request: nil,
       result: nil,
       search_error: nil
     )}
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

    case normalize_query(q) do
      nil -> {:noreply, assign(socket, search_error: @blank_message)}
      q when q == request.q -> {:noreply, assign(socket, search_error: nil)}
      q -> {:noreply, push_patch(socket, to: path(%{request | q: q, page: 1}))}
    end
  end

  def handle_event("filter", params, socket) do
    request = socket.assigns.request

    case filters(params, socket.assigns.options) do
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

  defp page_title(%{q: nil}), do: "Search"
  defp page_title(%{q: q}), do: "#{q} · Search"

  defp search(_scope, %{q: nil}), do: nil
  defp search(_scope, %{page: page}) when page > @last_page, do: :out_of_range

  defp search(scope, %{q: q, filters: filters, page: page}) do
    opts =
      for {filter, id} <- filters, id, do: {Map.fetch!(@search_options, filter), id}

    case Content.search_tips(scope, q, [offset: (page - 1) * @page_size] ++ opts) do
      {:ok, %{entries: []}} when page > 1 -> :out_of_range
      result -> result
    end
  end

  ## URL state

  defp request(params, options) do
    %{q: normalize_query(params["q"]), filters: filters(params, options), page: page(params)}
  end

  defp normalize_query(q) when is_binary(q) do
    case String.split(q) do
      [] -> nil
      words -> Enum.join(words, " ")
    end
  end

  defp normalize_query(_q), do: nil

  defp filters(params, options) do
    Map.new(@filters, fn filter ->
      value = params[Atom.to_string(filter)]
      {filter, if(Enum.any?(options[filter], &(&1.id == value)), do: value)}
    end)
  end

  defp no_filters, do: Map.new(@filters, &{&1, nil})

  defp filtered?(request), do: Enum.any?(request.filters, fn {_filter, id} -> id end)

  defp page(%{"page" => page}) when is_binary(page) do
    case Integer.parse(page) do
      {page, ""} when page > 0 -> page
      _invalid -> 1
    end
  end

  defp page(_params), do: 1

  defp path(%{q: q, filters: filters, page: page}) do
    query =
      [q: q] ++
        Enum.map(@filters, &{&1, filters[&1]}) ++
        [page: if(page > 1, do: page)]

    ~p"/search?#{Enum.reject(query, fn {_key, value} -> is_nil(value) end)}"
  end

  ## Presentation

  defp filters, do: @filters
  defp filter_label(filter), do: Map.fetch!(@filter_labels, filter)
  defp sources, do: @sources
  defp last_page, do: @last_page

  defp heading_details(request, options) do
    filters =
      for filter <- @filters, id = request.filters[filter] do
        "#{filter_label(filter)}: #{Enum.find(options[filter], &(&1.id == id)).label}"
      end

    pages = if request.page > 1, do: ["Page #{request.page}"], else: []
    Enum.map_join(filters ++ pages, "", &" · #{&1}")
  end

  defp row(tip, request) do
    %{
      id: "tip-#{tip.id}",
      title: tip.title,
      href: Reader.tip_path(tip),
      net_score: tip.score,
      review_count: tip.review_count,
      age: age(tip.created_at),
      datetime: DateTime.to_iso8601(tip.created_at),
      author: author(tip.author),
      setup: setup(tip, request)
    }
  end

  # No profile page exists yet, so the author is plain text.
  defp author(%{handle: handle}), do: %{handle: handle, href: nil}
  defp author(:deleted_account), do: %{handle: "[deleted]", href: nil}

  # A curated label patches only its own filter, keeping the query and the
  # other filters, on page 1; the filter already applied keeps the current URL.
  # Free-text models are plain text.
  defp setup(tip, request) do
    %{
      patch: true,
      technique: {tip.tag.label, filter_path(request, :technique, tip.tag.id)},
      model: model(tip.model, request),
      environment:
        tip.environment &&
          {tip.environment.label, filter_path(request, :environment, tip.environment.id)}
    }
  end

  defp model(nil, _request), do: nil
  defp model(%{id: nil, label: label}, _request), do: {:free_text, label}

  defp model(%{id: id, label: label}, request),
    do: {:curated, label, filter_path(request, :model, id)}

  defp filter_path(request, filter, id) do
    if request.filters[filter] == id,
      do: path(request),
      else: path(%{request | filters: Map.put(request.filters, filter, id), page: 1})
  end

  defp age(at) do
    case DateTime.diff(DateTime.utc_now(), at) do
      seconds when seconds < 60 -> "just now"
      seconds when seconds < 3600 -> ago(div(seconds, 60), "minute")
      seconds when seconds < 86_400 -> ago(div(seconds, 3600), "hour")
      seconds -> ago(div(seconds, 86_400), "day")
    end
  end

  defp ago(1, unit), do: "1 #{unit} ago"
  defp ago(count, unit), do: "#{count} #{unit}s ago"
end
