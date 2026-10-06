defmodule TipsWeb.UI do
  @moduledoc """
  Shared Tips components from `docs/design/visual/components.md`.

  Rules for every component here:

    * No component holds page state. The page LiveView owns form, filter,
      search and vote state, passes it in, and handles the ordinary `phx-*`
      events and links the components emit.
    * Native elements stay native: `<select>`, `<details>`, `<form>`,
      `<button>` and `<a>`. No SaladUI JavaScript components or hooks.
    * Call components by module (`<TipsWeb.UI.button>`), so they never clash
      with `TipsWeb.CoreComponents`. SaladUI is called by module too.
    * Styling uses the tokens in `docs/design/visual/tokens.md`.
  """
  use Phoenix.Component
  use TipsWeb, :verified_routes

  alias Phoenix.LiveView.JS
  alias SaladUI.Form
  alias TipsWeb.{CoreComponents, UserAuth}

  # SaladUI's input look, native. Inputs, textareas and selects use text-base so
  # iOS does not zoom on focus; without SaladUI's outline-hidden and focus ring,
  # the base :focus-visible outline shows.
  @control_class "flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-base placeholder:text-muted-foreground focus-visible:border-ring aria-invalid:border-destructive disabled:cursor-not-allowed disabled:opacity-50"
  @textarea_overrides "text-base focus-visible:ring-0 aria-invalid:border-destructive"

  @doc """
  Renders the top bar: the Tips home link and the account links.

  With `editor`, every exit is an ordinary `<a href>` so the editor's leave
  warning covers it. With `return_to`, Log in and Register carry that page as
  their `return_to` query, so sign-in comes back to it.

      <TipsWeb.UI.site_header current_scope={@current_scope} />
  """
  attr :current_scope, :map, default: nil
  attr :editor, :boolean, default: false
  attr :return_to, :string, default: nil

  def site_header(assigns) do
    assigns =
      assign(assigns,
        register_href: UserAuth.with_return_to(~p"/users/register", assigns.return_to),
        log_in_href: UserAuth.with_return_to(~p"/users/log-in", assigns.return_to)
      )

    ~H"""
    <header class="border-b">
      <nav
        aria-label="Site"
        class={[
          "mx-auto flex items-center justify-between gap-4 px-4 py-2",
          if(@editor, do: "max-w-editor", else: "max-w-reading")
        ]}
      >
        <.exit_link editor={@editor} href={~p"/"} class="font-semibold no-underline">Tips</.exit_link>
        <div class="flex flex-wrap items-center justify-end gap-x-4 text-sm">
          <%= if @current_scope do %>
            <span class="text-muted-foreground">{@current_scope.user.email}</span>
            <.exit_link editor={@editor} href={~p"/users/settings"}>Settings</.exit_link>
            <.link href={~p"/users/log-out"} method="delete" class="inline-flex min-h-8 items-center">
              Log out
            </.link>
          <% else %>
            <.exit_link editor={@editor} href={@register_href}>Register</.exit_link>
            <.exit_link editor={@editor} href={@log_in_href}>Log in</.exit_link>
          <% end %>
        </div>
      </nav>
    </header>
    """
  end

  attr :editor, :boolean, required: true
  attr :href, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block, required: true

  defp exit_link(%{editor: true} = assigns) do
    ~H"""
    <a href={@href} class={["inline-flex min-h-8 items-center", @class]}>{render_slot(@inner_block)}</a>
    """
  end

  defp exit_link(assigns) do
    ~H"""
    <.link navigate={@href} class={["inline-flex min-h-8 items-center", @class]}>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Renders a SaladUI button with the Tips sizes: `lg` (40 px) for primary
  actions, `sm` (32 px) otherwise.

  Links styled as buttons use `SaladUI.Helpers.button_variant/1` on `<.link>`.

      <TipsWeb.UI.button size="lg" phx-disable-with="Saving...">Save</TipsWeb.UI.button>
  """
  attr :variant, :string,
    values: ~w(default outline secondary ghost destructive link),
    default: "default"

  attr :size, :string, values: ~w(lg sm), default: "sm"
  attr :type, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled form name value)
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <SaladUI.Button.button
      type={@type}
      variant={@variant}
      size={@size}
      class={[@size == "sm" && "text-sm", "focus-visible:ring-0", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </SaladUI.Button.button>
    """
  end

  @doc """
  Renders the label, control, helper and error for one form field.

  `type` is `textarea`, `select` or a native input type. Errors appear once
  the input has been used or the form submitted (`used_input?/1`); the control
  then carries `aria-invalid`, and `aria-describedby` names the error and
  helper. No `maxlength` and no `required`: the server returns length and
  presence errors with the input preserved.

      <TipsWeb.UI.field field={@form[:body]} type="textarea" label="Review" helper="Markdown is supported." />
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :options, :list, default: [], doc: "options for `type=\"select\"`"
  attr :helper, :string, default: nil
  attr :rows, :integer, default: nil

  attr :rest, :global,
    include: ~w(autocomplete inputmode placeholder readonly disabled spellcheck)

  def field(%{field: field} = assigns) do
    errors =
      if used_input?(field),
        do: Enum.map(field.errors, &CoreComponents.translate_error/1),
        else: []

    describedby =
      [errors != [] && "#{field.id}-error", assigns.helper && "#{field.id}-help"]
      |> Enum.filter(& &1)
      |> Enum.join(" ")

    assigns =
      assign(assigns,
        id: field.id,
        errors: errors,
        describedby: if(describedby != "", do: describedby),
        invalid: errors != [] && "true",
        control_class: @control_class,
        textarea_class: @textarea_overrides
      )

    ~H"""
    <Form.form_item>
      <Form.form_label for={@id}>{@label}</Form.form_label>
      <div>
        <SaladUI.Textarea.textarea
          :if={@type == "textarea"}
          id={@id}
          name={@field.name}
          value={@field.value}
          rows={@rows}
          class={@textarea_class}
          aria-invalid={@invalid}
          aria-describedby={@describedby}
          {@rest}
        />
        <select
          :if={@type == "select"}
          id={@id}
          name={@field.name}
          class={@control_class}
          aria-invalid={@invalid}
          aria-describedby={@describedby}
          {@rest}
        >
          {Phoenix.HTML.Form.options_for_select(@options, @field.value)}
        </select>
        <%!-- Native, not SaladUI.Input: account tests match `<input type= name= id= value=`,
          and SaladUI renders class first. The wrapper keeps LiveView's root marker off it. --%>
        <input
          :if={@type not in ["textarea", "select"]}
          type={@type}
          name={@field.name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @field.value)}
          class={@control_class}
          aria-invalid={@invalid}
          aria-describedby={@describedby}
          {@rest}
        />
      </div>
      <Form.form_description :if={@helper} id={"#{@id}-help"}>{@helper}</Form.form_description>
      <Form.form_message :if={@errors != []} id={"#{@id}-error"} errors={@errors} />
    </Form.form_item>
    """
  end

  @doc """
  Renders the optional model control of the tip and review forms: a curated
  model select and, only while the select is `other`, the "Model name" input.

  The page re-renders it on its existing `phx-change`; there is no hook.

      <TipsWeb.UI.model_field
        select_field={@form[:model_id]}
        text_field={@form[:model_other]}
        options={[{"Not specified", ""}, {"Claude Opus 5.5", "opus"}, {"Other model…", "other"}]}
      />
  """
  attr :select_field, Phoenix.HTML.FormField, required: true
  attr :text_field, Phoenix.HTML.FormField, required: true
  attr :options, :list, required: true
  attr :label, :string, default: "Model used (optional)"

  def model_field(assigns) do
    ~H"""
    <div class="grid gap-2">
      <.field field={@select_field} type="select" label={@label} options={@options} />
      <.field
        :if={@select_field.value == "other"}
        field={@text_field}
        label="Model name"
        helper="Up to 80 characters. Shown as plain text, not as a filter."
      />
    </div>
    """
  end

  @doc """
  Renders one labelled native select that updates the list on change.
  Put it inside `filter_bar/1`, whose form emits the change.

      <TipsWeb.UI.filter_select
        id="technique"
        name="technique"
        label="Technique"
        options={[{"All", ""}, {"Planning", "planning"}]}
        value={@technique}
      />
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :options, :list, required: true, doc: "`{label, value}` pairs, All first"
  attr :value, :string, default: nil

  def filter_select(assigns) do
    assigns = assign(assigns, :class, @control_class)

    ~H"""
    <div class="grid content-start gap-1">
      <label for={@id} class="text-sm font-medium">{@label}</label>
      <select id={@id} name={@name} class={@class}>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
    </div>
    """
  end

  @doc """
  Renders a filter group: the behaviour note, the `filter_select/1` controls
  and, when any filter is active, Clear filters. Clear filters removes
  itself, so it moves focus to the note; the next Tab reaches the first
  select. Focus does not go to a select directly: LiveView keeps a focused
  select's current value when patching, so the select would keep showing the
  cleared filter.

  The page passes `phx-change` and patches the URL; the URL is the only
  filter state, so reconnect form recovery is off.

      <TipsWeb.UI.filter_bar id="filters" active={@filtered?} clear_href={@clear_href} phx-change="filter">
        <TipsWeb.UI.filter_select id="technique" name="technique" label="Technique" options={@techniques} value={@technique} />
      </TipsWeb.UI.filter_bar>
  """
  attr :id, :string, required: true
  attr :active, :boolean, default: false
  attr :clear_href, :string, required: true, doc: "filters at All, query and sort kept, page 1"
  attr :note, :string, default: "Changing a selection updates the list."
  attr :rest, :global
  slot :inner_block, required: true

  def filter_bar(assigns) do
    ~H"""
    <form
      id={@id}
      class="grid gap-2"
      aria-describedby={"#{@id}-note"}
      phx-auto-recover="ignore"
      {@rest}
    >
      <p id={"#{@id}-note"} class="text-sm" tabindex="-1">{@note}</p>
      <div class="grid grid-cols-[repeat(auto-fit,minmax(7.5rem,1fr))] items-end gap-x-3 gap-y-2">
        {render_slot(@inner_block)}
      </div>
      <p :if={@active}>
        <.link
          patch={@clear_href}
          phx-click={JS.focus(to: "##{@id}-note")}
          class={link_button_class("ghost")}
        >
          Clear filters
        </.link>
      </p>
    </form>
    """
  end

  @doc """
  Renders the task-framed search field with its Search button.

  The page runs the shared trim check: a blank submit sets `error` and changes
  nothing else. No `required`, which whitespace passes.

  Every submit leaves focus on the field. The focus runs before the push
  because LiveView blurs the focused element on submit and refocuses it when
  the server replies; with the field focused first, that is the field.

      <TipsWeb.UI.search_form value={@query} error={@search_error} action={~p"/search"} />
  """
  attr :id, :string, default: "q"
  attr :value, :string, default: nil, doc: "the last submitted query"
  attr :error, :string, default: nil, doc: "the blank-search message or nil"
  attr :action, :string, required: true, doc: "GET action without JavaScript"
  attr :on_submit, :string, default: "search", doc: "the LiveView submit event"

  def search_form(assigns) do
    assigns =
      assign(assigns,
        class: [@control_class, "min-w-0 flex-1"],
        describedby:
          if(assigns.error,
            do: "#{assigns.id}-error #{assigns.id}-help",
            else: "#{assigns.id}-help"
          )
      )

    ~H"""
    <form
      role="search"
      action={@action}
      method="get"
      class="grid gap-1"
      phx-submit={JS.focus(to: "##{@id}") |> JS.push(@on_submit)}
    >
      <label for={@id} class="text-sm font-medium">What are you trying to do?</label>
      <p id={"#{@id}-help"} class="text-sm text-muted-foreground">
        Describe a task or enter keywords. Search matches both meaning and words.
      </p>
      <div class="flex gap-2">
        <input
          type="search"
          id={@id}
          name="q"
          value={@value}
          class={@class}
          aria-invalid={@error && "true"}
          aria-describedby={@describedby}
        />
        <.button type="submit" size="lg" class="gap-2 px-4">
          <CoreComponents.icon name="hero-magnifying-glass" class="size-4" /> Search
        </.button>
      </div>
      <p :if={@error} id={"#{@id}-error"} class="text-sm font-medium text-destructive">{@error}</p>
    </form>
    """
  end

  @doc """
  Renders the technique, model and environment line.

  `technique` and `environment` are `{label, href}`; `model` is
  `{:curated, label, href}` or `{:free_text, label}`. Free-text models are
  always plain text; `linkable={false}` makes every part plain text.

      <TipsWeb.UI.setup_meta technique={{"Planning", "/?technique=planning"}} model={{:free_text, "local-qwen"}} />
  """
  attr :technique, :any, default: nil
  attr :model, :any, default: nil
  attr :environment, :any, default: nil
  attr :linkable, :boolean, default: true

  def setup_meta(assigns) do
    parts =
      Enum.flat_map([assigns.technique, assigns.model, assigns.environment], fn
        nil -> []
        {:curated, label, href} -> [{label, href}]
        {:free_text, label} -> [{label, nil}]
        {label, href} -> [{label, href}]
      end)

    assigns = assign(assigns, :parts, parts)

    ~H"""
    <span class="contents">
      <%= for {label, href} <- @parts do %>
        <.link :if={@linkable && href} navigate={href} class="inline-flex min-h-6 items-center">
          {label}
        </.link>
        <span :if={!(@linkable && href)}>{label}</span>
      <% end %>
    </span>
    """
  end

  @doc """
  Renders a compact text-only feed or search row. Title, tags, model, author
  and excerpt are separate links, never nested.

  `tip` has `id` (DOM id prefix), `title`, `href`, `net_score`,
  `review_count`, `age`, `datetime`, `author` (`handle`, `href`) and `setup`
  (`setup_meta/1` attrs). A nil author `href` renders the handle as plain
  text. `vote` holds the `vote_control/1` attrs; without it the row has no
  vote control.

      <TipsWeb.UI.tip_row tip={tip} vote={%{target: tip.id, selected: nil}}>
        <:excerpt source="Review" href={tip.href}>{excerpt}</:excerpt>
      </TipsWeb.UI.tip_row>
  """
  attr :tip, :map, required: true
  attr :vote, :map, default: nil

  slot :excerpt, doc: "a matching excerpt of about 200 characters" do
    attr :source, :string, required: true, doc: "Review, Prompt, Result or Reviewer setup"
    attr :href, :string, required: true
  end

  def tip_row(assigns) do
    ~H"""
    <li id={@tip.id} class="grid gap-1 border-b py-3">
      <.link
        id={"#{@tip.id}-title"}
        navigate={@tip.href}
        class="font-medium no-underline hover:underline"
      >
        {@tip.title}
      </.link>
      <div class="flex flex-wrap items-center gap-x-3 text-sm text-muted-foreground">
        <.setup_meta {@tip.setup} />
        <span>
          by
          <.link
            :if={@tip.author.href}
            navigate={@tip.author.href}
            class="inline-flex min-h-6 items-center"
          >
            {@tip.author.handle}
          </.link>
          <span :if={!@tip.author.href}>{@tip.author.handle}</span>
        </span>
        <time datetime={@tip.datetime}>{@tip.age}</time>
        <span>Net {net_score(@tip.net_score)}</span>
        <span>{review_count(@tip.review_count)}</span>
      </div>
      <.link
        :for={excerpt <- @excerpt}
        navigate={excerpt.href}
        class="block border-l-2 pl-3 text-sm no-underline hover:underline"
      >
        <span class="font-semibold">{excerpt.source}:</span> {render_slot(excerpt)}
      </.link>
      <.vote_control :if={@vote} id={"#{@tip.id}-vote"} describedby={"#{@tip.id}-title"} {@vote} />
    </li>
    """
  end

  defp net_score(score) when score > 0, do: "+#{score}"
  defp net_score(score), do: to_string(score)

  defp review_count(1), do: "1 review"
  defp review_count(count), do: "#{count} reviews"

  @doc """
  Renders Helpful / Not helpful. Emits `phx-click="vote"` with `target` and
  `choice` values; behaviour is wired by #110.

  While `pending`, both buttons carry `aria-disabled` (not `disabled`, so
  focus stays on the clicked button), clicks are ignored and a polite status
  says "Saving…".

      <TipsWeb.UI.vote_control variant="detail" target="review-12" selected={:helpful} counts={%{helpful: 8, not_helpful: 1}} />
  """
  attr :id, :string, default: nil
  attr :variant, :string, values: ~w(compact detail), default: "compact"
  attr :target, :string, required: true
  attr :selected, :atom, values: [:helpful, :not_helpful, nil], default: nil
  attr :pending, :boolean, default: false
  attr :counts, :map, default: %{helpful: 0, not_helpful: 0}
  attr :describedby, :string, default: nil, doc: "id of the voted item's title"

  def vote_control(assigns) do
    ~H"""
    <div id={@id} class="mt-1 flex flex-wrap items-center gap-2" aria-busy={@pending && "true"}>
      <.button
        :for={{choice, label} <- [helpful: "Helpful", not_helpful: "Not helpful"]}
        type="button"
        variant={if @selected == choice, do: "default", else: "outline"}
        class="aria-disabled:cursor-not-allowed aria-disabled:opacity-50"
        aria-pressed={to_string(@selected == choice)}
        aria-disabled={@pending && "true"}
        aria-describedby={@describedby}
        phx-click={!@pending && "vote"}
        phx-value-target={@target}
        phx-value-choice={choice}
      >
        {label}{if @variant == "detail", do: " #{Map.fetch!(@counts, choice)}"}
      </.button>
      <span role="status" class="text-sm">{if @pending, do: "Saving…"}</span>
    </div>
    """
  end

  @doc """
  Renders Previous, the current page and Next. A nil href hides its link.
  An empty or out-of-range page offers Previous and First page instead.

      <TipsWeb.UI.page_nav page={2} prev_href={~p"/?page=1"} next_href={~p"/?page=3"} first_href={~p"/"} />
  """
  attr :page, :integer, required: true
  attr :prev_href, :string, default: nil
  attr :next_href, :string, default: nil
  attr :first_href, :string, required: true
  attr :out_of_range, :boolean, default: false

  def page_nav(assigns) do
    ~H"""
    <nav aria-label="Pages" class="flex flex-wrap items-center justify-between gap-2">
      <.link :if={@prev_href} patch={@prev_href} rel="prev" class={link_button_class("outline")}>
        <CoreComponents.icon name="hero-chevron-left" /> Previous
      </.link>
      <%= if @out_of_range do %>
        <.link patch={@first_href} class={link_button_class("outline")}>First page</.link>
      <% else %>
        <span aria-current="page" class="text-sm font-medium">Page {@page}</span>
        <.link :if={@next_href} patch={@next_href} rel="next" class={link_button_class("outline")}>
          Next <CoreComponents.icon name="hero-chevron-right" />
        </.link>
      <% end %>
    </nav>
    """
  end

  @doc """
  Renders a one-line status, empty state, placeholder or error, with optional
  actions. `role` is rendered only when given. Not SaladUI `alert`, which
  hard-codes `role="alert"`.

      <TipsWeb.UI.notice tone="error" role="alert">
        Couldn't load this page of results.
        <:actions><TipsWeb.UI.button phx-click="retry">Retry</TipsWeb.UI.button></:actions>
      </TipsWeb.UI.notice>
  """
  attr :id, :string, default: nil
  attr :tone, :string, values: ~w(neutral error), default: "neutral"
  attr :role, :string, values: ["status", "alert", nil], default: nil
  attr :icon, :string, default: nil, doc: "a Heroicon name, such as `hero-arrow-path`"
  slot :inner_block, required: true
  slot :actions

  def notice(assigns) do
    assigns =
      assign(
        assigns,
        :icon,
        assigns.icon || (assigns.tone == "error" && "hero-exclamation-triangle")
      )

    ~H"""
    <div
      id={@id}
      role={@role}
      class={[
        "flex flex-wrap items-center gap-x-3 gap-y-2 rounded-md border p-3",
        @tone == "error" && "border-l-4 border-destructive"
      ]}
    >
      <CoreComponents.icon
        :if={@icon}
        name={@icon}
        class={["size-4 shrink-0", @tone == "error" && "text-destructive"]}
      />
      <p class="flex-[1_1_12rem]">{render_slot(@inner_block)}</p>
      {render_slot(@actions)}
    </div>
    """
  end

  @doc """
  Renders the submit-time error list: a focusable alert whose links jump to
  each field. The page moves focus to it (`JS.focus(to: "#error-summary")`).
  Renders nothing without errors.

      <TipsWeb.UI.error_summary errors={[{"review_body", "Review: write what happened"}]} />
  """
  attr :id, :string, default: "error-summary"
  attr :errors, :list, required: true, doc: "`{field_id, message}` pairs"
  attr :heading, :string, default: nil

  def error_summary(assigns) do
    assigns = assign(assigns, :heading, assigns.heading || error_heading(length(assigns.errors)))

    ~H"""
    <div
      :if={@errors != []}
      id={@id}
      role="alert"
      tabindex="-1"
      aria-labelledby={"#{@id}-heading"}
      class="grid gap-2 rounded-md border border-l-4 border-destructive p-4"
    >
      <h2 id={"#{@id}-heading"} class="text-base font-semibold text-destructive">{@heading}</h2>
      <ul class="grid list-disc gap-1 pl-6">
        <li :for={{field_id, message} <- @errors}><a href={"##{field_id}"}>{message}</a></li>
      </ul>
    </div>
    """
  end

  defp error_heading(1), do: "Fix 1 problem"
  defp error_heading(count), do: "Fix #{count} problems"

  @doc """
  Renders a native disclosure that keeps the reader's open state across
  patches (`JS.ignore_attributes(["open"])`). `open` sets only the initial
  state. Never nest disclosures.

      <TipsWeb.UI.disclosure id="review-12-evidence" summary="Prompt and result · 2 images">
        ...
      </TipsWeb.UI.disclosure>
  """
  attr :id, :string, required: true
  attr :open, :boolean, default: false
  attr :summary, :string, required: true
  slot :inner_block, required: true

  def disclosure(assigns) do
    ~H"""
    <details
      id={@id}
      open={@open}
      phx-mounted={JS.ignore_attributes(["open"])}
      class="rounded-md border [&[open]>summary]:border-b"
    >
      <summary class="min-h-8 cursor-pointer px-3 py-2 text-sm font-medium">{@summary}</summary>
      <div class="grid gap-4 p-3">{render_slot(@inner_block)}</div>
    </details>
    """
  end

  defp link_button_class(variant) do
    TwMerge.merge([
      SaladUI.Helpers.button_variant(%{variant: variant, size: "sm"}),
      "gap-1 text-sm focus-visible:ring-0"
    ])
  end
end
