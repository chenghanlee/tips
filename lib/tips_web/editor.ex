defmodule TipsWeb.Editor do
  @moduledoc """
  The page side of the tip and review editors: the form identity, the draft
  record the page renders, and the `EditorDraft` hook's restore and recovery
  events. Types and rules are in `TipsWeb.EditorContract`; the hook is
  `assets/js/editor_draft.js`.

  The page assigns `:identity`, `:record`, `:attrs`, `:form`, `:check`,
  `:refusal` and `:outcome`:

    * `:record` is the draft the page was mounted, restored or recovered with.
      It holds the submission key, the edit base and expected version. The
      hook owns the browser revision after its first save and never writes it
      back to the page.
    * `:attrs` are the current field values, exactly as typed. `phx-change`
      keeps them in step with the browser. It validates only after a submit
      failed validation; `:check` holds that submit's values and errors.
    * `:refusal` explains a refused save and `:outcome` confirms a save.

  `submit/2` validates the whole form with `Tips.Content.change_content/2`,
  readmits the session, then publishes or saves. Clearing the submitted draft
  and leaving the editor are #80's.

  The page renders `form_attrs/1` on its form and `hidden_inputs/1` inside it.
  A browser record or recovered form is untrusted input: `restore/2` and
  `recover/2` accept it only for the freshly mounted account and target, and
  only in the shape the hook and store use.
  """
  use Phoenix.Component
  use TipsWeb, :verified_routes

  alias Tips.Content
  alias TipsWeb.{AuthMailAdmission, CoreComponents, EditorContract, UserAuth}

  @kinds %{"tip" => :tip, "review" => :review}

  @fields %{
    tip: ~w(title body tag_id model_id model_other environment_id prompt output)a,
    review: ~w(body model_id model_other environment_id prompt output)a
  }

  defp fields(kind), do: Map.fetch!(@fields, kind)

  @doc """
  Assigns a fresh new-content draft: a new submission key, which is also its
  draft id, at revision 0. `attrs` are the initial values, such as a review's
  setup from its tip.
  """
  @spec assign_new(Phoenix.LiveView.Socket.t(), EditorContract.target(), map()) ::
          Phoenix.LiveView.Socket.t()
  def assign_new(socket, target, attrs \\ %{}) do
    key = Ecto.UUID.generate()
    kind = kind(target)
    attrs = Map.new(fields(kind), &{&1, Map.get(attrs, &1)})

    socket
    |> assign_identity(target)
    |> assign_record(%{
      storage: %{account_id: account_id(socket), slot: target},
      draft: %{draft_id: key, revision: 0},
      mode: :new,
      target: target,
      submission_key: key,
      intent: %{attrs: attrs, uploads: []},
      base: nil,
      expected_version: nil
    })
  end

  @doc """
  Assigns a fresh edit draft from `Tips.Content.get_edit_form/3`: a new local
  draft id, the complete base and its version.
  """
  @spec assign_edit(Phoenix.LiveView.Socket.t(), Content.edit_form()) ::
          Phoenix.LiveView.Socket.t()
  def assign_edit(socket, %{kind: kind, id: id, base: base, edit_version: version}) do
    target = {:edit, kind, id}

    socket
    |> assign_identity(target)
    |> assign_record(%{
      storage: %{account_id: account_id(socket), slot: target},
      draft: %{draft_id: Ecto.UUID.generate(), revision: 0},
      mode: :edit,
      target: target,
      submission_key: nil,
      intent: base,
      base: base,
      expected_version: version
    })
  end

  defp assign_identity(socket, target) do
    assign(socket,
      identity: %{account_id: account_id(socket), target: target},
      check: nil,
      refusal: nil,
      outcome: nil
    )
  end

  defp assign_record(socket, record) do
    socket
    |> assign(:record, record)
    |> assign_attrs(record.intent.attrs)
  end

  defp assign_attrs(socket, attrs) do
    kind = kind(socket.assigns.identity.target)
    errors = errors(socket.assigns.check, kind, attrs)

    assign(socket,
      attrs: attrs,
      form: to_form(form_params(kind, attrs), as: kind, errors: errors)
    )
  end

  # Before a refused submit, none. After one, the submitted errors of fields
  # the author has not changed since, and the current errors of those they have.
  defp errors(nil, _kind, _attrs), do: []

  defp errors(%{attrs: submitted, errors: errors}, kind, attrs) do
    changed? = fn {field, _error} -> Map.get(attrs, field) != Map.get(submitted, field) end
    %{errors: current} = Content.change_content(kind, attrs)
    Enum.reject(errors, changed?) ++ Enum.filter(current, changed?)
  end

  defp account_id(socket), do: socket.assigns.current_scope.user.id

  @doc """
  Keeps the typed values from a `phx-change` event. Validates changed fields
  only after a submit failed validation.
  """
  @spec change(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def change(socket, params) do
    kind = kind(socket.assigns.identity.target)
    assign_attrs(socket, typed_attrs(kind, params[Atom.to_string(kind)], socket.assigns.attrs))
  end

  @doc """
  Handles the form's `submit`: validates every field, including untouched
  ones, then readmits the session and publishes or saves the typed values.
  Every refusal keeps the input. A failed validation pushes `editor:refused`,
  so the hook opens the evidence disclosure around an error and focuses the
  error summary.
  """
  @spec submit(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def submit(socket, params) do
    socket = socket |> change(params) |> assign(refusal: nil, outcome: nil)
    %{identity: %{target: target}, record: record, attrs: attrs} = socket.assigns

    with %{valid?: true} <- Content.change_content(kind(target), attrs),
         {:ok, socket} <- UserAuth.readmit(socket),
         {:ok, receipt} <- write(socket.assigns.current_scope, record, attrs) do
      socket |> assign(:check, nil) |> assign_attrs(attrs) |> saved(receipt)
    else
      %Ecto.Changeset{errors: errors} -> invalid(socket, errors)
      {:error, %Ecto.Changeset{errors: errors}} -> invalid(socket, errors)
      {:error, reason} -> socket |> assign(:check, nil) |> assign_attrs(attrs) |> refuse(reason)
    end
  end

  defp write(scope, %{target: :new_tip, submission_key: key} = record, attrs),
    do: Content.publish_tip(scope, key, attrs, uploads(record))

  defp write(scope, %{target: {:new_review, tip_id}, submission_key: key} = record, attrs),
    do: Content.publish_review(scope, tip_id, key, attrs, uploads(record))

  defp write(scope, %{target: {:edit, :tip, id}, expected_version: version} = record, attrs),
    do: Content.edit_tip(scope, id, version, attrs, uploads(record))

  defp write(scope, %{target: {:edit, :review, id}, expected_version: version} = record, attrs),
    do: Content.edit_review(scope, id, version, attrs, uploads(record))

  # Browser image metadata never proves saved bytes.
  defp uploads(%{intent: %{uploads: nil}}), do: nil
  defp uploads(%{intent: %{uploads: uploads}}), do: Enum.map(uploads, &attachment/1)

  defp attachment({:missing_image, slot, _image}), do: {:missing_image, slot}
  defp attachment(media), do: media

  defp invalid(socket, errors) do
    socket
    |> assign(:check, %{attrs: socket.assigns.attrs, errors: errors})
    |> assign_attrs(socket.assigns.attrs)
    |> Phoenix.LiveView.push_event("editor:refused", %{})
  end

  defp saved(socket, %{outcome: outcome}) when outcome in [:created, :existing_equivalent],
    do: assign(socket, :outcome, "Published")

  defp saved(socket, %{outcome: outcome}) when outcome in [:updated, :noop],
    do: assign(socket, :outcome, "Changes saved")

  defp saved(socket, %{outcome: outcome})
       when outcome in [:existing_different, :existing_unknown],
       do: refuse(socket, :published_earlier)

  defp refuse(socket, reason) do
    %{target: target} = socket.assigns.identity

    assign(socket, :refusal, %{
      message: refusal(reason, kind(target), verb(target)),
      sign_in: reason == :unauthenticated && sign_in_path(target)
    })
  end

  defp verb({:edit, _kind, _id}), do: "save"
  defp verb(_new), do: "publish"

  defp refusal(:unauthenticated, _kind, verb),
    do:
      "Your sign-in has expired, so nothing was #{past(verb)}. Sign in again, then #{verb} again."

  defp refusal(:forbidden, _kind, _verb),
    do:
      "This account can't publish or edit. You can still read, and delete your own tips, reviews or account."

  defp refusal(:unconfirmed, _kind, verb),
    do: "Confirm your email address before you #{verb}. Nothing was #{past(verb)}."

  defp refusal({:rate_limited, seconds}, _kind, verb),
    do:
      "Too many attempts, so nothing was #{past(verb)}. Try again in #{AuthMailAdmission.retry_in(seconds)}."

  defp refusal({:capacity, seconds}, _kind, verb),
    do:
      "Tips is busy, so nothing was #{past(verb)}. Try again in #{AuthMailAdmission.retry_in(seconds)}."

  defp refusal(:not_found, :review, "publish"), do: "This tip is no longer open for reviews."
  defp refusal(:not_found, kind, _verb), do: "This #{kind} is no longer available."
  defp refusal(:already_reviewed, _kind, _verb), do: "You have already reviewed this tip."

  defp refusal(:conflict, kind, "save"),
    do: "This #{kind} changed after you opened it, so your changes were not saved."

  defp refusal(:conflict, _kind, _verb), do: "This draft belongs to another tip."

  defp refusal(:published_earlier, kind, _verb),
    do: "This draft was published earlier, maybe with other text. This #{kind} was not changed."

  defp refusal(:outcome_unknown, _kind, verb),
    do: "We couldn't confirm whether this was #{past(verb)}."

  defp refusal({upload, _refs}, _kind, verb) when upload in [:upload_failed, :upload_pending],
    do: "An attachment isn't ready, so nothing was #{past(verb)}."

  defp past("publish"), do: "published"
  defp past("save"), do: "saved"

  defp sign_in_path(target), do: UserAuth.with_return_to(~p"/users/log-in", editor_path(target))

  defp editor_path(:new_tip), do: ~p"/editor/tips/new"
  defp editor_path({:new_review, tip_id}), do: ~p"/editor/tips/#{tip_id}/reviews/new"
  defp editor_path({:edit, :tip, id}), do: ~p"/editor/tips/#{id}/edit"
  defp editor_path({:edit, :review, id}), do: ~p"/editor/reviews/#{id}/edit"

  @doc """
  Handles `editor:restore`: applies the record the hook read when its identity,
  storage slot and target are this form's. Returns the reply to send.
  """
  @spec restore(Phoenix.LiveView.Socket.t(), map()) ::
          {map(), Phoenix.LiveView.Socket.t()}
  def restore(socket, %{"identity" => identity, "record" => json}) do
    with true <- identity == identity_json(socket.assigns.identity),
         {:ok, record} <- own_record(socket, json) do
      {reply("restored", json), assign_record(socket, record)}
    else
      _ -> {reply("rejected", json), socket}
    end
  end

  def restore(socket, params), do: {reply("rejected", params["record"]), socket}

  defp reply(status, json) when is_map(json),
    do: %{status: status, storage: json["storage"], draft: json["draft"]}

  defp reply(status, _json), do: %{status: status, storage: nil, draft: nil}

  @doc """
  Handles `editor:recover` after a reconnect. When the hidden identity is
  this freshly mounted form's, keeps the hidden record (submission key, base,
  expected version) and the recovered field values, blanks included.
  Otherwise keeps the fresh mount and ignores the recovered values.
  """
  @spec recover(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def recover(socket, %{"editor" => %{"identity" => identity, "record" => record}} = params) do
    expected = identity_json(socket.assigns.identity)
    kind = kind(socket.assigns.identity.target)

    with {:ok, ^expected} <- JSON.decode(identity),
         {:ok, json} <- JSON.decode(record),
         {:ok, record} <- own_record(socket, json) do
      socket
      |> assign(:record, record)
      |> assign_attrs(typed_attrs(kind, params[Atom.to_string(kind)], record.intent.attrs))
    else
      _ -> socket
    end
  end

  def recover(socket, _params), do: socket

  # A record for this account's slot and this form's target. A handoff record
  # (an edit target in a new slot) is #93's.
  defp own_record(socket, json) do
    %{account_id: account_id, target: target} = socket.assigns.identity

    case decode_record(json) do
      {:ok, %{storage: %{account_id: ^account_id, slot: ^target}, target: ^target} = record} ->
        {:ok, record}

      _ ->
        :error
    end
  end

  @doc "The attributes of the editor form: id, hook, recovery and its data."
  @spec form_attrs(map()) :: keyword()
  def form_attrs(%{identity: identity, record: record}) do
    [
      id: form_id(identity),
      "phx-hook": "EditorDraft",
      "phx-change": "change",
      "phx-submit": "submit",
      "phx-auto-recover": "editor:recover",
      "data-editor-identity": JSON.encode!(identity_json(identity)),
      "data-editor-record": JSON.encode!(record_json(record))
    ]
  end

  @doc "The form and hook element id: `editor-<account_id>-<tip|review>`."
  @spec form_id(EditorContract.identity()) :: String.t()
  def form_id(%{account_id: account_id, target: target}),
    do: "editor-#{account_id}-#{kind(target)}"

  @doc "Renders the hidden identity and record that LiveView recovers on reconnect."
  attr :identity, :map, required: true
  attr :record, :map, required: true

  def hidden_inputs(assigns) do
    ~H"""
    <input type="hidden" name="editor[identity]" value={JSON.encode!(identity_json(@identity))} />
    <input type="hidden" name="editor[record]" value={JSON.encode!(record_json(@record))} />
    """
  end

  @doc """
  Renders the model and environment selects. A saved choice that is no longer
  curated stays selectable.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :choices, :map, required: true, doc: "`Tips.Content.list_filter_choices/0`"
  attr :helper, :string, default: nil

  def setup_fields(assigns) do
    form = assigns.form

    assigns =
      assign(assigns,
        models:
          [{"Not specified", ""}] ++
            options(assigns.choices.models, form[:model_id].value) ++ [{"Other model…", "other"}],
        environments:
          [{"Not specified", ""}] ++
            options(assigns.choices.environments, form[:environment_id].value)
      )

    ~H"""
    <div class="grid gap-2">
      <div class="grid gap-4 sm:grid-cols-2">
        <TipsWeb.UI.model_field
          select_field={@form[:model_id]}
          text_field={@form[:model_other]}
          options={@models}
        />
        <TipsWeb.UI.field
          field={@form[:environment_id]}
          type="select"
          label="Environment used (optional)"
          options={@environments}
        />
      </div>
      <p :if={@helper} class="text-sm text-muted-foreground">{@helper}</p>
    </div>
    """
  end

  @doc "Renders the select options of curated `choices`, keeping a saved retired `value`."
  @spec options([%{id: String.t(), label: String.t()}], String.t() | nil) :: [
          {String.t(), String.t()}
        ]
  def options(choices, value) do
    options = Enum.map(choices, &{&1.label, &1.id})

    if value in [nil, "", "other"] or Enum.any?(choices, &(&1.id == value)),
      do: options,
      else: options ++ [{value, value}]
  end

  @doc """
  Renders the optional Prompt and Result disclosure, open when either holds
  text. The `EditorDraft` hook opens it when a restored draft has evidence.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :id, :string, required: true

  def evidence_fields(assigns) do
    assigns =
      assign(
        assigns,
        :open,
        Enum.any?([:prompt, :output], &(assigns.form[&1].value not in [nil, ""]))
      )

    ~H"""
    <TipsWeb.UI.disclosure id={@id} open={@open} summary="Prompt and result">
      <TipsWeb.UI.field
        field={@form[:prompt]}
        type="textarea"
        rows={4}
        label="Prompt (optional)"
        helper="Shown exactly as you type it."
      />
      <TipsWeb.UI.field
        field={@form[:output]}
        type="textarea"
        rows={4}
        label="Result text (optional)"
        helper="Shown exactly as you type it."
      />
    </TipsWeb.UI.disclosure>
    """
  end

  @doc """
  Renders the error summary of the last refused submit: one link per error,
  to its field. The hook focuses it and opens the evidence disclosure around
  a linked field.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :identity, :map, required: true

  def error_summary(assigns) do
    kind = kind(assigns.identity.target)
    order = fields(kind) |> Enum.with_index() |> Map.new()

    errors =
      assigns.form.errors
      |> Enum.sort_by(fn {field, _error} -> Map.get(order, field, map_size(order)) end)
      |> Enum.map(fn {field, error} ->
        {field_id(kind, field, assigns.identity),
         "#{label(kind, field)}: #{CoreComponents.translate_error(error)}"}
      end)

    assigns = assign(assigns, :errors, errors)

    ~H"""
    <TipsWeb.UI.error_summary id={"#{form_id(@identity)}-errors"} errors={@errors} />
    """
  end

  defp field_id(kind, field, identity) do
    if field in fields(kind), do: "#{kind}_#{field}", else: "#{form_id(identity)}-fields"
  end

  defp label(:tip, :body), do: "Tip"
  defp label(:review, :body), do: "Review"
  defp label(_kind, :title), do: "Title"
  defp label(_kind, :tag_id), do: "Technique"
  defp label(_kind, :model_id), do: "Model"
  defp label(_kind, :model_other), do: "Model name"
  defp label(_kind, :environment_id), do: "Environment"
  defp label(_kind, :prompt), do: "Prompt"
  defp label(_kind, :output), do: "Result text"
  defp label(_kind, :uploads), do: "Attachments"
  defp label(_kind, field), do: Phoenix.Naming.humanize(field)

  @doc """
  Renders the draft status line, which the hook writes, the "Reload saved
  draft" button the hook shows while autosave is paused, the refusal or
  confirmation of the last submit, and the submit button.
  """
  attr :identity, :map, required: true
  attr :submit, :string, required: true
  attr :refusal, :map, default: nil
  attr :outcome, :string, default: nil

  def editor_bar(assigns) do
    ~H"""
    <div class="grid gap-3 border-t pt-4">
      <p
        id={"#{form_id(@identity)}-status"}
        role="status"
        phx-update="ignore"
        class="min-h-5 text-sm text-muted-foreground"
      >
      </p>
      <div>
        <TipsWeb.UI.button id={"#{form_id(@identity)}-reload"} type="button" variant="outline" hidden>
          Reload saved draft
        </TipsWeb.UI.button>
      </div>
      <TipsWeb.UI.notice
        :if={@refusal}
        id={"#{form_id(@identity)}-refusal"}
        tone="error"
        role="alert"
      >
        {@refusal.message} Your text stays on this page.
        <:actions :if={@refusal.sign_in}>
          <a href={@refusal.sign_in}>Sign in</a>
        </:actions>
      </TipsWeb.UI.notice>
      <p id={"#{form_id(@identity)}-outcome"} role="status" class="text-sm font-medium">
        {@outcome}
      </p>
      <div>
        <TipsWeb.UI.button type="submit" size="lg">{@submit}</TipsWeb.UI.button>
      </div>
    </div>
    """
  end

  defp kind(:new_tip), do: :tip
  defp kind({:new_review, _tip_id}), do: :review
  defp kind({:edit, kind, _id}), do: kind

  ## Form values

  # The model select holds a curated id, "" for none, or "other" with the
  # typed name beside it; attrs hold `model_id` or `model_other`.
  defp form_params(kind, attrs) do
    params = Map.new(fields(kind), &{Atom.to_string(&1), Map.get(attrs, &1) || ""})

    case attrs do
      %{model_other: other} when is_binary(other) -> %{params | "model_id" => "other"}
      _ -> params
    end
  end

  # A field the event left out keeps its current value.
  defp typed_attrs(kind, params, current) when is_map(params) do
    attrs =
      Map.new(fields(kind), fn field ->
        case params[Atom.to_string(field)] do
          value when is_binary(value) -> {field, value}
          _ -> {field, Map.get(current, field)}
        end
      end)

    case Map.fetch(params, "model_id") do
      {:ok, "other"} -> %{attrs | model_id: nil, model_other: text_or(params["model_other"], "")}
      {:ok, _model_id} -> %{attrs | model_other: nil}
      :error -> attrs
    end
  end

  defp typed_attrs(_kind, _params, current), do: current

  defp text_or(value, _default) when is_binary(value), do: value
  defp text_or(_value, default), do: default

  ## JSON, as in assets/js/editor_contract.js

  defp identity_json(%{account_id: account_id, target: target}),
    do: %{"account_id" => account_id, "target" => target_json(target)}

  defp record_json(record) do
    %{
      "storage" => %{
        "account_id" => record.storage.account_id,
        "slot" => target_json(record.storage.slot)
      },
      "draft" => %{"draft_id" => record.draft.draft_id, "revision" => record.draft.revision},
      "mode" => Atom.to_string(record.mode),
      "target" => target_json(record.target),
      "submission_key" => record.submission_key,
      "intent" => intent_json(record.intent),
      "base" => record.base && intent_json(record.base),
      "expected_version" => record.expected_version
    }
  end

  defp target_json(:new_tip), do: %{"tag" => "new_tip"}
  defp target_json({:new_review, tip_id}), do: %{"tag" => "new_review", "tip_id" => tip_id}

  defp target_json({:edit, kind, id}),
    do: %{"tag" => "edit", "kind" => Atom.to_string(kind), "id" => id}

  defp intent_json(%{attrs: attrs, uploads: uploads}) do
    %{
      "attrs" => Map.new(attrs, fn {field, value} -> {Atom.to_string(field), value} end),
      "uploads" => uploads && Enum.map(uploads, &media_json/1)
    }
  end

  defp media_json({:retained, media_id, description}),
    do: %{"tag" => "retained", "media_id" => media_id, "description" => description}

  defp media_json({:staged_video, media_id}),
    do: %{"tag" => "staged_video", "media_id" => media_id}

  defp media_json({:missing_image, slot, image}) do
    %{
      "tag" => "missing_image",
      "slot" => slot,
      "filename" => image.filename,
      "type" => image.type,
      "size" => image.size,
      "description" => image.description
    }
  end

  # Decodes a record with the store's rules (`copyRecord` in
  # assets/js/editor_draft_store.js): exact keys, one kind throughout, and a
  # new record only in its own new slot.
  defp decode_record(
         %{
           "storage" => storage,
           "draft" => draft,
           "mode" => mode,
           "target" => target,
           "submission_key" => key,
           "intent" => intent,
           "base" => base,
           "expected_version" => version
         } = json
       )
       when map_size(json) == 8 do
    with {:ok, storage} <- decode_storage(storage),
         {:ok, target} <- decode_target(target),
         kind = kind(target),
         true <- kind(storage.slot) == kind,
         {:ok, mode} <- decode_mode(mode, target, storage.slot),
         {:ok, draft} <- decode_draft(draft),
         {:ok, key} <- optional(key, &uuid/1),
         {:ok, intent} <- decode_intent(intent, kind),
         {:ok, base} <- optional(base, &decode_intent(&1, kind)),
         {:ok, version} <- optional(version, &positive/1) do
      {:ok,
       %{
         storage: storage,
         draft: draft,
         mode: mode,
         target: target,
         submission_key: key,
         intent: intent,
         base: base,
         expected_version: version
       }}
    else
      _ -> :error
    end
  end

  defp decode_record(_json), do: :error

  defp decode_storage(%{"account_id" => account_id, "slot" => slot} = json)
       when map_size(json) == 2 do
    with {:ok, account_id} <- positive(account_id),
         {:ok, slot} <- decode_target(slot),
         do: {:ok, %{account_id: account_id, slot: slot}}
  end

  defp decode_storage(_json), do: :error

  defp decode_target(%{"tag" => "new_tip"} = json) when map_size(json) == 1, do: {:ok, :new_tip}

  defp decode_target(%{"tag" => "new_review", "tip_id" => tip_id} = json)
       when map_size(json) == 2 do
    with {:ok, tip_id} <- positive(tip_id), do: {:ok, {:new_review, tip_id}}
  end

  defp decode_target(%{"tag" => "edit", "kind" => kind, "id" => id} = json)
       when map_size(json) == 3 and is_map_key(@kinds, kind) do
    with {:ok, id} <- positive(id), do: {:ok, {:edit, @kinds[kind], id}}
  end

  defp decode_target(_json), do: :error

  # A new record lives in its own new slot. An edit record lives in its own
  # edit slot, or in a new slot after a handoff.
  defp decode_mode("new", {:edit, _kind, _id}, _slot), do: :error
  defp decode_mode("new", target, target), do: {:ok, :new}
  defp decode_mode("edit", {:edit, _kind, _id} = target, target), do: {:ok, :edit}
  defp decode_mode("edit", {:edit, _kind, _id}, :new_tip), do: {:ok, :edit}
  defp decode_mode("edit", {:edit, _kind, _id}, {:new_review, _tip_id}), do: {:ok, :edit}
  defp decode_mode(_mode, _target, _slot), do: :error

  defp decode_draft(%{"draft_id" => draft_id, "revision" => revision} = json)
       when map_size(json) == 2 and is_binary(draft_id) and draft_id != "" and
              is_integer(revision) and revision >= 0,
       do: {:ok, %{draft_id: draft_id, revision: revision}}

  defp decode_draft(_json), do: :error

  defp decode_intent(%{"attrs" => attrs, "uploads" => uploads} = json, kind)
       when map_size(json) == 2 and is_map(attrs) do
    names = Map.new(fields(kind), &{Atom.to_string(&1), &1})

    with true <-
           Enum.all?(attrs, fn {name, value} -> is_map_key(names, name) and text?(value) end),
         {:ok, uploads} <- optional(uploads, &decode_uploads/1) do
      {:ok,
       %{attrs: Map.new(attrs, fn {name, value} -> {names[name], value} end), uploads: uploads}}
    else
      _ -> :error
    end
  end

  defp decode_intent(_json, _kind), do: :error

  defp decode_uploads([]), do: {:ok, []}

  defp decode_uploads([json | rest]) do
    with {:ok, media} <- decode_media(json),
         {:ok, rest} <- decode_uploads(rest),
         do: {:ok, [media | rest]}
  end

  defp decode_uploads(_json), do: :error

  defp decode_media(%{"tag" => "retained", "media_id" => id, "description" => description} = json)
       when map_size(json) == 3 do
    with {:ok, id} <- positive(id),
         true <- text?(description),
         do: {:ok, {:retained, id, description}}
  end

  defp decode_media(%{"tag" => "staged_video", "media_id" => id} = json)
       when map_size(json) == 2 do
    with {:ok, id} <- positive(id), do: {:ok, {:staged_video, id}}
  end

  defp decode_media(
         %{
           "tag" => "missing_image",
           "slot" => slot,
           "filename" => filename,
           "type" => type,
           "size" => size,
           "description" => description
         } = json
       )
       when map_size(json) == 6 and is_binary(slot) and is_binary(filename) and is_binary(type) and
              is_integer(size) and size >= 0 do
    if text?(description),
      do:
        {:ok,
         {:missing_image, slot,
          %{filename: filename, type: type, size: size, description: description}}},
      else: :error
  end

  defp decode_media(_json), do: :error

  defp optional(nil, _decode), do: {:ok, nil}
  defp optional(value, decode), do: decode.(value)

  defp positive(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive(_value), do: :error

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> {:ok, value}
      _ -> :error
    end
  end

  defp text?(value), do: is_nil(value) or is_binary(value)
end
