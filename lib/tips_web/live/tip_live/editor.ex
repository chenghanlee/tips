defmodule TipsWeb.TipLive.Editor do
  @moduledoc """
  The tip editor: `/editor/tips/new` and `/editor/tips/:id/edit`.

  Mounts the draft form, its `EditorDraft` hook, browser draft restore,
  reconnect recovery, submit-time validation, publishing or saving, outcome
  reconciliation and draft clearing (`TipsWeb.Editor`).
  """
  use TipsWeb, :live_view

  alias Tips.Content
  alias TipsWeb.{Editor, UserAuth}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} editor>
      <h1 class="text-2xl font-semibold">{@page_title}</h1>
      <TipsWeb.UI.notice :if={@load_failed} tone="error" role="alert">
        This tip couldn't be loaded. Reload the page to try again.
      </TipsWeb.UI.notice>
      <.form :if={!@load_failed} for={@form} class="grid gap-6" {Editor.form_attrs(assigns)}>
        <Editor.hidden_inputs identity={@identity} record={@record} />
        <Editor.error_summary form={@form} identity={@identity} />
        <fieldset disabled={@pending != nil} class="contents">
          <fieldset id={"#{Editor.form_id(@identity)}-fields"} class="grid gap-6">
            <TipsWeb.UI.field field={@form[:title]} label="Title" />
            <TipsWeb.UI.field
              field={@form[:body]}
              type="textarea"
              rows={8}
              label="Tip"
              helper="Explain when to use this, the steps, and what happened when you tried it. Markdown is supported."
            />
            <TipsWeb.UI.field
              field={@form[:tag_id]}
              type="select"
              label="Technique"
              options={[
                {"Choose a technique", ""} | Editor.options(@choices.tags, @form[:tag_id].value)
              ]}
            />
            <Editor.setup_fields form={@form} choices={@choices} />
            <Editor.evidence_fields form={@form} id={"#{Editor.form_id(@identity)}-evidence"} />
          </fieldset>
        </fieldset>
        <Editor.saved_version identity={@identity} saved={@saved} choices={@choices} />
        <Editor.editor_bar
          identity={@identity}
          submit={if @live_action == :new, do: "Publish", else: "Save changes"}
          refusal={@refusal}
          outcome={@outcome}
          pending={@pending}
        />
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, choices: Content.list_filter_choices(), load_failed: false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, socket.assigns.live_action, params)}
  end

  defp load(socket, :new, _params) do
    socket
    |> assign(page_title: "New tip", load_failed: false)
    |> Editor.assign_new(:new_tip)
  end

  defp load(socket, :edit, %{"id" => id}) do
    with {:ok, socket} <- UserAuth.readmit(socket),
         {:ok, form} <- Content.get_edit_form(socket.assigns.current_scope, :tip, id) do
      socket
      |> assign(page_title: "Edit tip", load_failed: false)
      |> Editor.assign_edit(form)
    else
      {:error, :unauthenticated} -> UserAuth.require_login(socket)
      {:error, :not_found} -> raise TipsWeb.NotFoundError
      {:error, :outcome_unknown} -> assign(socket, page_title: "Edit tip", load_failed: true)
    end
  end

  @impl true
  def handle_event(event, params, socket), do: Editor.handle_event(event, params, socket)
end
