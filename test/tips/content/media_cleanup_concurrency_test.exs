defmodule Tips.Content.MediaCleanupConcurrencyTest do
  # Each retirement runs on its own backend and commits for real.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.LockSessions
  import Tips.MediaFixtures

  alias Tips.Accounts.User
  alias Tips.Content.Media
  alias Tips.Content.Media.Asset
  alias Tips.Content.{Review, Tip, Vote}
  alias Tips.Repo

  setup do
    {author, image} =
      unboxed(fn ->
        author = user_fixture()
        {author, image_fixture(tip_fixture(author))}
      end)

    on_exit(fn -> unboxed(fn -> delete_all(author.id, image.id) end) end)

    %{image: image, supervisor: start_supervised!(Task.Supervisor)}
  end

  test "two concurrent retirements of one row enqueue one job", data do
    id = data.image.id
    first = open(data.supervisor)
    assert :ok = run(first, fn -> Media.retire([id]) end)

    second = call(data.supervisor, fn -> Repo.transact(fn -> {:ok, Media.retire([id])} end) end)
    await_blocked(second, first)
    commit(first)

    assert {:ok, :ok} = finish(second)

    unboxed(fn ->
      assert %Asset{cleanup_at: %DateTime{}, position: nil} = Repo.get!(Asset, id)
      assert [_job] = Repo.all(jobs(id))
    end)
  end

  defp jobs(media_id) do
    from(j in Oban.Job,
      where: j.worker == "Tips.Workers.CleanupMedia" and j.args["media_id"] == ^media_id
    )
  end

  defp delete_all(user_id, media_id) do
    tip_ids = Repo.all(from(t in Tip, where: t.user_id == ^user_id, select: t.id))
    review_ids = Repo.all(from(r in Review, where: r.tip_id in ^tip_ids, select: r.id))

    Repo.delete_all(jobs(media_id))
    Repo.delete_all(from(a in Asset, where: a.user_id == ^user_id))
    Repo.delete_all(from(v in Vote, where: v.tip_id in ^tip_ids or v.review_id in ^review_ids))
    Repo.delete_all(from(s in "tip_search", where: s.tip_id in ^tip_ids))
    Repo.delete_all(from(r in Review, where: r.id in ^review_ids))
    Repo.delete_all(from(t in Tip, where: t.id in ^tip_ids))
    Repo.delete_all(from(u in User, where: u.id == ^user_id))
  end
end
