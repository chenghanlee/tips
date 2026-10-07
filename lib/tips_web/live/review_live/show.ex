defmodule TipsWeb.ReviewLive.Show do
  @moduledoc """
  The single-review view, `/reviews/:id`: the review's current tip context and
  only that review, with its disclosure open, or the supplied reason it is
  unavailable. No list sort, filters or pages; "Show all reviews" opens the
  tip permalink on page 1 with no filters, keeping only a `sort=new`
  parameter that the tip page's review links add. The review's own Delete
  is handled by `TipsWeb.ReviewActions`, its vote control by
  `TipsWeb.VoteActions`.
  """
  use TipsWeb, :live_view

  alias Tips.Content
  alias TipsWeb.{Reader, ReviewActions, UserAuth, VoteActions}

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
          <Reader.review_card
            review={review}
            open
            confirm_delete={@confirm_delete == review.id}
            vote={VoteActions.control(:review, review, @current_scope, @vote_status)}
          />
          <p><.link navigate={Reader.tip_path(@tip, @sort_params)}>Show all reviews</.link></p>
        <% reason -> %>
          <UI.notice id="review-unavailable">
            {unavailable(reason)}
            <:actions>
              <.link navigate={Reader.tip_path(@tip, @sort_params)}>Show all reviews</.link>
            </:actions>
          </UI.notice>
      <% end %>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    case Content.get_review_page(UserAuth.viewer(socket), id) do
      {:ok, %{tip: tip, review: review}} ->
        sort_params = [sort: if(params["sort"] == "new", do: "new")]

        {:ok,
         socket
         |> assign(
           tip: tip,
           review: review,
           sort_params: sort_params,
           path: Reader.review_path(id, sort_params),
           page_title: "Review of #{tip.title}"
         )
         |> ReviewActions.attach()
         |> VoteActions.attach(&update_vote/3)}

      {:error, :not_found} ->
        raise TipsWeb.NotFoundError

      {:error, :unauthenticated} ->
        {:ok, UserAuth.require_login(socket)}
    end
  end

  defp update_vote(
         %{assigns: %{review: {:visible, %{id: id} = review}}} = socket,
         {:review, id},
         fun
       ),
       do: assign(socket, :review, {:visible, fun.(review)})

  defp update_vote(socket, _target, _fun), do: socket

  defp unavailable(:deleted), do: "Review deleted by author"
  defp unavailable(:removed), do: "Review removed by moderators"
  defp unavailable(:unavailable), do: "Review unavailable"
end
