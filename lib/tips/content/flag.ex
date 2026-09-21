defmodule Tips.Content.Flag do
  @moduledoc "A report of a suspected rule violation on one contribution."
  use Ecto.Schema

  schema "flags" do
    field :user_id, :id
    belongs_to :tip, Tips.Content.Tip
    belongs_to :review, Tips.Content.Review

    field :reason, Ecto.Enum, values: [:spam, :harmful, :fabricated, :other]
    field :detail, :string
    field :resolved_at, :utc_datetime
    field :resolved_by, :id

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime)
  end
end
