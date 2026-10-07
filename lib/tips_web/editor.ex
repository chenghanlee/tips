defmodule TipsWeb.Editor do
  @moduledoc """
  The page side of the tip and review editors: the form identity, the draft
  record the page renders, and the `EditorDraft` hook's restore and recovery
  events. Types and rules are in `TipsWeb.EditorContract`; the hook is
  `assets/js/editor_draft.js`.

  The page assigns `:identity`, `:record`, `:attrs`, `:form`, `:check`,
  `:pending`, `:receipt`, `:saved`, `:refusal` and `:outcome`:

    * `:record` is the draft the page was mounted, restored or recovered with.
      It holds the submission key, the edit base and expected version, and
      after a submit the submitted values. The hook owns the browser revision
      after its first save and never writes it back to the page.
    * `:attrs` are the current field values, exactly as typed. `phx-change`
      keeps them in step with the browser. It validates only after a submit
      failed validation; `:check` holds that submit's values and errors.
    * `:pending` is set while a submission's outcome is unresolved: `:absent`
      (no publication now; Retry sends the same key), `:unchecked` (the
      lookup failed; Check again) or `:signed_out`. Its values stay fixed.
    * `:receipt` is a confirmed publication or save, with its destination
      `:to`, whose draft the hook is clearing. `:saved` is the current saved edit after an unknown outcome.
    * `:refusal` explains a refused or unconfirmed save and `:outcome` a save
      whose browser draft was kept.

  A submit validates the whole form with `Tips.Content.change_content/2`,
  readmits the session, then publishes or saves. A `:created`,
  `:existing_equivalent`, `:updated` or `:noop` receipt pushes `editor:clear`;
  once the hook has cleared the submitted draft, the page leaves for the
  published item; the hook leaves by itself if that reply is lost. If other
  browser work kept the draft, the page stays. Any other receipt keeps the
  draft. An unknown outcome runs one lookup:
  `Tips.Content.get_publication/4` for a publication, `get_edit_form/3` for an
  edit, which shows the saved version beside the proposal and keeps the
  expected version. A restored new draft is looked up before it is applied.

  The page renders `form_attrs/1` on its form and `hidden_inputs/1` inside it.
  A browser record or recovered form is untrusted input: `editor:restore` and
  `editor:recover` accept it only for the freshly mounted account and target,
  and only in the shape the hook and store use.
  """
  use Phoenix.Component
  use TipsWeb, :verified_routes

  alias Phoenix.LiveView
  alias Tips.Content
  alias TipsWeb.{AuthMailAdmission, CoreComponents, EditorContract, Reader, UserAuth}

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
      pending: nil,
      receipt: nil,
      saved: nil,
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
  Handles the editor form's events and the `EditorDraft` hook's:

    * `"change"` keeps the typed values; it validates changed fields only
      after a submit failed validation.
    * `"submit"` publishes or saves (see the module documentation).
    * `"editor:restore"` applies the record the hook read, replying
      `restored`, `published` (its publication was already confirmed, so the
      hook clears it) or `rejected`.
    * `"editor:recover"` keeps a reconnected form's record and values.
    * `"editor:reconcile"` looks up an unresolved submission again: Check
      again, or the hook after a reconnect lost a submit's reply.
    * `"editor:cleared"` is the hook's result for the confirmed draft.
  """
  @spec handle_event(String.t(), map(), LiveView.Socket.t()) ::
          {:noreply, LiveView.Socket.t()} | {:reply, map(), LiveView.Socket.t()}
  def handle_event("change", params, socket), do: {:noreply, change(socket, params)}
  def handle_event("submit", params, socket), do: {:noreply, submit(socket, params)}

  def handle_event("editor:restore", params, socket) do
    {reply, socket} = restore(socket, params)
    {:reply, reply, settle(socket)}
  end

  def handle_event("editor:recover", params, socket), do: {:noreply, recover(socket, params)}

  def handle_event("editor:reconcile", _params, socket) do
    {:noreply,
     socket
     |> assign(refusal: nil, outcome: nil)
     |> fix(socket.assigns.attrs)
     |> reconcile()
     |> settle()}
  end

  def handle_event("editor:cleared", params, socket) do
    {left?, socket} = cleared(socket, params)
    {:reply, %{left: left?}, socket}
  end

  defp change(socket, params) do
    kind = kind(socket.assigns.identity.target)
    assign_attrs(socket, typed_attrs(kind, params[Atom.to_string(kind)], socket.assigns.attrs))
  end

  # Validates every field, including untouched ones, then readmits the session
  # and publishes or saves the typed values. An unresolved submission sends
  # its fixed values again. Every refusal keeps the input. A failed validation
  # pushes `editor:refused`, so the hook opens the evidence disclosure around
  # an error and focuses the error summary.
  defp submit(socket, params) do
    socket
    |> assign(refusal: nil, outcome: nil)
    |> submitted(params)
    |> settle()
  end

  defp submitted(%{assigns: %{pending: pending, record: record}} = socket, _params)
       when pending != nil,
       do: write(socket, record.intent.attrs)

  defp submitted(socket, params) do
    socket = change(socket, params)
    attrs = socket.assigns.attrs

    case Content.change_content(kind(socket.assigns.identity.target), attrs) do
      %{valid?: true} -> socket |> assign(:check, nil) |> assign_attrs(attrs) |> write(attrs)
      %{errors: errors} -> invalid(socket, errors)
    end
  end

  defp write(socket, attrs) do
    socket = fix(socket, attrs)

    with {:ok, socket} <- UserAuth.readmit(socket),
         {:ok, receipt} <- save(socket.assigns.current_scope, socket.assigns.record) do
      acknowledge(socket, receipt)
    else
      {:error, %Ecto.Changeset{errors: errors}} ->
        socket |> assign(:pending, nil) |> invalid(errors)

      {:error, :outcome_unknown} ->
        reconcile(socket)

      {:error, reason} ->
        refuse(socket, reason)
    end
  end

  # The submitted values, kept with the key, base and version for a lookup,
  # a retry and reconnect recovery.
  defp fix(socket, attrs), do: update(socket, :record, &put_in(&1.intent.attrs, attrs))

  defp save(scope, %{target: :new_tip, submission_key: key} = record),
    do: Content.publish_tip(scope, key, record.intent.attrs, uploads(record))

  defp save(scope, %{target: {:new_review, tip_id}, submission_key: key} = record),
    do: Content.publish_review(scope, tip_id, key, record.intent.attrs, uploads(record))

  defp save(scope, %{target: {:edit, :tip, id}, expected_version: version} = record),
    do: Content.edit_tip(scope, id, version, record.intent.attrs, uploads(record))

  defp save(scope, %{target: {:edit, :review, id}, expected_version: version} = record),
    do: Content.edit_review(scope, id, version, record.intent.attrs, uploads(record))

  # Browser image metadata never proves saved bytes.
  defp uploads(%{intent: %{uploads: nil}}), do: nil
  defp uploads(%{intent: %{uploads: uploads}}), do: Enum.map(uploads, &attachment/1)

  defp attachment({:missing_image, slot, _image}), do: {:missing_image, slot}
  defp attachment(media), do: media

  defp invalid(socket, errors) do
    socket
    |> assign(:check, %{attrs: socket.assigns.attrs, errors: errors})
    |> assign_attrs(socket.assigns.attrs)
    |> LiveView.push_event("editor:refused", %{})
  end

  # Only content acknowledged as submitted clears the submitted draft.
  defp acknowledge(socket, %{outcome: outcome} = receipt)
       when outcome in [:created, :existing_equivalent, :updated, :noop] do
    %{storage: storage, draft: %{draft_id: draft_id}} = socket.assigns.record
    socket = confirm(socket, receipt)

    LiveView.push_event(socket, "editor:clear", %{
      storage: storage_json(storage),
      draft_id: draft_id,
      to: socket.assigns.receipt.to
    })
  end

  defp acknowledge(socket, receipt) do
    socket
    |> assign(:pending, nil)
    |> refuse(:published_earlier, receipt.state != :deleted && destination(socket, receipt))
  end

  # Holds the confirmed receipt and its destination until the hook's clear.
  defp confirm(socket, receipt),
    do: assign(socket, pending: nil, receipt: Map.put(receipt, :to, destination(socket, receipt)))

  # One lookup of what an unknown outcome left saved. A publication is looked
  # up by its key and the submitted values; an edit reads the saved version
  # and keeps its expected version, so saving again keeps the version guard.
  defp reconcile(socket), do: reconciled(socket, lookup(socket))

  defp lookup(%{assigns: %{record: %{mode: :new} = record}} = socket) do
    with {:ok, socket} <- UserAuth.readmit(socket) do
      Content.get_publication(
        socket.assigns.current_scope,
        publication_kind(record.target),
        record.submission_key,
        %{attrs: record.intent.attrs, uploads: uploads(record)}
      )
    end
  end

  defp lookup(%{assigns: %{record: %{target: {:edit, kind, id}}}} = socket) do
    with {:ok, socket} <- UserAuth.readmit(socket),
         do: Content.get_edit_form(socket.assigns.current_scope, kind, id)
  end

  defp publication_kind(:new_tip), do: :tip
  defp publication_kind({:new_review, tip_id}), do: {:review, tip_id}

  defp reconciled(socket, {:ok, %{base: %{attrs: saved}}}),
    do: socket |> assign(pending: nil, saved: saved) |> refuse(:unconfirmed_edit)

  defp reconciled(socket, {:ok, nil}), do: unresolved(socket, :absent)
  defp reconciled(socket, {:ok, receipt}), do: acknowledge(socket, receipt)
  defp reconciled(socket, {:error, :unauthenticated}), do: unresolved(socket, :signed_out)
  defp reconciled(socket, {:error, :outcome_unknown}), do: unresolved(socket, :unchecked)
  defp reconciled(socket, {:error, reason}), do: socket |> assign(:pending, nil) |> refuse(reason)

  defp unresolved(socket, pending),
    do: socket |> assign(:pending, pending) |> refuse({:unresolved, pending})

  # Tells the hook whether a submission is still unresolved, so it looks it
  # up again after a reconnect.
  defp settle(socket),
    do:
      LiveView.push_event(socket, "editor:settled", %{unresolved: socket.assigns.pending != nil})

  # The hook's result for the confirmed draft: cleared, not stored or not
  # clearable leave the editor; other browser work keeps it open. Returns
  # whether the page is leaving; without a receipt (a remounted page) the
  # hook leaves by itself.
  defp cleared(%{assigns: %{receipt: nil}} = socket, _params), do: {false, socket}

  defp cleared(%{assigns: %{receipt: receipt}} = socket, %{"status" => "conflict"}),
    do: {false, assign(socket, receipt: nil, outcome: kept(receipt))}

  defp cleared(%{assigns: %{receipt: receipt}} = socket, _params) do
    {true,
     socket
     |> assign(:receipt, nil)
     |> LiveView.put_flash(:info, done(receipt))
     |> LiveView.push_navigate(to: receipt.to)}
  end

  defp done(%{outcome: outcome}) when outcome in [:updated, :noop], do: "Changes saved."
  defp done(_receipt), do: "Published."

  defp kept(%{outcome: outcome}) when outcome in [:updated, :noop],
    do: "Changes saved. A different draft saved in this browser was kept; it isn't saved."

  defp kept(_receipt),
    do: "Published. A different draft saved in this browser was kept; it isn't published."

  # The item's page, from its current projection.
  defp destination(_socket, %{kind: :review, id: id}), do: ~p"/reviews/#{id}"

  defp destination(socket, %{kind: :tip, id: id}) do
    case Content.get_tip_page(UserAuth.viewer(socket), id) do
      {:ok, %{tip: tip}} -> Reader.tip_path(tip)
      {:error, _reason} -> ~p"/tips/#{id}/tip"
    end
  end

  defp refuse(socket, reason, view \\ false) do
    %{target: target} = socket.assigns.identity

    assign(socket, :refusal, %{
      message: refusal(reason, kind(target), verb(target)),
      sign_in: reason in [:unauthenticated, {:unresolved, :signed_out}] && sign_in_path(target),
      check: reason == {:unresolved, :unchecked},
      view: view
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
    do:
      "This draft was published earlier, and that #{kind} may differ from what is here. Nothing new was published."

  defp refusal({:unresolved, :absent}, kind, _verb),
    do:
      "We couldn't confirm whether your #{kind} was published, and it isn't published now. Retry to publish it."

  defp refusal({:unresolved, :unchecked}, _kind, verb),
    do: "We couldn't check whether this was #{past(verb)}. Check again before you change it."

  defp refusal({:unresolved, :signed_out}, _kind, verb),
    do:
      "We couldn't check whether this was #{past(verb)} because your sign-in has expired. Sign in again to check."

  defp refusal(:unconfirmed_edit, kind, _verb),
    do:
      "We couldn't confirm whether your changes were saved. The saved #{kind} is below. If you save again and your changes were already saved, you'll be told the #{kind} changed."

  defp refusal({:too_long, 1}, kind, _verb),
    do: "This #{kind} is too long to publish. Shorten it by about 1 word."

  defp refusal({:too_long, words}, kind, _verb),
    do: "This #{kind} is too long to publish. Shorten it by about #{words} words."

  defp refusal({upload, _refs}, _kind, verb) when upload in [:upload_failed, :upload_pending],
    do: "An attachment isn't ready, so nothing was #{past(verb)}."

  defp past("publish"), do: "published"
  defp past("save"), do: "saved"

  defp sign_in_path(target), do: UserAuth.with_return_to(~p"/users/log-in", editor_path(target))

  defp editor_path(:new_tip), do: ~p"/editor/tips/new"
  defp editor_path({:new_review, tip_id}), do: ~p"/editor/tips/#{tip_id}/reviews/new"
  defp editor_path({:edit, :tip, id}), do: ~p"/editor/tips/#{id}/edit"
  defp editor_path({:edit, :review, id}), do: ~p"/editor/reviews/#{id}/edit"

  # Applies the record the hook read when its identity, storage slot and
  # target are this form's. Returns the reply to send.
  defp restore(socket, %{"identity" => identity, "record" => json}) do
    with true <- identity == identity_json(socket.assigns.identity),
         {:ok, record} <- own_record(socket, json) do
      reopen(socket, record, json)
    else
      _ -> {reply("rejected", json), socket}
    end
  end

  defp restore(socket, params), do: {reply("rejected", params["record"]), socket}

  # A new draft may have been published from another page: its key is looked
  # up first. An equivalent publication restores the draft while the hook
  # clears it, so recovery keeps its key until the clear settles; a missing
  # one restores the ordinary draft.
  defp reopen(socket, %{mode: :new} = record, json) do
    restored = assign_record(socket, record)

    case lookup(restored) do
      {:ok, nil} ->
        {reply("restored", json), restored}

      {:ok, %{outcome: :existing_equivalent} = receipt} ->
        restored = confirm(restored, receipt)
        {Map.put(reply("published", json), :to, restored.assigns.receipt.to), restored}

      result ->
        {reply("restored", json), reconciled(restored, result)}
    end
  end

  defp reopen(socket, record, json), do: {reply("restored", json), assign_record(socket, record)}

  defp reply(status, json) when is_map(json),
    do: %{status: status, storage: json["storage"], draft: json["draft"]}

  defp reply(status, _json), do: %{status: status, storage: nil, draft: nil}

  # After a reconnect, when the hidden identity is this freshly mounted
  # form's, keeps the hidden record (submission key, base, expected version)
  # and the recovered field values, blanks included. Otherwise keeps the
  # fresh mount and ignores the recovered values. Fixed fields are disabled
  # and send no values, so the record's submitted values stay.
  defp recover(socket, %{"editor" => %{"identity" => identity, "record" => record}} = params) do
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

  defp recover(socket, _params), do: socket

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
        helper="Up to 10,000 characters. Shown exactly as you type it."
      />
      <TipsWeb.UI.field
        field={@form[:output]}
        type="textarea"
        rows={4}
        label="Result text (optional)"
        helper="Up to 10,000 characters. Shown exactly as you type it."
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
  Renders the saved version of an edit whose outcome was unknown, beside the
  author's proposal.
  """
  attr :identity, :map, required: true
  attr :saved, :map, default: nil, doc: "the saved `t:Tips.Content.attrs/0`"
  attr :choices, :map, required: true, doc: "`Tips.Content.list_filter_choices/0`"

  def saved_version(assigns) do
    kind = kind(assigns.identity.target)

    rows =
      for field <- fields(kind) -- [:model_other],
          value = shown(field, assigns.saved || %{}, assigns.choices),
          value != nil,
          do: {label(kind, field), value}

    assigns = assign(assigns, :rows, rows)

    ~H"""
    <section
      :if={@saved}
      id={"#{form_id(@identity)}-saved"}
      aria-labelledby={"#{form_id(@identity)}-saved-title"}
      class="grid gap-3 rounded-md border p-4"
    >
      <h2 id={"#{form_id(@identity)}-saved-title"} class="font-semibold">Saved version</h2>
      <dl class="grid gap-2">
        <div :for={{label, value} <- @rows}>
          <dt class="text-sm text-muted-foreground">{label}</dt>
          <dd class="whitespace-pre-wrap">{value}</dd>
        </div>
      </dl>
    </section>
    """
  end

  defp shown(:model_id, %{model_other: other}, _choices) when other not in [nil, ""], do: other
  defp shown(field, saved, choices), do: choice(field, Map.get(saved, field), choices)

  defp choice(_field, value, _choices) when value in [nil, ""], do: nil

  defp choice(field, value, choices) when field in [:tag_id, :model_id, :environment_id] do
    list =
      Map.fetch!(
        choices,
        %{tag_id: :tags, model_id: :models, environment_id: :environments}[field]
      )

    Enum.find_value(list, value, &(&1.id == value && &1.label))
  end

  defp choice(_field, value, _choices), do: value

  @doc """
  Renders the draft status line, which the hook writes, the "Reload saved
  draft" button the hook shows while autosave is paused, the refusal or
  confirmation of the last submit, and the submit button. While a
  submission is unresolved, the button retries it or is disabled until it
  is checked again.
  """
  attr :identity, :map, required: true
  attr :submit, :string, required: true
  attr :refusal, :map, default: nil
  attr :outcome, :string, default: nil
  attr :pending, :atom, default: nil

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
        <:actions :if={@refusal.sign_in || @refusal.check || @refusal.view}>
          <a :if={@refusal.sign_in} href={@refusal.sign_in}>Sign in</a>
          <TipsWeb.UI.button
            :if={@refusal.check}
            type="button"
            variant="outline"
            phx-click="editor:reconcile"
          >
            Check again
          </TipsWeb.UI.button>
          <a :if={@refusal.view} href={@refusal.view}>View it</a>
        </:actions>
      </TipsWeb.UI.notice>
      <p id={"#{form_id(@identity)}-outcome"} role="status" class="text-sm font-medium">
        {@outcome}
      </p>
      <div>
        <TipsWeb.UI.button type="submit" size="lg" disabled={@pending in [:unchecked, :signed_out]}>
          {if @pending == :absent, do: "Retry", else: @submit}
        </TipsWeb.UI.button>
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

  defp storage_json(%{account_id: account_id, slot: slot}),
    do: %{"account_id" => account_id, "slot" => target_json(slot)}

  defp record_json(record) do
    %{
      "storage" => storage_json(record.storage),
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
