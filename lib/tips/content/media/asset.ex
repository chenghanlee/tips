defmodule Tips.Content.Media.Asset do
  @moduledoc "Persistence state for an image or video across staging, attachment and cleanup."

  use Ecto.Schema

  alias Tips.Content.Media.Target

  schema "media" do
    field :user_id, :id
    belongs_to :tip, Tips.Content.Tip
    belongs_to :review, Tips.Content.Review

    field :kind, Ecto.Enum, values: [:image, :video]
    field :description, :string
    field :is_animated, :boolean
    field :key, :string
    field :stream_uid, :string
    field :state, Ecto.Enum, values: [:uploading, :processing, :ready, :failed]
    field :duration_s, :float
    field :target, Target
    field :position, :integer
    field :expires_at, :utc_datetime
    field :reconcile_after, :utc_datetime
    field :cleanup_at, :utc_datetime

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime)
  end
end
