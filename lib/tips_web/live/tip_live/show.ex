defmodule TipsWeb.TipLive.Show do
  @moduledoc """
  The tip page, `/tips/:id/:slug`: the projected tip, its header and text.

  Loads by id; any other slug redirects to the projected one, including the
  neutral placeholder slugs. The review list is #98.
  """
  use TipsWeb, :live_view

  alias Tips.Content
  alias TipsWeb.{Reader, UserAuth}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} return_to={Reader.tip_path(@tip)}>
      <Reader.removed_notice
        :if={@tip.state == :visible and @tip.removed}
        id="tip-removed-notice"
        editable={@tip.capabilities.edit}
      />
      <Reader.tip_header tip={@tip} own_review={@own_review} signed_in={!!@current_scope} />
      <%= if @tip.state == :visible do %>
        <Reader.markdown id="tip-body" text={@tip.body} />
        <Reader.verbatim_block :if={@tip.prompt} id="tip-prompt" label="Prompt" text={@tip.prompt} />
        <Reader.verbatim_block :if={@tip.output} id="tip-result" label="Result" text={@tip.output} />
      <% end %>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id, "slug" => slug}, _session, socket) do
    case Content.get_tip_page(UserAuth.viewer(socket), id) do
      {:ok, %{tip: %{slug: ^slug} = tip, own_review: own_review}} ->
        {:ok, assign(socket, tip: tip, own_review: own_review, page_title: tip.title)}

      {:ok, %{tip: tip}} ->
        {:ok, push_navigate(socket, to: Reader.tip_path(tip), replace: true)}

      {:error, :not_found} ->
        raise TipsWeb.NotFoundError

      {:error, :unauthenticated} ->
        {:ok, UserAuth.require_login(socket)}
    end
  end
end
