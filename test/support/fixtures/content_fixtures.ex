defmodule Tips.ContentFixtures do
  @moduledoc "Database fixtures for contributions, including invalid-row constraint tests."

  alias Tips.Content.{Review, Tip}
  alias Tips.Repo

  import Tips.AccountsFixtures

  def tip_fixture(user \\ user_fixture(), attrs \\ %{}) do
    Tip
    |> struct!(
      Enum.into(attrs, %{
        user_id: user.id,
        submission_key: Ecto.UUID.generate(),
        title: "A useful technique",
        body: "Explain the technique with a concrete example.",
        tag_id: "other",
        created_at: DateTime.utc_now(:second)
      })
    )
    |> Repo.insert!()
  end

  def review_fixture(tip \\ tip_fixture(), attrs \\ %{}) do
    Review
    |> struct!(
      Enum.into(attrs, %{
        tip_id: tip.id,
        user_id: user_fixture().id,
        submission_key: Ecto.UUID.generate(),
        body: "The technique helped in this synthetic test.",
        created_at: DateTime.utc_now(:second)
      })
    )
    |> Repo.insert!()
  end

  def vote_fixture(target, attrs \\ %{}) do
    target_attrs =
      case target do
        %Tip{id: id} -> %{tip_id: id}
        %Review{id: id} -> %{review_id: id}
      end

    attrs =
      attrs
      |> Enum.into(Map.put(target_attrs, :value, 1))
      |> Map.put_new_lazy(:user_id, fn -> user_fixture().id end)

    Tips.Content.Vote
    |> struct!(attrs)
    |> Repo.insert!()
  end
end
