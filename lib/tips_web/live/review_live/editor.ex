defmodule TipsWeb.ReviewLive.Editor do
  @moduledoc """
  The review editor: `/editor/tips/:tip_id/reviews/new` and
  `/editor/reviews/:id/edit`.

  Mounts the draft form, its `EditorDraft` hook, browser draft restore,
  reconnect recovery, submit-time validation, publishing or saving, outcome
  reconciliation and draft clearing (`TipsWeb.Editor`). A fresh review form
  starts with the tip's model and environment; a restored, recovered or saved
  review keeps its own values, blanks included.
  """
  use TipsWeb, :live_view

  alias Tips.Content
  alias TipsWeb.{Editor, Reader, UserAuth}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} unread={@unread_notifications} editor>
      <h1 class="text-2xl font-semibold">{@page_title}</h1>
      <p :if={@tip}>Your review of <a href={Reader.tip_path(@tip)}>{@tip.title}</a></p>
      <TipsWeb.UI.notice :if={@load_failed} tone="error" role="alert">
        This review couldn't be loaded. Reload the page to try again.
      </TipsWeb.UI.notice>
      <.form :if={!@load_failed} for={@form} class="grid gap-6" {Editor.form_attrs(assigns)}>
        <Editor.hidden_inputs identity={@identity} record={@record} />
        <Editor.error_summary form={@form} identity={@identity} />
        <fieldset disabled={@pending != nil} class="contents">
          <fieldset id={"#{Editor.form_id(@identity)}-fields"} class="grid gap-6">
            <TipsWeb.UI.field
              field={@form[:body]}
              type="textarea"
              rows={8}
              label="Review"
              helper="Describe what happened when you tried this tip yourself: what you did, what worked and what didn't. Markdown is supported. Up to 10,000 characters."
            />
            <Editor.evidence_fields form={@form} id={"#{Editor.form_id(@identity)}-evidence"} />
            <Editor.setup_fields
              form={@form}
              choices={@choices}
              helper="Check that they match your own attempt."
            />
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
    {:ok, assign(socket, choices: Content.list_filter_choices(), tip: nil, load_failed: false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, socket.assigns.live_action, params)}
  end

  defp load(socket, :new, %{"tip_id" => tip_id}) do
    case Content.get_tip_page(UserAuth.viewer(socket), tip_id) do
      {:ok, %{tip: %{state: :visible} = tip}} ->
        socket
        |> assign(page_title: "Write a review", tip: tip, load_failed: false)
        |> Editor.assign_new({:new_review, tip.id}, setup(tip))

      {:ok, _placeholder} ->
        raise TipsWeb.NotFoundError

      {:error, :not_found} ->
        raise TipsWeb.NotFoundError

      {:error, :unauthenticated} ->
        UserAuth.require_login(socket)
    end
  end

  defp load(socket, :edit, %{"id" => id}) do
    with {:ok, socket} <- UserAuth.readmit(socket),
         {:ok, form} <- Content.get_edit_form(socket.assigns.current_scope, :review, id) do
      socket
      |> assign(page_title: "Edit review", tip: nil, load_failed: false)
      |> Editor.assign_edit(form)
    else
      {:error, :unauthenticated} -> UserAuth.require_login(socket)
      {:error, :not_found} -> raise TipsWeb.NotFoundError
      {:error, :outcome_unknown} -> assign(socket, page_title: "Edit review", load_failed: true)
    end
  end

  # The tip's reported setup, including a free-text model. Applied once, to a
  # fresh form.
  defp setup(tip) do
    Map.merge(
      %{model_id: nil, model_other: nil, environment_id: environment_id(tip.environment)},
      model_setup(tip.model)
    )
  end

  defp model_setup(nil), do: %{}
  defp model_setup(%{id: nil, label: other}), do: %{model_other: other}
  defp model_setup(%{id: id}), do: %{model_id: id}

  defp environment_id(nil), do: nil
  defp environment_id(%{id: id}), do: id

  @impl true
  def handle_event(event, params, socket), do: Editor.handle_event(event, params, socket)
end
