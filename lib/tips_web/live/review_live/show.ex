defmodule TipsWeb.ReviewLive.Show do
  @moduledoc """
  The single-review view, `/reviews/:id`: the review's current tip context and
  only that review, with its disclosure open, or the supplied reason it is
  unavailable. No list sort, filters or pages; "Show all reviews" opens the
  tip permalink.
  """
  use TipsWeb, :live_view

  alias Tips.Content
  alias TipsWeb.{Reader, UserAuth}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      unread={@unread_notifications}
      return_to={@path}
    >
      <Reader.tip_context tip={@tip} />
      <%= case @review do %>
        <% {:visible, review} -> %>
          <Reader.review_card review={review} open />
          <p><.link navigate={Reader.tip_path(@tip)}>Show all reviews</.link></p>
        <% reason -> %>
          <UI.notice id="review-unavailable">
            {unavailable(reason)}
            <:actions>
              <.link navigate={Reader.tip_path(@tip)}>Show all reviews</.link>
            </:actions>
          </UI.notice>
      <% end %>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Content.get_review_page(UserAuth.viewer(socket), id) do
      {:ok, %{tip: tip, review: review}} ->
        {:ok,
         assign(socket,
           tip: tip,
           review: review,
           path: ~p"/reviews/#{id}",
           page_title: "Review of #{tip.title}"
         )}

      {:error, :not_found} ->
        raise TipsWeb.NotFoundError

      {:error, :unauthenticated} ->
        {:ok, UserAuth.require_login(socket)}
    end
  end

  defp unavailable(:deleted), do: "Review deleted by author"
  defp unavailable(:removed), do: "Review removed by moderators"
  defp unavailable(:unavailable), do: "Review unavailable"
end
