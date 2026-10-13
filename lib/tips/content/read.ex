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
  @page_size 30
  @filters [:model_id, :environment_id]
  @options [:sort, :offset | @filters]

  @type reviews :: %{entries: [Projection.visible_review()], has_more: boolean()}

  @doc false
  def get_tip_page(viewer, tip_id, opts \\ []) do
    with {:ok, options} <- options(opts),
         {:ok, scope} <- admit(viewer),
         {:ok, id} <- row_id(tip_id),
         %Tip{} = tip <- Repo.get(Tip, id) do
      own_review = own_review(scope, tip)

      {:ok,
       %{
         tip: Projection.tip(scope, tip, tip_hydration(scope, tip, own_review)),
         own_review: Projection.own_review(scope, own_review),
         reviews: reviews(scope, tip, options)
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
  # The first matching row of the media-access table in `Tips.Content`. Only a
  # privileged branch (hidden or deleted parent, staged row) readmits the viewer.
  def get_media_access(viewer, media_id) do
    with {:ok, id} <- row_id(media_id),
         {%Asset{} = asset, tip, review} <- playable_video(id),
         :ok <- media_access(viewer, asset, review || tip) do
      {:ok, %{stream_uid: asset.stream_uid}}
    else
      _denied -> {:error, :not_found}
    end
  end

  # A ready, uncleaned video with its tip or review, if attached. Attached rows
  # have no deadline; a staged row's deadline must not have passed.
  defp playable_video(id) do
    Repo.one(
      from a in Asset,
        left_join: t in assoc(a, :tip),
        left_join: r in assoc(a, :review),
        where:
          a.id == ^id and a.kind == :video and a.state == :ready and is_nil(a.cleanup_at) and
            (is_nil(a.expires_at) or a.expires_at > fragment("clock_timestamp()")),
        select: {a, t, r}
    )
  end

  # Staged: only its author.
  defp media_access(viewer, %Asset{user_id: user_id}, nil) do
    with {:ok, %Scope{user: %User{id: ^user_id}}} <- admit(viewer), do: :ok
  end

  # Attached: anyone while the parent is live; otherwise the parent's decision
  # for the readmitted viewer.
  defp media_access(viewer, _asset, parent) do
    if readable?(nil, parent) do
      :ok
    else
      with {:ok, scope} <- admit(viewer), true <- readable?(scope, parent), do: :ok
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

  # One ranked page of live reviews, with the lookahead row. Every row is live,
  # so each is readable and hydrated; the parent may be a placeholder.
  defp reviews(scope, tip, %{sort: sort, offset: offset, filters: filters}) do
    {rows, lookahead} =
      from([r, _u] in ranked_reviews(tip.id, filters),
        order_by: ^review_order(sort),
        limit: @page_size + 1,
        offset: ^offset
      )
      |> Repo.all()
      |> Enum.split(@page_size)

    ids = Enum.map(rows, fn {review, _author} -> review.id end)
    votes = viewer_votes(scope, ids)
    media = Enum.group_by(media(:review_id, ids), & &1.review_id)
    labels = Vocabulary.label_maps()

    entries =
      Enum.map(rows, fn {review, author} ->
        Projection.review(scope, review, %{
          parent: tip,
          author: author,
          labels: labels,
          viewer_vote: votes[review.id],
          media: Map.get(media, review.id, [])
        })
      end)

    %{entries: entries, has_more: lookahead != []}
  end

  # Same predicate as the `reviews_best` and `reviews_new` partial indexes.
  defp ranked_reviews(tip_id, filters) do
    from r in live_reviews(tip_id),
      join: u in User,
      on: u.id == r.user_id,
      where: ^filters,
      select: {r, struct(u, [:id, :handle, :deleted_at])}
  end

  defp review_order(:best), do: [desc: :best_score, desc: :id]
  defp review_order(:new), do: [desc: :created_at, desc: :id]

  defp options(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         [] <- keys -- @options,
         true <- keys == Enum.uniq(keys),
         sort when sort in [:best, :new] <- Keyword.get(opts, :sort, :best),
         offset when is_integer(offset) and offset >= 0 and rem(offset, @page_size) == 0 <-
           Keyword.get(opts, :offset, 0),
         filters = Keyword.take(opts, @filters),
         true <- Enum.all?(filters, fn {_key, id} -> is_binary(id) end) do
      {:ok, %{sort: sort, offset: offset, filters: filters}}
    else
      _invalid -> {:error, :invalid_option}
    end
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

  defp viewer_votes(nil, _review_ids), do: %{}

  defp viewer_votes(%Scope{user: %User{id: user_id}}, review_ids) do
    from(v in Vote,
      where: v.user_id == ^user_id and v.review_id in ^review_ids,
      select: {v.review_id, v.value}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp media(parent, ids) when is_list(ids) do
    Repo.all(
      from a in Asset,
        where: field(a, ^parent) in ^ids and is_nil(a.cleanup_at) and not is_nil(a.position)
    )
  end

  defp media(parent, id), do: media(parent, [id])

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
