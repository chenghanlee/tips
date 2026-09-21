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
end
