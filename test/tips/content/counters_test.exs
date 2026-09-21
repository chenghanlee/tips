defmodule Tips.Content.CountersTest do
  use Tips.DataCase, async: true

  import Tips.AccountsFixtures
  import Tips.ContentFixtures

  test "a stored vote updates its tip counters and generated score" do
    tip = tip_fixture()
    voter = user_fixture()

    Repo.query!("INSERT INTO votes (user_id, tip_id, value) VALUES ($1, $2, 1)", [
      voter.id,
      tip.id
    ])

    assert %{up_count: 1, down_count: 0, score: 1} = Repo.reload!(tip)
  end

  test "a live review increments its parent count" do
    tip = tip_fixture()
    review_fixture(tip)

    assert %{review_count: 1} = Repo.reload!(tip)
  end
end
