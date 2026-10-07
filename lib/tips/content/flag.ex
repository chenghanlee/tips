defmodule Tips.Content.Flag do
  @moduledoc """
  A report of a suspected rule violation on one contribution.

  `:fabricated` means suspected invented experience or evidence. A technique
  that failed or is outdated belongs in reviews and votes, not in a report.
  """
  use Ecto.Schema

  import Ecto.Changeset

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

  @doc """
  Validates the reporter's reason and optional explanation. The reporter and
  target come from the caller, never from `attrs`.
  """
  def report_changeset(flag, attrs) do
    flag
    |> cast(attrs, [:reason, :detail])
    |> validate_required([:reason])
    |> validate_length(:detail, max: 1000, count: :codepoints)
    |> validate_format(:detail, ~r/\A[^\x00]*\z/, message: "cannot contain a null byte")
    |> unique_constraint(:tip_id, name: :flags_open_tip)
    |> unique_constraint(:review_id, name: :flags_open_review)
  end
end
