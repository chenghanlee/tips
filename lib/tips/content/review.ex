defmodule Tips.Content.Review do
  @moduledoc "A review with independent author deletion and moderation visibility."
  use Ecto.Schema
  import Ecto.Changeset

  schema "reviews" do
    belongs_to :user, Tips.Accounts.User
    belongs_to :tip, Tips.Content.Tip, define_field: false
    field :tip_id, :id, writable: :insert, on_writable_violation: :raise
    belongs_to :model, Tips.Content.Model, type: :string
    belongs_to :environment, Tips.Content.Environment, type: :string

    field :body, :string
    field :model_other, :string
    field :prompt, :string
    field :output, :string
    field :submission_key, Ecto.UUID, writable: :insert, on_writable_violation: :raise
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

  @editable [:body, :model_id, :model_other, :environment_id, :prompt, :output]

  @doc "Validates a new review; ownership, counters and versions are managed separately."
  def changeset(review, attrs) do
    review
    |> cast(attrs, [:submission_key, :tip_id])
    |> validate_required([:submission_key, :tip_id])
    |> edit_changeset(attrs)
    |> unique_constraint(:submission_key, name: :reviews_submission_unique)
    |> unique_constraint(:tip_id, name: :reviews_one_per_user)
    |> foreign_key_constraint(:tip_id)
  end

  @doc "Validates the author-editable fields only, for a new review or an edit."
  def edit_changeset(review, attrs) do
    review
    |> cast(attrs, @editable)
    |> validate_utf8()
    |> validate_required([:body])
    |> validate_length(:body, min: 1, max: 20_000, count: :codepoints)
    |> validate_format(:body, ~r/\S/u)
    |> validate_length(:model_other, max: 80, count: :codepoints)
    |> validate_format(:model_other, ~r/\S/u)
    |> validate_length(:prompt, max: 20_000, count: :codepoints)
    |> validate_format(:prompt, ~r/\S/u)
    |> validate_length(:output, max: 20_000, count: :codepoints)
    |> validate_format(:output, ~r/\S/u)
    |> validate_no_null_bytes()
    |> validate_model_choice()
    |> foreign_key_constraint(:model_id)
    |> foreign_key_constraint(:environment_id)
  end

  # Text validations run regexes, which raise on invalid UTF-8. Such a value
  # becomes an error and leaves the changes; params keep it.
  defp validate_utf8(changeset) do
    Enum.reduce(changeset.changes, changeset, fn
      {field, value}, changeset when is_binary(value) ->
        if String.valid?(value),
          do: changeset,
          else: changeset |> delete_change(field) |> add_error(field, "is invalid")

      _change, changeset ->
        changeset
    end)
  end

  defp validate_no_null_bytes(changeset) do
    Enum.reduce(@editable, changeset, fn field, changeset ->
      validate_format(changeset, field, ~r/\A[^\x00]*\z/, message: "cannot contain a null byte")
    end)
  end

  defp validate_model_choice(changeset) do
    if get_field(changeset, :model_id) && get_field(changeset, :model_other) do
      add_error(changeset, :model_other, "cannot be set with a selected model")
    else
      changeset
    end
  end
end
