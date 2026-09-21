defmodule Tips.Content.Review do
  @moduledoc "A review with independent author deletion and moderation visibility."
  use Ecto.Schema
  import Ecto.Changeset

  schema "reviews" do
    belongs_to :user, Tips.Accounts.User
    belongs_to :tip, Tips.Content.Tip
    belongs_to :model, Tips.Content.Model, type: :string
    belongs_to :environment, Tips.Content.Environment, type: :string

    field :body, :string
    field :model_other, :string
    field :prompt, :string
    field :output, :string
    field :submission_key, Ecto.UUID
    field :edit_version, :integer, default: 1
    field :up_count, :integer, default: 0
    field :down_count, :integer, default: 0
    field :score, :integer, read_after_writes: true
    field :best_score, :float, read_after_writes: true
    field :edited_at, :utc_datetime
    field :deleted_at, :utc_datetime
    field :dead_at, :utc_datetime

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime)
  end

  @doc "Validates author-editable content; ownership, counters and versions are managed separately."
  def changeset(review, attrs) do
    review
    |> cast(attrs, [
      :submission_key,
      :tip_id,
      :body,
      :model_id,
      :model_other,
      :environment_id,
      :prompt,
      :output
    ])
    |> validate_required([:submission_key, :tip_id, :body])
    |> validate_length(:body, min: 1, max: 20_000, count: :codepoints)
    |> validate_format(:body, ~r/\S/u)
    |> validate_length(:model_other, max: 80, count: :codepoints)
    |> validate_format(:model_other, ~r/\S/u)
    |> validate_length(:prompt, max: 20_000, count: :codepoints)
    |> validate_format(:prompt, ~r/\S/u)
    |> validate_length(:output, max: 20_000, count: :codepoints)
    |> validate_format(:output, ~r/\S/u)
    |> validate_model_choice()
    |> unique_constraint(:submission_key, name: :reviews_submission_unique)
    |> unique_constraint(:tip_id, name: :reviews_one_per_user)
  end

  defp validate_model_choice(changeset) do
    if get_field(changeset, :model_id) && get_field(changeset, :model_other) do
      add_error(changeset, :model_other, "cannot be set with a selected model")
    else
      changeset
    end
  end
end
