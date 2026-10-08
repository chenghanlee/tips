defmodule TipsWeb.Reader do
  @moduledoc """
  Tip-page components owned by #77 in `docs/design/visual/components.md`.

  They render only `Tips.Content.Projection` maps. A tip may be a placeholder
  (`state: :deleted | :removed`), which carries nothing but its id, title and
  slug. Text only: attachments render nothing until `attachment_view` (#99).
  Editor targets are plain paths until the editor routes (#78) mount them.

  A review card's Delete sends `confirm_delete`, `cancel_delete` and `delete`
  events; `TipsWeb.ReviewActions` handles them on each page that renders cards.
  Vote controls send `vote` events, which `TipsWeb.VoteActions` handles.
  """
  use TipsWeb, :html

  # Readable Markdown without a typography plugin; the sanitizer allows only
  # these elements.
  @markdown_class [
    "grid gap-3 break-words",
    "[&_h1]:text-xl [&_h2]:text-lg [&_h3]:text-base [&_h1,&_h2,&_h3,&_h4,&_h5,&_h6]:font-semibold",
    "[&_ul]:list-disc [&_ol]:list-decimal [&_ul,&_ol]:pl-6",
    "[&_blockquote]:border-l-2 [&_blockquote]:pl-3 [&_a]:underline",
    "[&_code]:font-mono [&_code]:text-sm",
    "[&_pre]:whitespace-pre-wrap [&_pre]:rounded-md [&_pre]:bg-muted [&_pre]:p-3",
    "[&_table]:text-sm [&_th,&_td]:border [&_th,&_td]:px-2 [&_th,&_td]:py-1"
  ]

  @doc "The tip permalink from its projected id and slug, placeholders included."
  def tip_path(%{id: id, slug: slug}), do: ~p"/tips/#{TipsWeb.TipId.encode(id)}/#{slug}"

  @doc "The tip permalink with review-list URL parameters; `nil` values are left out."
  def tip_path(tip, params), do: tip_path(tip) <> query(params)

  @doc """
  The single-review view of `id`. `params` carries only the review sort, for
  its Show all reviews link.
  """
  def review_path(id, params \\ []), do: ~p"/reviews/#{id}" <> query(params)

  defp query(params) do
    case Enum.reject(params, fn {_key, value} -> is_nil(value) end) do
      [] -> ""
      params -> "?" <> URI.encode_query(params)
    end
  end

  # The contribution control state for the tip page header, first match wins:
  # own review, unavailable tip, anonymous viewer, review capability, none.
  defp contribution(_tip, %{id: review_id}, _signed_in?, sort_params),
    do: {:own_review, review_path(review_id, sort_params)}

  defp contribution(%{state: state}, nil, _signed_in?, _sort_params) when state != :visible,
    do: {:not_accepting, nil}

  defp contribution(%{removed: true}, nil, _signed_in?, _sort_params), do: {:not_accepting, nil}

  defp contribution(tip, nil, false, _sort_params),
    do: {:sign_in, TipsWeb.UserAuth.with_return_to(~p"/users/log-in", tip_path(tip))}

  defp contribution(%{id: id, capabilities: %{review: true}}, nil, true, _sort_params),
    do: {:write, "/editor/tips/#{id}/reviews/new"}

  defp contribution(_tip, nil, true, _sort_params), do: {:none, nil}

  @doc """
  Renders the tip page header: title, author, dates, setup, the tip's vote
  control or counts, its actions and the contribution control. A placeholder
  renders only its title and the contribution control.
  """
  attr :tip, :map, required: true
  attr :own_review, :map, default: nil
  attr :signed_in, :boolean, required: true
  attr :sort_params, :list, default: [], doc: "the review sort, kept by the Your review link"
  attr :vote, :map, default: nil, doc: "`TipsWeb.VoteActions.control/4` attrs; nil shows counts"

  def tip_header(assigns) do
    {state, href} =
      contribution(assigns.tip, assigns.own_review, assigns.signed_in, assigns.sort_params)

    assigns = assign(assigns, contribution_state: state, contribution_href: href)

    ~H"""
    <header id="tip-header" class="grid gap-3">
      <h1 class="text-2xl font-semibold">{@tip.title}</h1>
      <%= if @tip.state == :visible do %>
        <div class="flex flex-wrap items-center gap-x-3 text-sm text-muted-foreground">
          <span>by {author(@tip.author)}</span>
          <.dates created_at={@tip.created_at} edited_at={@tip.edited_at} />
        </div>
        <div class="flex flex-wrap items-center gap-x-3 text-sm text-muted-foreground">
          <UI.setup_meta {tip_setup(@tip)} />
        </div>
      <% end %>
      <div class="flex flex-wrap items-center gap-3">
        <.votes
          :if={@tip.state == :visible}
          id="tip-vote"
          vote={@vote}
          helpful={@tip.up_count}
          not_helpful={@tip.down_count}
        />
        <.contribution_control state={@contribution_state} href={@contribution_href} />
      </div>
      <.actions
        :if={@tip.state == :visible}
        capabilities={@tip.capabilities}
        edit_href={"/editor/tips/#{@tip.id}/edit"}
      />
    </header>
    """
  end

  @doc """
  Renders the tip context above a selected review: the projected title linking
  to the tip permalink, then author and date for a readable tip.
  """
  attr :tip, :map, required: true

  def tip_context(assigns) do
    ~H"""
    <header id="tip-context" class="grid gap-1">
      <h1 class="text-2xl font-semibold">
        <.link navigate={tip_path(@tip)}>{@tip.title}</.link>
      </h1>
      <div
        :if={@tip.state == :visible}
        class="flex flex-wrap items-center gap-x-3 text-sm text-muted-foreground"
      >
        <span>by {author(@tip.author)}</span>
        <.dates created_at={@tip.created_at} edited_at={@tip.edited_at} />
      </div>
    </header>
    """
  end

  @doc """
  Renders the one contribution control by viewer state. `:not_accepting` is a
  disabled button with its explanation and no sign-in link; `:none` renders
  nothing.
  """
  attr :state, :atom,
    values: [:own_review, :write, :sign_in, :not_accepting, :none],
    required: true

  attr :href, :string, default: nil

  def contribution_control(%{state: :none} = assigns), do: ~H""

  def contribution_control(%{state: :not_accepting} = assigns) do
    ~H"""
    <div id="contribution-control" class="flex flex-wrap items-center gap-x-3 gap-y-1">
      <UI.button size="lg" disabled aria-describedby="contribution-control-why">
        Write a review
      </UI.button>
      <p id="contribution-control-why" class="text-sm">This tip is not accepting reviews.</p>
    </div>
    """
  end

  def contribution_control(assigns) do
    ~H"""
    <div id="contribution-control">
      <.link href={@href} class={link_button_class("default", "lg")}>
        {contribution_label(@state)}
      </.link>
    </div>
    """
  end

  defp contribution_label(:own_review), do: "Your review"
  defp contribution_label(:write), do: "Tried this? Write a review"
  defp contribution_label(:sign_in), do: "Sign in to review"

  @doc "Renders authored Markdown through `TipsWeb.Markdown`."
  attr :id, :string, default: nil
  attr :text, :string, required: true

  def markdown(assigns) do
    ~H"""
    <div id={@id} class={markdown_class()}>{TipsWeb.Markdown.to_html(@text)}</div>
    """
  end

  defp markdown_class, do: @markdown_class

  @doc """
  Renders Prompt or Result text verbatim and escaped. Copy is added by #99.
  The leading newline keeps a stored leading newline, which HTML drops after
  `<pre>`.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :text, :string, required: true

  def verbatim_block(assigns) do
    ~H"""
    <figure id={@id} class="grid gap-2">
      <figcaption id={"#{@id}-label"} class="text-sm font-medium">{@label}</figcaption>
      <pre
        aria-labelledby={"#{@id}-label"}
        class="whitespace-pre-wrap rounded-md bg-muted p-3 font-mono text-sm [overflow-wrap:anywhere]"
        phx-no-format
      >{"\n"}{@text}</pre>
    </figure>
    """
  end

  @doc """
  Renders the generic notice an author or moderator sees on content moderators
  hid. No reason or report details exist here to show.
  """
  attr :id, :string, required: true
  attr :editable, :boolean, required: true

  def removed_notice(assigns) do
    ~H"""
    <UI.notice id={@id} role="status">
      <strong>Removed by moderation.</strong>
      <span :if={@editable}>You can still edit it; saving changes does not restore visibility.</span>
    </UI.notice>
    """
  end

  @doc """
  Renders one readable review: author, dates, reviewer setup, Markdown body,
  the Prompt and Result disclosure, the vote control or counts and the
  viewer's actions. `open` opens the disclosure, as on the single-review view.
  `href` is the author heading's link, the card's own anchor by default. `own`
  adds the Your review badge. `confirm_delete` shows the delete confirmation.
  """
  attr :review, :map, required: true
  attr :vote, :map, default: nil, doc: "`TipsWeb.VoteActions.control/4` attrs; nil shows counts"
  attr :open, :boolean, default: false
  attr :href, :string, default: nil
  attr :own, :boolean, default: false
  attr :confirm_delete, :boolean, default: false

  def review_card(assigns) do
    assigns = assign(assigns, :dom_id, "review-#{assigns.review.id}")

    ~H"""
    <article id={@dom_id} aria-labelledby={"#{@dom_id}-author"} class="grid gap-3 border-b py-4">
      <div class="grid gap-1">
        <h2 id={"#{@dom_id}-author"} class="flex flex-wrap items-center gap-2 text-base font-semibold">
          <.link :if={@href} navigate={@href}>{author(@review.author)}</.link>
          <a :if={!@href} href={"##{@dom_id}"}>{author(@review.author)}</a>
          <span :if={@own} data-badge class="rounded-md border px-2 text-sm font-medium">
            Your review
          </span>
        </h2>
        <div class="flex flex-wrap items-center gap-x-3 text-sm text-muted-foreground">
          <.dates created_at={@review.created_at} edited_at={@review.edited_at} />
          <span :if={@review.model || @review.environment}>
            Reviewer setup: <UI.setup_meta {review_setup(@review)} linkable={false} />
          </span>
        </div>
      </div>
      <.removed_notice
        :if={@review.removed}
        id={"#{@dom_id}-removed-notice"}
        editable={@review.capabilities.edit}
      />
      <.markdown text={@review.body} />
      <UI.disclosure
        :if={@review.prompt || @review.output}
        id={"#{@dom_id}-evidence"}
        open={@open}
        summary={evidence_summary(@review)}
      >
        <.verbatim_block
          :if={@review.prompt}
          id={"#{@dom_id}-prompt"}
          label="Prompt"
          text={@review.prompt}
        />
        <.verbatim_block
          :if={@review.output}
          id={"#{@dom_id}-result"}
          label="Result"
          text={@review.output}
        />
      </UI.disclosure>
      <.votes
        id={"#{@dom_id}-vote"}
        vote={@vote}
        helpful={@review.up_count}
        not_helpful={@review.down_count}
        describedby={"#{@dom_id}-author"}
      />
      <.actions
        capabilities={@review.capabilities}
        edit_href={"/editor/reviews/#{@review.id}/edit"}
        delete={%{id: @review.id, dom_id: @dom_id, confirm: @confirm_delete}}
      />
    </article>
    """
  end

  # The detail vote control, or plain counts for a viewer who cannot vote.
  attr :id, :string, required: true
  attr :vote, :map, required: true
  attr :helpful, :integer, required: true
  attr :not_helpful, :integer, required: true
  attr :describedby, :string, default: nil

  defp votes(%{vote: vote} = assigns) when is_map(vote) do
    ~H"""
    <UI.vote_control id={@id} variant="detail" describedby={@describedby} {@vote} />
    """
  end

  defp votes(assigns) do
    ~H"""
    <p id={@id} class="flex flex-wrap gap-x-3 text-sm">
      <span>Helpful {@helpful}</span>
      <span>Not helpful {@not_helpful}</span>
    </p>
    """
  end

  # Edit and, on a review, Delete, each by capability. Delete opens one
  # confirmation; Cancel returns focus to Delete.
  attr :capabilities, :map, required: true
  attr :edit_href, :string, required: true
  attr :delete, :map, default: nil, doc: "a review's `id`, `dom_id` and `confirm` state"

  defp actions(assigns) do
    assigns = assign(assigns, :delete, assigns.capabilities.delete && assigns.delete)

    ~H"""
    <div :if={@capabilities.edit or @delete} class="flex flex-wrap gap-2">
      <.link :if={@capabilities.edit} href={@edit_href} class={link_button_class("outline", "sm")}>
        Edit
      </.link>
      <UI.button
        :if={@delete}
        id={"#{@delete.dom_id}-delete"}
        variant="outline"
        phx-click="confirm_delete"
        phx-value-id={@delete.id}
        aria-expanded={to_string(@delete.confirm)}
      >
        Delete
      </UI.button>
    </div>
    <div
      :if={@delete && @delete.confirm}
      id={"#{@delete.dom_id}-delete-confirm"}
      role="group"
      aria-labelledby={"#{@delete.dom_id}-delete-question"}
      class="grid gap-2 rounded-md border p-3"
    >
      <p id={"#{@delete.dom_id}-delete-question"} tabindex="-1" phx-mounted={JS.focus()}>
        Delete this review? This can't be undone.
      </p>
      <div class="flex flex-wrap gap-2">
        <UI.button variant="destructive" phx-click="delete" phx-disable-with="Deleting...">
          Delete review
        </UI.button>
        <UI.button
          variant="outline"
          phx-click={JS.push("cancel_delete") |> JS.focus(to: "##{@delete.dom_id}-delete")}
        >
          Cancel
        </UI.button>
      </div>
    </div>
    """
  end

  attr :created_at, DateTime, required: true
  attr :edited_at, DateTime, default: nil

  defp dates(assigns) do
    ~H"""
    <span>Published <.time at={@created_at} /></span>
    <span :if={@edited_at}>Updated <.time at={@edited_at} /></span>
    """
  end

  attr :at, DateTime, required: true

  defp time(assigns) do
    ~H"""
    <time datetime={DateTime.to_iso8601(@at)}>{Calendar.strftime(@at, "%b %-d, %Y")}</time>
    """
  end

  defp author(%{handle: handle}), do: handle
  defp author(:deleted_account), do: "[deleted]"

  # Tip metadata links open browse with that single filter.
  defp tip_setup(tip) do
    %{
      technique: {tip.tag.label, ~p"/?#{[technique: tip.tag.id]}"},
      model: model(tip.model),
      environment:
        tip.environment && {tip.environment.label, ~p"/?#{[environment: tip.environment.id]}"}
    }
  end

  defp review_setup(review) do
    %{
      model: model(review.model),
      environment: review.environment && {review.environment.label, nil}
    }
  end

  defp model(nil), do: nil
  defp model(%{id: nil, label: label}), do: {:free_text, label}
  defp model(%{id: id, label: label}), do: {:curated, label, ~p"/?#{[model: id]}"}

  defp evidence_summary(%{prompt: prompt, output: output})
       when is_binary(prompt) and is_binary(output),
       do: "Prompt and result"

  defp evidence_summary(%{prompt: prompt}) when is_binary(prompt), do: "Prompt"
  defp evidence_summary(_review), do: "Result"

  defp link_button_class(variant, size) do
    TwMerge.merge([
      SaladUI.Helpers.button_variant(%{variant: variant, size: size}),
      "gap-1 focus-visible:ring-0"
    ])
  end
end
