defmodule TipsWeb.TipLive.Show do
  @moduledoc """
  The tip page, `/tips/:id/:slug?sort=new&model=…&environment=…&page=…`: the
  projected tip, its header and text, then one ranked page of its live
  reviews.

  Loads by id; any other slug redirects to the projected one, including the
  neutral placeholder slugs, keeping the list parameters. As on browse, the
  URL is the only list state and `handle_params/3` reads the page on every URL
  change; an unchanged request loads nothing. A `sort` other than `new` is
  Best. A filter value that is not an active curated id is All, which also
  lists reviews that reported no setup.

  Changing a select or Clear filters patches the URL on page 1, keeping the
  sort. An empty page after the first is out of range. Review links carry the
  sort, so Show all reviews on the single-review view keeps it.
  """
  use TipsWeb, :live_view

  alias Tips.Content
  alias TipsWeb.{Discovery, Reader, ReviewActions, UserAuth}

  @page_size 30
  # Postgres offsets are bigints; later pages cannot be requested.
  @last_page div(9_223_372_036_854_775_807, @page_size)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      unread={@unread_notifications}
      return_to={@path}
    >
      <Reader.removed_notice
        :if={@tip.state == :visible and @tip.removed}
        id="tip-removed-notice"
        editable={@tip.capabilities.edit}
      />
      <Reader.tip_header
        tip={@tip}
        own_review={@own_review}
        signed_in={!!@current_scope}
        sort_params={sort_params(@request.sort)}
      />
      <%= if @tip.state == :visible do %>
        <Reader.markdown id="tip-body" text={@tip.body} />
        <Reader.verbatim_block :if={@tip.prompt} id="tip-prompt" label="Prompt" text={@tip.prompt} />
        <Reader.verbatim_block :if={@tip.output} id="tip-result" label="Result" text={@tip.output} />
      <% end %>
      <section id="reviews" class="grid gap-4" aria-labelledby="reviews-heading">
        <h2 id="reviews-heading" class="text-xl font-semibold">
          Reviews
          <span class="text-sm font-normal text-muted-foreground">
            {Discovery.heading_details(@request, @options)}
          </span>
        </h2>
        <UI.notice
          :if={@tip.state == :visible and @tip.has_earlier_reviews}
          id="earlier-reviews-note"
        >
          This tip has been updated; earlier reviews may describe an earlier version.
        </UI.notice>
        <UI.filter_bar
          id="review-filters"
          active={Discovery.filtered?(@request.filters)}
          clear_href={list_path(@tip, %{@request | filters: Discovery.no_filters(), page: 1})}
          note="Changing a selection updates the list. Model and Environment show only reviews reporting this setup."
          phx-change="filter"
        >
          <UI.filter_select
            id="sort"
            name="sort"
            label="Sort"
            options={[{"Best", "best"}, {"New", "new"}]}
            value={Atom.to_string(@request.sort)}
          />
          <UI.filter_select
            :for={{filter, label} <- [model: "Model", environment: "Environment"]}
            id={Atom.to_string(filter)}
            name={Atom.to_string(filter)}
            label={label}
            options={[{"All", ""} | Enum.map(@options[filter], &{&1.label, &1.id})]}
            value={@request.filters[filter]}
          />
        </UI.filter_bar>
        <.reviews
          reviews={@reviews}
          request={@request}
          tip={@tip}
          own_review={@own_review}
          confirm_delete={@confirm_delete}
        />
      </section>
    </Layouts.app>
    """
  end

  attr :reviews, :any, required: true
  attr :request, :map, required: true
  attr :tip, :map, required: true
  attr :own_review, :map, required: true
  attr :confirm_delete, :integer, required: true

  defp reviews(%{reviews: :out_of_range} = assigns) do
    ~H"""
    <UI.notice id="reviews-empty">No reviews on page {@request.page}.</UI.notice>
    <UI.page_nav
      page={@request.page}
      prev_href={list_path(@tip, %{@request | page: @request.page - 1})}
      first_href={list_path(@tip, %{@request | page: 1})}
      out_of_range
    />
    """
  end

  defp reviews(%{reviews: %{entries: []}} = assigns) do
    ~H"""
    <UI.notice id="reviews-empty">
      {if Discovery.filtered?(@request.filters),
        do: "No reviews match these filters",
        else: "No reviews yet"}
    </UI.notice>
    """
  end

  defp reviews(assigns) do
    ~H"""
    <div id="review-list">
      <Reader.review_card
        :for={review <- @reviews.entries}
        review={review}
        href={Reader.review_path(review.id, sort_params(@request.sort))}
        own={!!@own_review and @own_review.id == review.id}
        confirm_delete={@confirm_delete == review.id}
      />
    </div>
    <UI.page_nav
      page={@request.page}
      prev_href={@request.page > 1 && list_path(@tip, %{@request | page: @request.page - 1})}
      next_href={@reviews.has_more && list_path(@tip, %{@request | page: @request.page + 1})}
      first_href={list_path(@tip, %{@request | page: 1})}
    />
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    options = %{Discovery.filter_options() | technique: []}
    {:ok, socket |> assign(options: options, request: nil) |> ReviewActions.attach()}
  end

  @impl true
  def handle_params(%{"id" => id, "slug" => slug} = params, _uri, socket) do
    case request(id, params, socket.assigns.options) do
      request when request == socket.assigns.request -> {:noreply, socket}
      request -> {:noreply, load(socket, request, slug)}
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    request = socket.assigns.request
    options = socket.assigns.options
    changed = %{request | sort: sort(params), filters: Discovery.filters(params, options)}

    if changed.sort == request.sort and changed.filters == request.filters,
      do: {:noreply, socket},
      else:
        {:noreply, push_patch(socket, to: list_path(socket.assigns.tip, %{changed | page: 1}))}
  end

  defp load(socket, request, slug) do
    case read(socket, request) do
      {:ok, %{tip: %{slug: ^slug} = tip} = page} ->
        assign(socket,
          request: request,
          tip: tip,
          own_review: page.own_review,
          reviews: page.reviews,
          confirm_delete: nil,
          path: list_path(tip, request),
          page_title: tip.title
        )

      {:ok, %{tip: tip}} ->
        push_navigate(socket, to: list_path(tip, request), replace: true)

      {:error, :not_found} ->
        raise TipsWeb.NotFoundError

      {:error, :unauthenticated} ->
        UserAuth.require_login(socket)
    end
  end

  # A page past the last offset still reads the tip, with an empty list.
  defp read(socket, %{id: id, sort: sort, filters: filters, page: page}) do
    offset = if page > @last_page, do: 0, else: (page - 1) * @page_size
    opts = [sort: sort, offset: offset] ++ Discovery.content_filters(filters)

    case Content.get_tip_page(UserAuth.viewer(socket), id, opts) do
      {:ok, page_result} when page > @last_page ->
        {:ok, %{page_result | reviews: :out_of_range}}

      {:ok, %{reviews: %{entries: []}} = page_result} when page > 1 ->
        {:ok, %{page_result | reviews: :out_of_range}}

      result ->
        result
    end
  end

  ## URL state

  defp request(id, params, options) do
    %{
      id: id,
      sort: sort(params),
      filters: Discovery.filters(params, options),
      page: Discovery.page(params)
    }
  end

  defp sort(%{"sort" => "new"}), do: :new
  defp sort(_params), do: :best

  defp sort_params(sort), do: [sort: if(sort == :new, do: "new")]

  # Best and page 1 are the defaults, left out of the URL.
  defp list_path(tip, %{sort: sort, filters: filters, page: page}) do
    Reader.tip_path(
      tip,
      sort_params(sort) ++ Discovery.filter_params(filters) ++ [page: Discovery.page_param(page)]
    )
  end
end
