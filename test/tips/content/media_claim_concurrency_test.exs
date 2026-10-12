defmodule Tips.Content.MediaClaimConcurrencyTest do
  # Each claim and opposing write runs on its own backend and commits for real.
  # The discard/expiry side is simulated by a transaction that locks the media
  # row and marks it for cleanup, as the future workers must (#66/#67). These
  # tests establish the claim participant's serialization, not those workers.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.LockSessions
  import Tips.MediaFixtures

  alias Tips.Accounts.{Scope, User}
  alias Tips.Content
  alias Tips.Content.Media.Asset
  alias Tips.Content.{Review, Tip, Vote}
  alias Tips.Repo

  @attrs %{
    title: "Race the cleanup",
    body: "The claim and the discard lock the same row.",
    tag_id: "workflow",
    model_id: nil,
    model_other: nil,
    environment_id: nil,
    prompt: nil,
    output: nil
  }

  setup do
    {author, tip} =
      unboxed(fn ->
        author = user_fixture()
        {author, tip_fixture(author, @attrs)}
      end)

    on_exit(fn -> unboxed(fn -> delete_all(author.id) end) end)

    %{
      author: author,
      scope: Scope.for_user(author),
      tip: tip,
      supervisor: start_supervised!(Task.Supervisor)
    }
  end

  for operation <- [:publish, :edit] do
    describe "#{operation} versus discard has one winner" do
      test "a committed discard rejects the waiting claim", data do
        {claim, video} = claim_setup(unquote(operation), data)

        discard = open(data.supervisor)
        assert {1, _} = run(discard, fn -> discard!(video.id) end)

        claimer = call(data.supervisor, claim)
        await_blocked(claimer, discard)
        commit(discard)

        assert {:error, {:upload_failed, [id]}} = finish(claimer)
        assert id == video.id

        unboxed(fn ->
          assert %Asset{cleanup_at: %DateTime{}, tip_id: nil, position: nil} =
                   Repo.get!(Asset, video.id)

          assert %Tip{edit_version: 1} = Repo.get!(Tip, data.tip.id)
        end)
      end

      test "a committed claim leaves the waiting discard nothing to mark", data do
        {claim, video} = claim_setup(unquote(operation), data)

        claimer = open(data.supervisor)
        assert {:ok, %{id: id}} = run(claimer, claim)

        discard =
          call(data.supervisor, fn -> Repo.transact(fn -> {:ok, discard!(video.id)} end) end)

        await_blocked(discard, claimer)
        commit(claimer)

        assert {:ok, {0, _}} = finish(discard)

        unboxed(fn ->
          parent = if unquote(operation) == :publish, do: id, else: data.tip.id

          assert %Asset{cleanup_at: nil, expires_at: nil, tip_id: ^parent, position: 0} =
                   Repo.get!(Asset, video.id)
        end)
      end
    end
  end

  test "the deadline is checked after the lock wait", data do
    key = Ecto.UUID.generate()
    video = unboxed(fn -> ready_video(data.author, {:new_tip, key}) end)

    # One statement keeps `media_deadline_chk`: the recovery deadline is about one second ahead.
    unboxed(fn ->
      Repo.query!(
        "UPDATE media SET created_at = now() - interval '49 hours' + interval '1 second', " <>
          "expires_at = now() + interval '1 second' WHERE id = $1",
        [video.id]
      )
    end)

    holder = open(data.supervisor)
    assert [_id] = run(holder, fn -> lock!(video.id) end)

    claimer =
      call(data.supervisor, fn ->
        Content.publish_tip(data.scope, key, @attrs, [{:staged_video, video.id}])
      end)

    await_blocked(claimer, holder)
    assert unexpired?(video.id), "the claim must start waiting before the deadline"
    await_deadline(video.id)
    commit(holder)

    assert {:error, {:upload_failed, [id]}} = finish(claimer)
    assert id == video.id

    unboxed(fn ->
      assert Repo.all_by(Tip, submission_key: key) == []
      assert %Asset{tip_id: nil, cleanup_at: nil} = Repo.get!(Asset, video.id)
    end)
  end

  test "media rows are locked in ascending id order, whatever the selection order", data do
    key = Ecto.UUID.generate()

    {low, high} =
      unboxed(fn ->
        {ready_video(data.author, {:new_tip, key}), ready_video(data.author, {:new_tip, key})}
      end)

    assert low.id < high.id

    holder = open(data.supervisor)
    assert [_id] = run(holder, fn -> lock!(high.id) end)

    claimer =
      call(data.supervisor, fn ->
        Content.publish_tip(data.scope, key, @attrs, [
          {:staged_video, high.id},
          {:staged_video, low.id}
        ])
      end)

    await_blocked(claimer, holder)

    # The claim already holds the lower id while it waits for the higher one.
    probe = open(data.supervisor)
    probed = submit(probe, fn -> lock!(low.id) end)
    await_blocked(probe, claimer)
    commit(holder)

    assert {:ok, %{outcome: :created, id: id}} = finish(claimer)
    assert [_id] = await(probe, probed)
    commit(probe)

    unboxed(fn ->
      assert %Asset{tip_id: ^id, position: 1} = Repo.get!(Asset, low.id)
      assert %Asset{tip_id: ^id, position: 0} = Repo.get!(Asset, high.id)
    end)
  end

  # A new tip claims a video staged for its key; an edit claims one staged for
  # the existing tip's original key.
  defp claim_setup(:publish, data) do
    key = Ecto.UUID.generate()
    video = unboxed(fn -> ready_video(data.author, {:new_tip, key}) end)
    {fn -> Content.publish_tip(data.scope, key, @attrs, [{:staged_video, video.id}]) end, video}
  end

  defp claim_setup(:edit, data) do
    video = unboxed(fn -> ready_video(data.author, {:new_tip, data.tip.submission_key}) end)

    claim = fn ->
      Content.edit_tip(data.scope, data.tip.id, 1, @attrs, [{:staged_video, video.id}])
    end

    {claim, video}
  end

  defp ready_video(user, target) do
    staged_video_fixture(user, %{
      target: target,
      state: :ready,
      stream_uid: "stream-#{Ecto.UUID.generate()}",
      duration_s: 12.5
    })
  end

  defp lock!(id),
    do: Repo.all(from(a in Asset, where: a.id == ^id, lock: "FOR NO KEY UPDATE", select: a.id))

  # The cleanup side's guarded mark: only an unattached row not already in cleanup.
  defp discard!(id) do
    lock!(id)

    Repo.update_all(
      from(a in Asset,
        where: a.id == ^id and is_nil(a.tip_id) and is_nil(a.review_id) and is_nil(a.cleanup_at)
      ),
      set: [cleanup_at: DateTime.utc_now(:second), position: nil, reconcile_after: nil]
    )
  end

  defp unexpired?(id) do
    unboxed(fn ->
      Repo.one!(
        from(a in Asset,
          where: a.id == ^id,
          select: fragment("? > clock_timestamp()", a.expires_at)
        )
      )
    end)
  end

  # Polls the database clock; the claim's lock wait must stay under the 2 s query timeout.
  defp await_deadline(id, attempts \\ 150) do
    cond do
      not unexpired?(id) ->
        :ok

      attempts == 0 ->
        flunk("the deadline did not pass")

      true ->
        Process.sleep(10)
        await_deadline(id, attempts - 1)
    end
  end

  defp delete_all(user_id) do
    tip_ids = Repo.all(from(t in Tip, where: t.user_id == ^user_id, select: t.id))
    review_ids = Repo.all(from(r in Review, where: r.tip_id in ^tip_ids, select: r.id))

    Repo.delete_all(from(a in Asset, where: a.user_id == ^user_id))
    Repo.delete_all(from(v in Vote, where: v.tip_id in ^tip_ids or v.review_id in ^review_ids))
    Repo.delete_all(from(s in "tip_search", where: s.tip_id in ^tip_ids))
    Repo.delete_all(from(r in Review, where: r.id in ^review_ids))
    Repo.delete_all(from(t in Tip, where: t.id in ^tip_ids))
    Repo.delete_all(from(u in User, where: u.id == ^user_id))
  end
end
