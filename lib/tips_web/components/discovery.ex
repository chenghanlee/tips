defmodule TipsWeb.Discovery do
  @moduledoc """
  URL state, filter selects and tip rows shared by browse (`/`) and search
  (`/search`).

  Each page owns a request map with at least `filters` and `page`, and a
  `path` function that turns a request into its URL. URL normalization:

    * A filter value that is not an active curated id is All (`nil`).
    * A `page` that is not a positive integer is 1.
    * A query has its whitespace trimmed and collapsed; a blank one is `nil`.
  """
  use Phoenix.Component
  use TipsWeb, :verified_routes

  alias Tips.Content
  alias TipsWeb.{Reader, UI}

  @filters [:technique, :model, :environment]
  @labels %{technique: "Technique", model: "Model", environment: "Environment"}
  @content_options %{technique: :tag_id, model: :model_id, environment: :environment_id}

  @doc "The blank-search message from the shared trim check."
  def blank_message, do: "Enter a task or keywords to search."

  @doc "The note before the filter selects."
  def filter_note,
    do:
      "Changing a selection updates the list. Model and Environment match the tip author's setup."

  @doc "The active curated choices of each filter, in display order."
  def filter_options do
    choices = Content.list_filter_choices()
    %{technique: choices.tags, model: choices.models, environment: choices.environments}
  end

  @doc "The applied filters in `params`; a value that is not an active choice is `nil`."
  def filters(params, options) do
    Map.new(@filters, fn filter ->
      value = params[Atom.to_string(filter)]
      {filter, if(Enum.any?(options[filter], &(&1.id == value)), do: value)}
    end)
  end

  @doc "Every filter at All."
  def no_filters, do: Map.new(@filters, &{&1, nil})

  def filtered?(filters), do: Enum.any?(filters, fn {_filter, id} -> id end)

  @doc "The filters as `Tips.Content.list_tips/2` and `search_tips/3` options."
  def content_filters(filters) do
    for {filter, id} <- filters, id, do: {Map.fetch!(@content_options, filter), id}
  end

  @doc "The requested page: a positive integer, else 1."
  def page(%{"page" => page}) when is_binary(page) do
    case Integer.parse(page) do
      {page, ""} when page > 0 -> page
      _invalid -> 1
    end
  end

  def page(_params), do: 1

  @doc "The query with whitespace trimmed and collapsed, or `nil` when blank."
  def normalize_query(q) when is_binary(q) do
    case String.split(q) do
      [] -> nil
      words -> Enum.join(words, " ")
    end
  end

  def normalize_query(_q), do: nil

  @doc "The search URL of a `q`, `filters` and `page` request."
  def search_path(%{q: q, filters: filters, page: page}) do
    ~p"/search?#{compact([q: q] ++ filter_params(filters) ++ [page: page_param(page)])}"
  end

  @doc "Drops `nil` values from URL parameters."
  def compact(params), do: Enum.reject(params, fn {_key, value} -> is_nil(value) end)

  @doc "The filters as URL parameters, `nil` for All."
  def filter_params(filters), do: Enum.map(@filters, &{&1, filters[&1]})

  @doc "The page as a URL parameter; page 1 is left out."
  def page_param(page), do: if(page > 1, do: page)

  @doc "\" · Technique: Workflow · Page 2\" for a heading."
  def heading_details(%{filters: filters, page: page}, options) do
    labels =
      for filter <- @filters, id = filters[filter] do
        "#{Map.fetch!(@labels, filter)}: #{Enum.find(options[filter], &(&1.id == id)).label}"
      end

    pages = if page > 1, do: ["Page #{page}"], else: []
    Enum.map_join(labels ++ pages, "", &" · #{&1}")
  end

  @doc """
  Renders the Technique, Model and Environment selects, each with All, for a
  `UI.filter_bar/1`.
  """
  attr :options, :map, required: true
  attr :filters, :map, required: true

  def filter_selects(assigns) do
    assigns = assign(assigns, names: @filters, labels: @labels)

    ~H"""
    <UI.filter_select
      :for={filter <- @names}
      id={Atom.to_string(filter)}
      name={Atom.to_string(filter)}
      label={Map.fetch!(@labels, filter)}
      options={[{"All", ""} | Enum.map(@options[filter], &{&1.label, &1.id})]}
      value={@filters[filter]}
    />
    """
  end

  @doc """
  The `UI.tip_row/1` map of a tip summary. A curated label patches only its
  own filter, keeping the rest of `request`, on page 1; the filter already
  applied keeps the current URL. Free-text models are plain text.
  """
  def row(tip, request, path) do
    %{
      id: "tip-#{tip.id}",
      title: tip.title,
      href: Reader.tip_path(tip),
      net_score: tip.score,
      review_count: tip.review_count,
      age: age(tip.created_at),
      datetime: DateTime.to_iso8601(tip.created_at),
      author: author(tip.author),
      setup: setup(tip, request, path)
    }
  end

  # No profile page exists yet, so the author is plain text.
  defp author(%{handle: handle}), do: %{handle: handle, href: nil}
  defp author(:deleted_account), do: %{handle: "[deleted]", href: nil}

  defp setup(tip, request, path) do
    filter_path = fn filter, id ->
      if request.filters[filter] == id,
        do: path.(request),
        else: path.(%{request | filters: Map.put(request.filters, filter, id), page: 1})
    end

    %{
      patch: true,
      technique: {tip.tag.label, filter_path.(:technique, tip.tag.id)},
      model: model(tip.model, filter_path),
      environment:
        tip.environment &&
          {tip.environment.label, filter_path.(:environment, tip.environment.id)}
    }
  end

  defp model(nil, _filter_path), do: nil
  defp model(%{id: nil, label: label}, _filter_path), do: {:free_text, label}

  defp model(%{id: id, label: label}, filter_path),
    do: {:curated, label, filter_path.(:model, id)}

  @doc ~s(How long ago `at` was: "just now", "5 minutes ago", "2 days ago".)
  def age(at) do
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
