defmodule Tips.Content.SearchCommittedTest do
  # Ranking, visibility changes and hydration each run on their own real
  # connection and commit, as they do across concurrent requests.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.VisibilityFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Tips.Accounts.{Scope, User}
  alias Tips.Content.{Review, Search, Tip}
  alias Tips.Repo

  setup do
    data =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, data} = Repo.transaction(&committed_corpus/0)
        data
      end)

    on_exit(fn -> Sandbox.unboxed_run(Repo, fn -> delete_owned!(data) end) end)
    data
  end

  test "hydration rechecks committed visibility changes after ranking", data do
    %{term: term, tips: tips, review: review} = data

    assert {:ok, %{candidates: candidates, total: 5}} =
             Sandbox.unboxed_run(Repo, fn -> Search.rank(term, []) end)

    ranked = Enum.map(candidates, & &1.tip_id)
    assert Enum.sort(ranked) == tips |> Map.values() |> Enum.map(& &1.id) |> Enum.sort()
    assert %{review_id: review_id} = Enum.find(candidates, &(&1.tip_id == tips.reviewed.id))
    assert review_id == review.id

    Sandbox.unboxed_run(Repo, fn ->
      put_marker!(tips.hidden, :hidden)
      put_marker!(tips.deleted, :deleted)
      put_marker!(review, :hidden)
    end)

    surviving = ranked -- [tips.hidden.id, tips.deleted.id]

    for {name, scope} <- data.viewers do
      entries = hydrate(scope, term, candidates)
      assert Enum.map(entries, & &1.tip.id) == surviving, "viewer #{name}"

      assert %{matched_review_id: nil, excerpt: nil} =
               Enum.find(entries, &(&1.tip.id == tips.reviewed.id))

      refute inspect(entries) =~ "SECRET"
    end

    Sandbox.unboxed_run(Repo, fn -> put_marker!(tips.reviewed, :deleted) end)

    for {name, scope} <- data.viewers do
      assert Enum.map(hydrate(scope, term, candidates), & &1.tip.id) ==
               surviving -- [tips.reviewed.id],
             "viewer #{name}"
    end
  end

  defp hydrate(scope, term, candidates),
    do: Sandbox.unboxed_run(Repo, fn -> Search.hydrate(scope, term, candidates) end)

  defp committed_corpus do
    author = user_fixture()
    moderator = moderator!(user_fixture())
    reviewer = user_fixture()
    # A term no other committed row contains, so ranking sees only this corpus.
    term = "quoll#{System.unique_integer([:positive])}"

    tips = %{
      first: tip!(author, "#{term} #{term} #{term}", "Notes"),
      hidden: tip!(author, "#{term} #{term} SECRET title", "Notes"),
      deleted: tip!(author, "#{term} SECRET deleted", "Notes"),
      reviewed: tip!(author, "Reviewed", "Notes with more words"),
      last: tip!(author, term, "Notes with many more words than the others")
    }

    # review_fixture/2 would also commit its default author, which cleanup does not own.
    review =
      Repo.insert!(%Review{
        tip_id: tips.reviewed.id,
        user_id: reviewer.id,
        submission_key: Ecto.UUID.generate(),
        body: "#{term} SECRET review",
        created_at: DateTime.utc_now(:second)
      })

    :ok = Search.write_review_text(review.id)

    %{
      term: term,
      tips: tips,
      review: review,
      user_ids: [author.id, moderator.id, reviewer.id],
      viewers: [
        anonymous: nil,
        author: Scope.for_user(author),
        moderator: Scope.for_user(moderator)
      ]
    }
  end

  defp tip!(author, title, body) do
    tip = tip_fixture(author, %{title: title, body: body})
    :ok = Search.write_tip_text(tip.id)
    tip
  end

  defp delete_owned!(%{tips: tips, review: review, user_ids: user_ids}) do
    tip_ids = tips |> Map.values() |> Enum.map(& &1.id)

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.query!("DELETE FROM review_search WHERE review_id = $1", [review.id])
        Repo.query!("DELETE FROM tip_search WHERE tip_id = ANY($1)", [tip_ids])
        Repo.delete_all(from(r in Review, where: r.id == ^review.id))
        Repo.delete_all(from(t in Tip, where: t.id in ^tip_ids))
        Repo.delete_all(from(u in User, where: u.id in ^user_ids))
      end)
  end
end
