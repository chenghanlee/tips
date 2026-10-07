defmodule Tips.Content.Read do
  @moduledoc """
  Loads the tip and selected-review destinations, then projects them.

  Each read admits its viewer once at entry, loads current rows, hydrates only
  what a readable row displays and returns `Tips.Content.Projection` output.
  See "Reading" in `Tips.Content`.
  """

  import Ecto.Query

  alias Tips.Accounts
  alias Tips.Accounts.{Scope, User}
  alias Tips.Content.Media.Asset
  alias Tips.Content.{Projection, Review, Tip, Visibility, Vocabulary, Vote}
  alias Tips.Repo

  # Positive bigint ids; anything else cannot name a row.
  @row_ids 1..9_223_372_036_854_775_807

  @doc false
  def get_tip_page(viewer, tip_id) do
    with {:ok, scope} <- admit(viewer),
         {:ok, id} <- row_id(tip_id),
         %Tip{} = tip <- Repo.get(Tip, id) do
      own_review = own_review(scope, tip)

      {:ok,
       %{
         tip: Projection.tip(scope, tip, tip_hydration(scope, tip, own_review)),
         own_review: Projection.own_review(scope, own_review)
       }}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def get_review_page(viewer, review_id) do
    with {:ok, scope} <- admit(viewer),
         {:ok, id} <- row_id(review_id),
         %Review{} = review <- Repo.get(Review, id) do
      # The parent is immutable and the foreign key guarantees it exists.
      tip = Repo.get!(Tip, review.tip_id)

      hydration = %{
        tip: tip_hydration(scope, tip, own_review(scope, tip)),
        review: review_hydration(scope, review)
      }

      {:ok, Projection.selected_review(scope, tip, review, hydration)}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  # Projects one loaded row for a moderation case, with the same hydration and
  # deletion-first masking as the pages. A review sees its parent as a link.
  def project(scope, %Tip{} = tip),
    do: Projection.tip(scope, tip, tip_hydration(scope, tip, own_review(scope, tip)))

  def project(scope, %Review{} = review) do
    hydration = review_hydration(scope, review)
    Projection.review(scope, review, Map.put(hydration, :parent, Repo.get!(Tip, review.tip_id)))
  end

  # Anonymous viewers take the public path without a token query; anything else
  # must be a session reference that readmits now.
  defp admit(nil), do: {:ok, nil}
  defp admit(session_ref), do: Accounts.readmit_scope(session_ref)

  defp row_id(value) do
    case Ecto.Type.cast(:id, value) do
      {:ok, id} when id in @row_ids -> {:ok, id}
      _invalid -> {:error, :not_found}
    end
  end

  # Hydration is loaded only for a row the viewer may read; projections skip it
  # for placeholders and removal notices.
  defp tip_hydration(scope, tip, own_review) do
    if readable?(scope, tip) do
      %{
        author: Repo.get!(User, tip.user_id),
        labels: Vocabulary.label_maps(),
        viewer_vote: viewer_vote(scope, :tip_id, tip.id),
        media: media(:tip_id, tip.id),
        own_review: own_review,
        latest_review_at: latest_review_at(tip),
        has_earlier_reviews: has_earlier_reviews?(scope, tip)
      }
    else
      %{}
    end
  end

  defp review_hydration(scope, review) do
    if readable?(scope, review) do
      %{
        author: Repo.get!(User, review.user_id),
        labels: Vocabulary.label_maps(),
        viewer_vote: viewer_vote(scope, :review_id, review.id),
        media: media(:review_id, review.id)
      }
    else
      %{}
    end
  end

  defp readable?(scope, content), do: Visibility.decision(scope, content) == :visible

  # Identity, ownership and visibility fields only; never another review body.
  defp own_review(nil, _tip), do: nil

  defp own_review(%Scope{user: %User{id: user_id}}, %Tip{id: tip_id}) do
    Repo.one(
      from r in Review,
        where: r.tip_id == ^tip_id and r.user_id == ^user_id and is_nil(r.deleted_at),
        select: struct(r, [:id, :tip_id, :user_id, :deleted_at, :dead_at])
    )
  end

  defp viewer_vote(nil, _target, _id), do: nil

  defp viewer_vote(%Scope{user: %User{id: user_id}}, target, id) do
    Repo.one(
      from v in Vote,
        where: v.user_id == ^user_id and field(v, ^target) == ^id,
        select: v.value
    )
  end

  defp media(parent, id) do
    Repo.all(
      from a in Asset,
        where: field(a, ^parent) == ^id and is_nil(a.cleanup_at) and not is_nil(a.position)
    )
  end

  defp latest_review_at(%Tip{id: tip_id}) do
    Repo.one(from r in live_reviews(tip_id), select: max(r.created_at))
  end

  defp has_earlier_reviews?(_scope, %Tip{edited_at: nil}), do: false

  # Live reviews are readable by everyone. Only a signed-in viewer can read a
  # hidden one, decided per row by `Visibility`.
  defp has_earlier_reviews?(scope, %Tip{id: tip_id, edited_at: edited_at}) do
    Repo.exists?(from r in live_reviews(tip_id), where: r.created_at < ^edited_at) or
      hidden_review_readable?(scope, tip_id, edited_at)
  end

  defp hidden_review_readable?(nil, _tip_id, _edited_at), do: false

  defp hidden_review_readable?(scope, tip_id, edited_at) do
    from(r in Review,
      where:
        r.tip_id == ^tip_id and r.created_at < ^edited_at and is_nil(r.deleted_at) and
          not is_nil(r.dead_at),
      select: struct(r, [:id, :user_id, :deleted_at, :dead_at])
    )
    |> Repo.all()
    |> Enum.any?(&readable?(scope, &1))
  end

  defp live_reviews(tip_id) do
    from r in Review, where: r.tip_id == ^tip_id and is_nil(r.deleted_at) and is_nil(r.dead_at)
  end
end
