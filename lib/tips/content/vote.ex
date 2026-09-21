defmodule Tips.Content.Vote do
  @moduledoc """
  A stored helpful (1) or not helpful (-1) vote on exactly one tip or review.

  Votes have no primary key. Write with `insert`, `insert_all`, `update_all` or
  `delete_all`; struct-based updates and deletes are unavailable. Write statements
  must preserve the voter and target, changing only the value or removing the row.
  Database triggers maintain counters for every stored vote, including invalidation.
  """
  use Ecto.Schema

  @primary_key false
  schema "votes" do
    belongs_to :user, Tips.Accounts.User
    belongs_to :tip, Tips.Content.Tip
    belongs_to :review, Tips.Content.Review

    field :value, :integer

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime)
  end
end
