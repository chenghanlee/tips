defmodule TipsWeb.BrowseLive.Index do
  @moduledoc """
  The home feed, `/?sort=new&technique=…&model=…&environment=…&page=…`.

  The URL is the only browse state; `TipsWeb.Discovery` normalizes it, and a
  `sort` other than `new` is Hot. `handle_params/3` loads the requested page
  of `Tips.Content.list_tips/2` synchronously on every URL change, so the
  disconnected render, each patch reply and Back all carry their rows, and
  LiveView can restore the reading position. An unchanged request loads
  nothing. The page holds only its current rows.

  Changing a select or Clear filters patches the URL on page 1, keeping the
  sort. A search goes to `/search` with the applied filters and without the
  sort, which does not apply to relevance order. A blank search shows the
  shared message and stays. An empty page after the first is out of range:
  it offers Previous and First page.

  `TipsWeb.VoteActions` handles each row's vote control. A confirmed vote
  updates only that row's net score and selection, in place.
  """
  use TipsWeb, :live_view

  alias Tips.Content
  alias TipsWeb.{Discovery, VoteActions}

  @page_size 20
  # Postgres offsets are bigints; later pages cannot be requested.
  @last_page div(9_223_372_036_854_775_807, @page_size)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} unread={@unread_notifications}>
      <UI.search_form error={@search_error} action={~p"/search"} />
      <UI.filter_bar
        id="filters"
        active={Discovery.filtered?(@request.filters)}
        clear_href={path(%{@request | filters: Discovery.no_filters(), page: 1})}
        note={Discovery.filter_note()}
        phx-change="filter"
      >
        <UI.filter_select
          id="sort"
          name="sort"
          label="Sort"
          options={[{"Hot", "hot"}, {"New", "new"}]}
          value={Atom.to_string(@request.sort)}
        />
        <Discovery.filter_selects options={@options} filters={@request.filters} />
      </UI.filter_bar>
      <section id="feed" class="grid gap-4" aria-labelledby="feed-heading">
        <h1 id="feed-heading" class="text-xl font-semibold">
          {heading(@request.sort)}
          <span class="text-sm font-normal text-muted-foreground">
            {Discovery.heading_details(@request, @options)}
          </span>
        </h1>
        <.tips
          result={@result}
          request={@request}
          current_scope={@current_scope}
          vote_status={@vote_status}
        />
      </section>
    </Layouts.app>
    """
  end

  attr :result, :any, required: true
  attr :request, :map, required: true
  attr :current_scope, :any, required: true
  attr :vote_status, :map, required: true

  defp tips(%{result: :out_of_range} = assigns) do
    ~H"""
    <UI.notice id="tips-empty">No tips on page {@request.page}.</UI.notice>
    <UI.page_nav
      page={@request.page}
      prev_href={path(%{@request | page: @request.page - 1})}
      first_href={path(%{@request | page: 1})}
      out_of_range
    />
    """
  end

  defp tips(%{result: %{entries: []}} = assigns) do
    ~H"""
    <UI.notice id="tips-empty">
      {if Discovery.filtered?(@request.filters),
        do: "No tips match these filters",
        else: "No tips yet"}
    </UI.notice>
    """
  end

  defp tips(assigns) do
    ~H"""
    <ol id="tip-rows">
      <UI.tip_row
        :for={tip <- @result.entries}
        tip={Discovery.row(tip, @request, &path/1)}
        vote={VoteActions.control(:tip, tip, @current_scope, @vote_status)}
      />
    </ol>
    <UI.page_nav
      page={@request.page}
      prev_href={@request.page > 1 && path(%{@request | page: @request.page - 1})}
      next_href={@result.has_more && path(%{@request | page: @request.page + 1})}
      first_href={path(%{@request | page: 1})}
    />
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
         assign(socket,
           request: request,
           result: list(socket.assigns.current_scope, request),
           page_title: heading(request.sort)
         )}
    end
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    case Discovery.normalize_query(q) do
      nil ->
        {:noreply, assign(socket, search_error: Discovery.blank_message())}

      q ->
        to = Discovery.search_path(%{q: q, filters: socket.assigns.request.filters, page: 1})
        {:noreply, push_navigate(socket, to: to)}
    end
  end

  def handle_event("filter", params, socket) do
    request = socket.assigns.request

    changed = %{
      request
      | sort: sort(params),
        filters: Discovery.filters(params, socket.assigns.options)
    }

    if changed.sort == request.sort and changed.filters == request.filters,
      do: {:noreply, socket},
      else: {:noreply, push_patch(socket, to: path(%{changed | page: 1}))}
  end

  defp list(_scope, %{page: page}) when page > @last_page, do: :out_of_range

  defp list(scope, %{sort: sort, filters: filters, page: page}) do
    opts = [sort: sort, offset: (page - 1) * @page_size] ++ Discovery.content_filters(filters)

    case Content.list_tips(scope, opts) do
      {:ok, %{entries: []}} when page > 1 -> :out_of_range
      {:ok, result} -> result
    end
  end

  defp update_vote(%{assigns: %{result: %{entries: entries} = result}} = socket, fun),
    do: assign(socket, :result, %{result | entries: Enum.map(entries, &fun.(:tip, &1))})

  defp update_vote(socket, _fun), do: socket

  defp heading(:hot), do: "Hot tips"
  defp heading(:new), do: "New tips"

  ## URL state

  defp request(params, options) do
    %{
      sort: sort(params),
      filters: Discovery.filters(params, options),
      page: Discovery.page(params)
    }
  end

  defp sort(%{"sort" => "new"}), do: :new
  defp sort(_params), do: :hot

  # Hot and page 1 are the defaults, left out of the URL.
  defp path(%{sort: sort, filters: filters, page: page}) do
    params =
      [sort: if(sort == :new, do: "new")] ++
        Discovery.filter_params(filters) ++ [page: Discovery.page_param(page)]

    ~p"/?#{Discovery.compact(params)}"
  end
end
