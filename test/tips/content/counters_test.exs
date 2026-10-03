defmodule Tips.Content.CountersTest do
  use Tips.DataCase, async: true

  alias Tips.Content.{Counters, Tip, Vote}

  import Tips.AccountsFixtures
  import Tips.ContentFixtures

  for target <- [:tip, :review] do
    test "#{target} vote insert, value changes, identical update and removal apply exact deltas" do
      target = target_fixture(unquote(target))
      vote = vote_fixture(target)
      votes = from(v in Vote, where: v.user_id == ^vote.user_id)
      assert_counts(target, 1, 0)

      assert {1, nil} = Repo.update_all(votes, set: [value: -1])
      assert_counts(target, 0, 1)

      assert {1, nil} = Repo.update_all(votes, set: [value: -1])
      assert_counts(target, 0, 1)

      assert {1, nil} = Repo.update_all(votes, set: [value: 1])
      assert_counts(target, 1, 0)

      assert {1, nil} = Repo.delete_all(votes)
      assert_counts(target, 0, 0)
    end

    test "votes_one_per_#{target} rejects another vote by the same user" do
      target = target_fixture(unquote(target))
      vote = vote_fixture(target)

      assert_raise Ecto.ConstraintError, ~r/votes_one_per_#{unquote(target)}/, fn ->
        vote_fixture(target, %{user_id: vote.user_id, value: -1})
      end
    end
  end

  test "review hide, restore, text edit, author deletion and physical deletion count liveness" do
    tip = tip_fixture()
    review = review_fixture(tip)
    assert_review_count(tip, 1)

    review = review |> change(body: "Edited text") |> Repo.update!()
    assert_review_count(tip, 1)
    review = review |> change(dead_at: DateTime.utc_now(:second)) |> Repo.update!()
    assert_review_count(tip, 0)
    review = review |> change(dead_at: nil) |> Repo.update!()
    assert_review_count(tip, 1)
    review = review |> change(deleted_at: DateTime.utc_now(:second)) |> Repo.update!()
    assert_review_count(tip, 0)

    # Moderator hide/restore never revives an author-deleted review.
    review = review |> change(dead_at: DateTime.utc_now(:second)) |> Repo.update!()
    assert_review_count(tip, 0)
    review = review |> change(dead_at: nil) |> Repo.update!()
    assert_review_count(tip, 0)
    Repo.delete!(review)
    assert_review_count(tip, 0)

    live = review_fixture(tip)
    assert_review_count(tip, 1)
    Repo.delete!(live)
    assert_review_count(tip, 0)
  end

  for marker <- [:deleted_at, :dead_at] do
    test "a review inserted with #{marker} does not change its parent count" do
      tip = tip_fixture()
      review = review_fixture(tip, %{unquote(marker) => DateTime.utc_now(:second)})
      assert_review_count(tip, 0)
      Repo.delete!(review)
      assert_review_count(tip, 0)
    end
  end

  test "votes_value_chk rejects 0" do
    tip = tip_fixture()

    assert_raise Ecto.ConstraintError, ~r/votes_value_chk/, fn ->
      vote_fixture(tip, %{value: 0})
    end
  end

  test "one voter may vote on multiple distinct tips and reviews" do
    voter = user_fixture()
    targets = [tip_fixture(), tip_fixture(), review_fixture(), review_fixture()]

    for target <- targets do
      vote_fixture(target, %{user_id: voter.id})
      assert_counts(target, 1, 0)
    end
  end

  test "recount repairs only incorrect tip and review counters and then does no work" do
    tip = tip_fixture()
    empty_tip = tip_fixture()
    review = review_fixture(tip)
    hidden = review_fixture(tip, %{dead_at: DateTime.utc_now(:second)})
    review_fixture(tip, %{deleted_at: DateTime.utc_now(:second)})
    vote_fixture(tip)
    vote_fixture(tip, %{value: -1})
    vote_fixture(review, %{value: -1})
    vote_fixture(hidden)

    Repo.query!("UPDATE tips SET up_count = 99, down_count = 98, review_count = 97")
    Repo.query!("UPDATE reviews SET up_count = 99, down_count = 98")

    assert {2, 3} = Counters.recount!()
    assert_counts(tip, 1, 1)
    assert_review_count(tip, 1)
    assert_counts(empty_tip, 0, 0)
    assert_review_count(empty_tip, 0)
    assert_counts(review, 0, 1)
    assert_counts(hidden, 1, 0)
    assert {0, 0} = Counters.recount!()
  end

  defp target_fixture(:tip), do: tip_fixture()
  defp target_fixture(:review), do: review_fixture()

  defp assert_counts(target, up, down) do
    score = up - down
    assert %{up_count: ^up, down_count: ^down, score: ^score} = Repo.reload!(target)
  end

  defp assert_review_count(tip, count) do
    assert %Tip{review_count: ^count} = Repo.reload!(tip)
  end
end
