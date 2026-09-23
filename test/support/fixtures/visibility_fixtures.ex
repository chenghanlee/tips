defmodule Tips.VisibilityFixtures do
  @moduledoc "Persisted viewers and content visibility markers for visibility/projection tests."

  alias Tips.Accounts.{Scope, User}
  alias Tips.Content.{Review, Tip}
  alias Tips.Repo

  import Ecto.Query
  import Tips.AccountsFixtures

  @markers %{
    live: %{deleted: false, hidden: false},
    hidden: %{deleted: false, hidden: true},
    deleted: %{deleted: true, hidden: false},
    deleted_and_hidden: %{deleted: true, hidden: true}
  }

  @doc "The four stored marker combinations of `deleted_at` and `dead_at`."
  def markers, do: Map.keys(@markers)

  @doc "Sets the stored visibility markers on a persisted tip or review."
  def put_marker!(%module{} = content, marker) when module in [Tip, Review] do
    %{deleted: deleted?, hidden: hidden?} = Map.fetch!(@markers, marker)
    now = DateTime.utc_now(:second)

    content
    |> Ecto.Changeset.change(
      deleted_at: if(deleted?, do: now),
      dead_at: if(hidden?, do: now)
    )
    |> Repo.update!()
  end

  @doc "Makes a persisted user a moderator."
  def moderator!(%User{} = user),
    do: user |> Ecto.Changeset.change(role: :moderator) |> Repo.update!()

  @doc "Applies a full ban to a persisted user."
  def full_ban!(%User{} = user) do
    user
    |> Ecto.Changeset.change(ban: :full, banned_at: DateTime.utc_now(:second))
    |> Repo.update!()
  end

  @doc "Marks a persisted account deleted, as account deletion stores it."
  def delete_account!(%User{id: id}) do
    Repo.update_all(from(u in User, where: u.id == ^id),
      set: [deleted_at: DateTime.utc_now(:second), handle: nil, email: nil]
    )

    Repo.get!(User, id)
  end

  @doc """
  Builds the viewer matrix for content authored by `author`.

  Returns `{name, scope}` pairs for anonymous, unrelated reader, author,
  moderator, fully banned author/moderator and deleted-account author/moderator.
  The author's own account is mutated only for the returned variants.
  """
  def viewers(%User{} = author) do
    moderator = moderator!(user_fixture())

    [
      anonymous: nil,
      reader: Scope.for_user(user_fixture()),
      author: Scope.for_user(author),
      moderator: Scope.for_user(moderator),
      banned_author: Scope.for_user(%{author | ban: :full, banned_at: DateTime.utc_now(:second)}),
      banned_moderator: Scope.for_user(full_ban!(moderator!(user_fixture()))),
      deleted_author: Scope.for_user(deleted_copy(author)),
      deleted_moderator: Scope.for_user(delete_account!(moderator!(user_fixture())))
    ]
  end

  # Account deletion never leaves a live row behind; the author's content still
  # references the same id, so the scope carries the deleted state without
  # changing the fixture author used by other rows in the same test.
  defp deleted_copy(%User{} = author),
    do: %{author | deleted_at: DateTime.utc_now(:second), handle: nil, email: nil}

  @doc "Current curated label maps, as a consumer would cache them."
  def labels do
    %{
      tags: label_map(Tips.Content.Tag),
      models: label_map(Tips.Content.Model),
      environments: label_map(Tips.Content.Environment)
    }
  end

  defp label_map(schema), do: schema |> Repo.all() |> Map.new(&{&1.id, &1.label})
end
