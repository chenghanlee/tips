defmodule Tips.Content.Notification do
  @moduledoc """
  A recipient's folded notification about one contribution, and the inbox that
  reads and marks them. See "Inbox" in `Tips.Content`.
  """
  use Ecto.Schema

  import Ecto.Query

  alias Tips.Accounts
  alias Tips.Accounts.{Scope, User}
  alias Tips.Content.{Projection, Review, Tip, Visibility}
  alias Tips.Repo

  @page_size 20
  @badge_cap 100

  @type type :: :tip_upvoted | :review_upvoted | :tip_reviewed

  schema "notifications" do
    field :user_id, :id
    field :actor_id, :id
    belongs_to :tip, Tips.Content.Tip
    belongs_to :review, Tips.Content.Review

    field :type, Ecto.Enum, values: [:tip_upvoted, :review_upvoted, :tip_reviewed]
    field :count, :integer, default: 1
    field :read_at, :utc_datetime

    timestamps(inserted_at: false, updated_at: :updated_at, type: :utc_datetime)
  end

  @doc """
  Folds one event into the recipient's unread notification for `type` and
  `target`: inserts it with the current time, or adds 1 to the unread row's
  count and moves its time and actor to this event. A read row stays as it is.

  Writes nothing when the actor is the recipient. The caller decides that the
  event is eligible and runs this in the transaction that commits the event.
  """
  @spec fold(
          type(),
          recipient_id :: pos_integer(),
          actor_id :: pos_integer(),
          Visibility.content()
        ) ::
          :ok
  def fold(_type, user_id, user_id, _target), do: :ok

  def fold(type, recipient_id, actor_id, target) do
    unless Repo.in_transaction?() do
      raise ArgumentError, "notification folds require a caller transaction"
    end

    {tip_id, review_id} =
      case target do
        %Tip{id: id} -> {id, nil}
        %Review{id: id} -> {nil, id}
      end

    Repo.query!(
      """
      INSERT INTO notifications (user_id, type, actor_id, tip_id, review_id, updated_at)
      VALUES ($1, $2, $3, $4, $5, now())
      ON CONFLICT (user_id, type, tip_id, review_id) WHERE read_at IS NULL
      DO UPDATE SET count = notifications.count + 1, actor_id = EXCLUDED.actor_id, updated_at = now()
      """,
      [recipient_id, Atom.to_string(type), actor_id, tip_id, review_id]
    )

    :ok
  end

  @typedoc "One inbox page, newest first."
  @type page :: %{entries: [Projection.inbox_entry()], has_more: boolean()}

  @doc "See `Tips.Content.get_inbox/2`."
  @spec inbox(term(), keyword()) ::
          {:ok, page()} | {:error, :unauthenticated | :invalid_option}
  def inbox(session_ref, opts) do
    with {:ok, scope} <- Accounts.readmit_scope(session_ref),
         {:ok, offset, mark_read?} <- inbox_options(opts) do
      {:ok, {page, captured}} = snapshot(scope, offset, mark_read?)
      mark_read(scope, captured)
      {:ok, page}
    end
  end

  @doc "See `Tips.Content.count_unread_notifications/1`."
  @spec count_unread(Scope.t()) :: 0..100
  def count_unread(%Scope{user: %User{id: user_id}}) do
    capped = from(n in unread(user_id), select: n.id, limit: @badge_cap)
    Repo.one(from(n in subquery(capped), select: count()))
  end

  defp inbox_options(opts) do
    with true <- Keyword.keyword?(opts),
         [] <- Keyword.keys(opts) -- [:offset, :mark_read],
         offset when is_integer(offset) and offset >= 0 and rem(offset, @page_size) == 0 <-
           Keyword.get(opts, :offset, 0),
         mark_read? when is_boolean(mark_read?) <- Keyword.get(opts, :mark_read, false) do
      {:ok, offset, mark_read?}
    else
      _invalid -> {:error, :invalid_option}
    end
  end

  # The page, its targets and the unread pairs to mark come from one snapshot,
  # closed before marking. Folds and new rows committed later are not captured.
  # Not READ ONLY: in the test sandbox that would last the whole test transaction.
  defp snapshot(%Scope{user: %User{id: user_id}} = scope, offset, mark_read?) do
    Repo.transact(fn ->
      Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")

      {rows, lookahead} =
        from(n in __MODULE__,
          where: n.user_id == ^user_id,
          order_by: [desc: n.updated_at, desc: n.id],
          limit: @page_size + 1,
          offset: ^offset
        )
        |> Repo.all()
        |> Enum.split(@page_size)

      page = %{entries: entries(scope, rows), has_more: lookahead != []}
      captured = if mark_read?, do: Repo.all(from(n in unread(user_id), select: {n.id, n.count}))
      {:ok, {page, captured}}
    end)
  end

  # Marks only captured rows still unread at their captured count, so a later
  # fold stays unread. `read_at` is the only change: time, count and order stay.
  defp mark_read(_scope, nil), do: :ok
  defp mark_read(_scope, []), do: :ok

  defp mark_read(%Scope{user: %User{id: user_id}}, captured) do
    {ids, counts} = Enum.unzip(captured)

    Repo.update_all(
      from(n in unread(user_id),
        join:
          c in fragment(
            "SELECT * FROM unnest(?::bigint[], ?::integer[]) AS c(id, count)",
            ^ids,
            ^counts
          ),
        on: c.id == n.id and c.count == n.count
      ),
      set: [read_at: DateTime.utc_now(:second)]
    )

    :ok
  end

  defp unread(user_id),
    do: from(n in __MODULE__, where: n.user_id == ^user_id and is_nil(n.read_at))

  # Targets are loaded in the snapshot, with only the fields the projection
  # reads, and every title goes through it.
  defp entries(scope, rows) do
    reviews =
      rows
      |> Enum.map(& &1.review_id)
      |> load(Review, [:id, :tip_id, :user_id, :deleted_at, :dead_at])

    tips =
      (Enum.map(rows, & &1.tip_id) ++ Enum.map(Map.values(reviews), & &1.tip_id))
      |> load(Tip, [:id, :user_id, :title, :deleted_at, :dead_at])

    reviewers =
      for %{type: :tip_reviewed, review_id: id} <- rows,
          review = reviews[id],
          Visibility.decision(scope, review) == :visible,
          do: review.user_id

    authors = load(reviewers, User, [:id, :handle, :deleted_at])

    Enum.map(rows, fn row ->
      review = reviews[row.review_id]
      tip = tips[row.tip_id || review.tip_id]
      Projection.inbox_entry(scope, row, tip, review, review && authors[review.user_id])
    end)
  end

  defp load(ids, schema, fields) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    from(r in schema, where: r.id in ^ids, select: struct(r, ^fields))
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end
end
