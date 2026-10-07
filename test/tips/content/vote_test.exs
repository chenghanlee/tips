defmodule Tips.Content.VoteTest do
  use Tips.DataCase, async: true

  alias Tips.Accounts.{Scope, User}
  alias Tips.Content
  alias Tips.Content.{Notification, Vote}

  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.VisibilityFixtures

  for kind <- [:tip, :review] do
    test "#{kind}: repeats are no-ops and each change or removal counts once" do
      kind = unquote(kind)
      target = target_fixture(kind)
      voter = Scope.for_user(user_fixture())
      type = upvoted(kind)

      assert {:ok, %{vote: 1, up_count: 1, down_count: 0, score: 1, outcome: :changed}} =
               Content.set_vote(voter, kind, target.id, 1)

      assert [%Notification{type: ^type, count: 1} = notification] = Repo.all(Notification)
      earlier = DateTime.add(notification.updated_at, -3600)
      notification |> change(updated_at: earlier) |> Repo.update!()

      assert {:ok, %{vote: 1, up_count: 1, down_count: 0, outcome: :unchanged}} =
               Content.set_vote(voter, kind, target.id, 1)

      assert [%Notification{count: 1, updated_at: ^earlier}] = Repo.all(Notification)

      assert {:ok, %{vote: -1, up_count: 0, down_count: 1, score: -1, outcome: :changed}} =
               Content.set_vote(voter, kind, target.id, -1)

      assert {:ok, %{vote: -1, up_count: 0, down_count: 1, outcome: :unchanged}} =
               Content.set_vote(voter, kind, target.id, -1)

      assert {:ok, %{vote: nil, up_count: 0, down_count: 0, score: 0, outcome: :changed}} =
               Content.set_vote(voter, kind, target.id, nil)

      assert {:ok, %{vote: nil, up_count: 0, down_count: 0, outcome: :unchanged}} =
               Content.set_vote(voter, kind, target.id, nil)

      assert [%Notification{count: 1, updated_at: ^earlier}] = Repo.all(Notification)
      assert %{up_count: 0, down_count: 0, edit_version: 1} = Repo.reload!(target)
    end

    test "#{kind}: each new helpful vote is another event, and the author's own vote notifies no one" do
      kind = unquote(kind)
      target = target_fixture(kind)
      author = Scope.for_user(Repo.get!(User, target.user_id))
      voter = Scope.for_user(user_fixture())
      vote_fixture(target, %{user_id: target.user_id})

      assert {:ok, %{vote: 1, outcome: :unchanged}} =
               Content.set_vote(author, kind, target.id, 1)

      assert {:ok, %{vote: -1, outcome: :changed}} = Content.set_vote(author, kind, target.id, -1)
      assert {:ok, %{vote: 1, outcome: :changed}} = Content.set_vote(author, kind, target.id, 1)
      assert Repo.all(Notification) == []

      for desired <- [1, nil, 1, -1, 1],
          do: {:ok, _} = Content.set_vote(voter, kind, target.id, desired)

      assert [%Notification{count: 3, read_at: nil}] = Repo.all(Notification)
      assert %{up_count: 2, down_count: 0, edit_version: 1} = Repo.reload!(target)
    end

    test "#{kind}: a rejected vote is an error, not an unchanged vote" do
      kind = unquote(kind)
      target = target_fixture(kind)
      banned = user_fixture()
      vote_fixture(target, %{user_id: banned.id, value: -1})
      banned = full_ban!(banned)

      assert {:error, :forbidden} = Content.set_vote(Scope.for_user(banned), kind, target.id, -1)
      assert {:error, :forbidden} = Content.set_vote(Scope.for_user(banned), kind, target.id, nil)

      unconfirmed = Scope.for_user(unconfirmed_user_fixture())
      assert {:error, :unconfirmed} = Content.set_vote(unconfirmed, kind, target.id, 1)
      assert {:error, :unauthenticated} = Content.set_vote(nil, kind, target.id, 1)

      voter = Scope.for_user(user_fixture())
      assert {:error, :not_found} = Content.set_vote(voter, kind, 9_000_000_000, 1)

      for marker <- [:hidden, :deleted] do
        put_marker!(target, marker)
        assert {:error, :not_found} = Content.set_vote(voter, kind, target.id, 1)
      end

      assert [%Vote{value: -1}] = Repo.all(Vote)
      assert %{up_count: 0, down_count: 1} = Repo.reload!(target)
      assert Repo.all(Notification) == []
    end
  end

  test "a review under a hidden or deleted tip takes votes" do
    tip = tip_fixture()
    review = review_fixture(tip)
    voter = Scope.for_user(user_fixture())

    put_marker!(tip, :hidden)
    assert {:ok, %{vote: 1, outcome: :changed}} = Content.set_vote(voter, :review, review.id, 1)

    put_marker!(tip, :deleted)

    assert {:ok, %{vote: nil, outcome: :changed}} =
             Content.set_vote(voter, :review, review.id, nil)
  end

  test "lifting a ban does not recreate an invalidated vote; a later vote is a new event" do
    tip = tip_fixture()
    voter = user_fixture()
    scope = Scope.for_user(voter)

    assert {:ok, %{up_count: 1}} = Content.set_vote(scope, :tip, tip.id, 1)

    # Ban, invalidate the vote as the moderation operation will, then lift the ban.
    banned = full_ban!(voter)
    Repo.delete_all(from(v in Vote, where: v.user_id == ^voter.id))
    banned |> change(ban: nil, banned_at: nil) |> Repo.update!()

    assert {:ok, %{vote: nil, up_count: 0, outcome: :unchanged}} =
             Content.set_vote(scope, :tip, tip.id, nil)

    assert {:ok, %{vote: 1, up_count: 1, outcome: :changed}} =
             Content.set_vote(scope, :tip, tip.id, 1)

    assert [%Notification{count: 2}] = Repo.all(Notification)
  end

  defp target_fixture(:tip), do: tip_fixture()
  defp target_fixture(:review), do: review_fixture()

  defp upvoted(:tip), do: :tip_upvoted
  defp upvoted(:review), do: :review_upvoted
end
