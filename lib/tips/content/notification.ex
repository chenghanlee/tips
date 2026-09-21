defmodule Tips.Content.Notification do
  @moduledoc "A recipient's folded notification about one contribution."
  use Ecto.Schema

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
end
