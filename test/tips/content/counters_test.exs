defmodule Tips.Content.CountersTest do
  use Tips.DataCase, async: true

  alias Tips.Content.{Counters, Tip, Vote}

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

    test "#{target} invalidation deletes stored votes once, including on hidden content" do
      target = target_fixture(unquote(target))
      vote_fixture(target)
      vote_fixture(target, %{value: -1})
      assert_counts(target, 1, 1)

      target |> change(dead_at: DateTime.utc_now(:second)) |> Repo.update!()
      assert_counts(target, 1, 1)

      target_field = if unquote(target) == :tip, do: :tip_id, else: :review_id
      votes = from(v in Vote, where: field(v, ^target_field) == ^target.id)
      assert {2, nil} = Repo.delete_all(votes)
      assert_counts(target, 0, 0)
      assert {0, nil} = Repo.delete_all(votes)
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

  for {name, attrs} <- [
        {"no target", %{tip_id: nil, review_id: nil}},
        {"both targets", :both}
      ] do
    test "votes_one_target rejects #{name}" do
      review = review_fixture()

      attrs =
        if unquote(Macro.escape(attrs)) == :both,
          do: %{tip_id: review.tip_id, review_id: review.id},
          else: unquote(Macro.escape(attrs))

      assert_raise Ecto.ConstraintError, ~r/votes_one_target/, fn ->
        vote_fixture(review, attrs)
      end
    end
  end

  for value <- [0, 2] do
    test "votes_value_chk rejects #{value}" do
      tip = tip_fixture()

      assert_raise Ecto.ConstraintError, ~r/votes_value_chk/, fn ->
        vote_fixture(tip, %{value: unquote(value)})
      end
    end
  end

  for {field, attrs} <- [
        {:user_id, %{user_id: -1}},
        {:tip_id, %{tip_id: -1}},
        {:review_id, %{tip_id: nil, review_id: -1}}
      ] do
    test "votes_#{field}_fkey rejects unknown references" do
      tip = tip_fixture()

      assert_raise Ecto.ConstraintError, ~r/votes_#{unquote(field)}_fkey/, fn ->
        vote_fixture(tip, unquote(Macro.escape(attrs)))
      end
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

  test "statement inserts receive the database timestamp default and votes have no primary key" do
    tip = tip_fixture()
    voter = user_fixture()

    assert {1, nil} = Repo.insert_all(Vote, [%{user_id: voter.id, tip_id: tip.id, value: -1}])
    assert %Vote{created_at: %DateTime{}} = Repo.one!(Vote)
    assert Vote.__schema__(:primary_key) == []
    assert_counts(tip, 0, 1)
  end

  test "partial indexes and row triggers are installed on their actual targets" do
    %{rows: indexes} =
      Repo.query!("SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'votes'")

    for {name, target} <- [
          {"votes_one_per_tip", "tip_id"},
          {"votes_one_per_review", "review_id"},
          {"votes_by_tip", "tip_id"},
          {"votes_by_review", "review_id"}
        ] do
      assert [^name, definition] = Enum.find(indexes, fn [index, _] -> index == name end)
      assert definition =~ "WHERE (#{target} IS NOT NULL)"

      if String.starts_with?(name, "votes_one_per_") do
        assert definition =~ "UNIQUE INDEX"
        assert definition =~ "(user_id, #{target})"
      else
        assert definition =~ "(#{target}, created_at DESC)"
      end
    end

    assert %{rows: [["reviews", "reviews_counts"], ["votes", "votes_counts"]]} =
             Repo.query!("""
             SELECT tgrelid::regclass::text, tgname FROM pg_trigger
             WHERE tgname IN ('votes_counts', 'reviews_counts') AND NOT tgisinternal
             ORDER BY tgname
             """)
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
