defmodule Tips.Content.Notification do
  @moduledoc "A recipient's folded notification about one contribution."
  use Ecto.Schema

  alias Tips.Content.{Review, Tip, Visibility}
  alias Tips.Repo

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
end
