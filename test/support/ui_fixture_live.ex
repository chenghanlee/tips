defmodule TipsWeb.UIFixtureLive do
  @moduledoc """
  Test-only page at `/_ui` that drives `TipsWeb.UI` through URL patches,
  delayed vote confirmation and reconnects, the way page LiveViews will.
  """
  use TipsWeb, :live_view

  @filters ~w(technique model environment)
  @options %{
    "technique" => [{"All", ""}, {"Planning", "planning"}, {"Test-first", "test-first"}],
    "model" => [
      {"All", ""},
      {"Claude Opus 5.5", "claude-opus-5-5"},
      {"Claude Sonnet 5", "claude-sonnet-5"}
    ],
    "environment" => [{"All", ""}, {"Claude Code", "claude-code"}, {"Codex CLI", "codex-cli"}]
  }
  @confirm_after_ms 500

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <UI.search_form value={@query["q"]} error={@search_error} action={~p"/_ui"} />

      <UI.filter_bar
        id="filters"
        active={Map.keys(@query) -- ["q"] != []}
        clear_href={path(Map.take(@query, ["q"]))}
        phx-change="filter"
      >
        <UI.filter_select
          :for={name <- @filters}
          id={name}
          name={name}
          label={String.capitalize(name)}
          options={@options[name]}
          value={@query[name]}
        />
      </UI.filter_bar>

      <p id="applied" class="text-sm">{@uri_query}</p>

      <section id="results" class="space-y-3">
        <h2 class="text-lg font-semibold">
          {if @query["q"], do: "Results for “#{@query["q"]}”", else: "Hot tips"}
        </h2>
        <ol class="border-t">
          <UI.tip_row tip={tip()} vote={Map.put(@votes["tip"], :target, "tip")}>
            <:excerpt source="Review" href="/_ui#review">the loop caught a race</:excerpt>
          </UI.tip_row>
        </ol>
        <UI.page_nav
          page={1}
          next_href={path(Map.put(@query, "page", "2"))}
          first_href={path(@query)}
        />
      </section>

      <UI.disclosure id="evidence" summary="Prompt and result · 1 image">
        <p>Evidence body.</p>
      </UI.disclosure>

      <UI.vote_control
        id="review-vote"
        variant="detail"
        target="review"
        counts={%{helpful: 8, not_helpful: 1}}
        {@votes["review"]}
      />

      <UI.notice role="status">Loading results…</UI.notice>

      <UI.error_summary errors={[{"fixture_body", "Body: can't be blank"}]} />

      <.form for={@form} id="fixture_form" phx-change="validate" class="space-y-4">
        <UI.field field={@form[:body]} label="Body" helper="Say what happened." />
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       filters: @filters,
       options: @options,
       search_error: nil,
       votes: %{
         "tip" => %{selected: nil, pending: false},
         "review" => %{selected: nil, pending: false}
       },
       form: body_form(%{})
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    query = params |> Map.take(["q" | @filters]) |> Map.reject(fn {_, value} -> value == "" end)
    {:noreply, assign(socket, query: query, uri_query: URI.parse(uri).query, search_error: nil)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    filters = params |> Map.take(@filters) |> Map.reject(fn {_, value} -> value == "" end)

    {:noreply,
     push_patch(socket, to: path(Map.merge(Map.take(socket.assigns.query, ["q"]), filters)))}
  end

  def handle_event("search", %{"q" => q}, socket) do
    case String.trim(q) do
      "" ->
        {:noreply, assign(socket, search_error: "Enter a task or keywords to search.")}

      q ->
        {:noreply, push_patch(socket, to: path(Map.put(socket.assigns.query, "q", q)))}
    end
  end

  def handle_event("vote", %{"target" => target, "choice" => choice}, socket) do
    Process.send_after(
      self(),
      {:confirm_vote, target, String.to_existing_atom(choice)},
      @confirm_after_ms
    )

    {:noreply, update(socket, :votes, &put_in(&1, [target, :pending], true))}
  end

  def handle_event("validate", %{"fixture" => params}, socket) do
    {:noreply, assign(socket, form: body_form(params))}
  end

  @impl true
  def handle_info({:confirm_vote, target, choice}, socket) do
    {:noreply, update(socket, :votes, &Map.put(&1, target, %{selected: choice, pending: false}))}
  end

  defp body_form(params) do
    errors = if Map.get(params, "body", "") == "", do: [body: {"can't be blank", []}], else: []
    to_form(params, as: :fixture, errors: errors, action: :validate)
  end

  defp path(query) when map_size(query) == 0, do: ~p"/_ui"
  defp path(query), do: ~p"/_ui?#{query}"

  defp tip do
    %{
      id: "tip",
      title: "Ask for a written plan before a large refactor",
      href: "/_ui#tip",
      net_score: 42,
      review_count: 12,
      age: "3 hours ago",
      datetime: "2026-09-23T09:10:00Z",
      author: %{handle: "ada", href: "/_ui#ada"},
      setup: %{
        technique: {"Planning", "/_ui?technique=planning"},
        model: {:free_text, "local-qwen-coder-32b"}
      }
    }
  end
end
