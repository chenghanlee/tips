defmodule Tips.Content.EditConcurrencyTest do
  # Each edit and opposing write runs on its own backend and commits for real.
  # The test observes the actual lock wait before letting the first transaction commit.
  # Moderator hide and author deletion do not exist yet, so their writes are database
  # fixtures that take the shared lock order: accounts, then the content row.
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.LockSessions

  alias Tips.Accounts.{Scope, User}
  alias Tips.Content
  alias Tips.Content.{Review, Tip}
  alias Tips.Repo

  @attrs %{
    tip: %{
      title: "Race the same version",
      body: "Two tabs edit the same tip.",
      tag_id: "workflow",
      model_id: nil,
      model_other: nil,
      environment_id: nil,
      prompt: nil,
      output: nil
    },
    review: %{
      body: "Two tabs edit the same review.",
      model_id: nil,
      model_other: nil,
      environment_id: nil,
      prompt: nil,
      output: nil
    }
  }

  setup do
    {author, moderator, parent, tip, review} =
      unboxed(fn ->
        author = user_fixture()
        parent = tip_fixture(user_fixture())

        # Inserted directly: review_fixture/2 would commit an extra default author.
        review =
          Repo.insert!(%Review{
            tip_id: parent.id,
            user_id: author.id,
            submission_key: Ecto.UUID.generate(),
            body: "The technique helped in this synthetic test.",
            created_at: DateTime.utc_now(:second)
          })

        {author, user_fixture(), parent, tip_fixture(author), review}
      end)

    on_exit(fn ->
      unboxed(fn -> delete_content([author.id, moderator.id, parent.user_id]) end)
    end)

    %{
      author: author,
      moderator: moderator,
      # Admitted before any opposing change commits.
      scope: Scope.for_user(author),
      parent: parent,
      rows: %{tip: tip, review: review},
      supervisor: start_supervised!(Task.Supervisor)
    }
  end

  for kind <- [:tip, :review] do
    test "#{kind}: one expected version permits one winning edit", data do
      kind = unquote(kind)
      first = open(data.supervisor)
      winner = %{@attrs[kind] | body: "The first tab wins."}

      assert {:ok, %{outcome: :updated, edit_version: 2}} =
               run(first, fn -> edit(kind, data, 1, winner) end)

      second = call(data.supervisor, fn -> edit(kind, data, 1, @attrs[kind]) end)
      await_blocked(second, first)
      commit(first)

      assert {:error, :conflict} = finish(second)

      unboxed(fn ->
        assert %{edit_version: 2, body: "The first tab wins."} = current(kind, data)
      end)
    end
  end

  describe "edit serializes with account ban and deletion" do
    for {change, rejection} <- [ban: :forbidden, delete_account: :unauthenticated] do
      test "a committed #{change} rejects the stale admitted scope", data do
        opposing = open(data.supervisor)
        assert {1, _} = run(opposing, fn -> account!(unquote(change), data.author) end)

        edit = call(data.supervisor, fn -> edit(:tip, data, 1, @attrs.tip) end)
        await_blocked(edit, opposing)
        commit(opposing)

        assert {:error, unquote(rejection)} = finish(edit)
        unboxed(fn -> assert %{edit_version: 1, edited_at: nil} = current(:tip, data) end)
      end

      test "an edit committed before the #{change} keeps its result", data do
        edit = open(data.supervisor)
        assert {:ok, %{edit_version: 2}} = run(edit, fn -> edit(:tip, data, 1, @attrs.tip) end)

        opposing = open(data.supervisor)
        changed = submit(opposing, fn -> account!(unquote(change), data.author) end)
        await_blocked(opposing, edit)
        commit(edit)
        assert {1, _} = await(opposing, changed)
        commit(opposing)

        unboxed(fn ->
          assert %{edit_version: 2, title: "Race the same version"} = current(:tip, data)
          refute Repo.get!(User, data.author.id) == data.author
        end)
      end
    end
  end

  describe "visibility and deletion races preserve the version guard" do
    for {change, rejection} <- [hide: :conflict, delete: :not_found] do
      test "a committed #{change} rejects the edit", data do
        opposing = open(data.supervisor)
        assert {1, _} = run(opposing, fn -> content!(unquote(change), data) end)

        edit = call(data.supervisor, fn -> edit(:tip, data, 1, @attrs.tip) end)
        await_blocked(edit, opposing)
        commit(opposing)

        assert {:error, unquote(rejection)} = finish(edit)
        unboxed(fn -> refute current(:tip, data).title == @attrs.tip.title end)
      end

      test "an edit committed before the #{change} is preserved by it", data do
        edit = open(data.supervisor)
        assert {:ok, %{edit_version: 2}} = run(edit, fn -> edit(:tip, data, 1, @attrs.tip) end)

        opposing = open(data.supervisor)
        changed = submit(opposing, fn -> content!(unquote(change), data) end)
        await_blocked(opposing, edit)
        commit(edit)
        assert {1, _} = await(opposing, changed)
        commit(opposing)

        unboxed(fn ->
          tip = current(:tip, data)
          assert tip.title == @attrs.tip.title

          case unquote(change) do
            :hide -> assert %{edit_version: 3, dead_at: %DateTime{}, deleted_at: nil} = tip
            :delete -> assert %{edit_version: 2, dead_at: nil, deleted_at: %DateTime{}} = tip
          end
        end)
      end
    end
  end

  test "review edit finishes under a committed unavailable parent held by another connection",
       data do
    # Committed in the documented order: a moderator hide locks the moderator and
    # advances the version; the parent author's deletion locks that author.
    for {change, version} <- [hide: 1, delete: 2] do
      unboxed(fn ->
        {:ok, _} = Repo.transact(fn -> {:ok, parent!(change, data)} end)
      end)

      holder = open(data.supervisor)
      assert [_id] = run(holder, fn -> lock_tip(data.parent.id) end)

      edit =
        call(data.supervisor, fn ->
          edit(:review, data, version, %{@attrs.review | body: "Edited under #{change}"})
        end)

      assert {:ok, %{outcome: :updated, edit_version: edited, state: :live}} = finish(edit)
      assert edited == version + 1
      commit(holder)
    end

    unboxed(fn ->
      assert %Tip{dead_at: %DateTime{}, deleted_at: %DateTime{}} =
               Repo.get!(Tip, data.parent.id)

      assert %{body: "Edited under delete", edit_version: 3} = current(:review, data)
    end)
  end

  test "a lost connection during the edit returns outcome_unknown", data do
    holder = open(data.supervisor)
    assert [_id] = run(holder, fn -> lock_tip(data.rows.tip.id) end)

    edit = call(data.supervisor, fn -> edit(:tip, data, 1, @attrs.tip) end)
    await_blocked(edit, holder)

    # The edit's own backend disappears before COMMIT; this cannot show a lost COMMIT reply.
    log =
      capture_log(fn ->
        unboxed(fn -> Repo.query!("SELECT pg_terminate_backend($1)", [edit.backend]) end)
        assert {:error, :outcome_unknown} = finish(edit)
      end)

    assert log =~ "Edit outcome unknown"
    commit(holder)

    unboxed(fn -> assert %{edit_version: 1, edited_at: nil} = current(:tip, data) end)

    # Nothing committed, so the original expected version still saves.
    assert {:ok, %{outcome: :updated, edit_version: 2}} =
             unboxed(fn -> edit(:tip, data, 1, @attrs.tip) end)
  end

  defp edit(:tip, data, version, attrs),
    do: Content.edit_tip(data.scope, data.rows.tip.id, version, attrs, [])

  defp edit(:review, data, version, attrs),
    do: Content.edit_review(data.scope, data.rows.review.id, version, attrs, [])

  defp current(:tip, data), do: Repo.get!(Tip, data.rows.tip.id)
  defp current(:review, data), do: Repo.get!(Review, data.rows.review.id)

  defp account!(:ban, %User{id: id}),
    do: Repo.update_all(where(User, id: ^id), set: [ban: :full, banned_at: now()])

  defp account!(:delete_account, %User{id: id}),
    do:
      Repo.update_all(where(User, id: ^id),
        set: [deleted_at: now(), handle: nil, email: nil]
      )

  # A moderator hide locks the moderator, then the content, and advances the version.
  defp content!(:hide, data) do
    lock_user(data.moderator.id)

    Repo.update_all(where(Tip, id: ^data.rows.tip.id),
      set: [dead_at: now()],
      inc: [edit_version: 1]
    )
  end

  # Author deletion locks the author, then the content.
  defp content!(:delete, data) do
    lock_user(data.author.id)
    Repo.update_all(where(Tip, id: ^data.rows.tip.id), set: [deleted_at: now()])
  end

  defp parent!(:hide, data) do
    lock_user(data.moderator.id)

    Repo.update_all(where(Tip, id: ^data.parent.id),
      set: [dead_at: now()],
      inc: [edit_version: 1]
    )
  end

  defp parent!(:delete, data) do
    lock_user(data.parent.user_id)
    Repo.update_all(where(Tip, id: ^data.parent.id), set: [deleted_at: now()])
  end

  defp lock_user(id),
    do: Repo.all(from(u in User, where: u.id == ^id, lock: "FOR NO KEY UPDATE", select: u.id))

  defp lock_tip(id),
    do: Repo.all(from(t in Tip, where: t.id == ^id, lock: "FOR NO KEY UPDATE", select: t.id))

  defp now, do: DateTime.utc_now(:second)

  defp delete_content(user_ids) do
    tip_ids = Repo.all(from(t in Tip, where: t.user_id in ^user_ids, select: t.id))

    review_ids =
      Repo.all(
        from(r in Review, where: r.user_id in ^user_ids or r.tip_id in ^tip_ids, select: r.id)
      )

    Repo.delete_all(from(s in "review_search", where: s.review_id in ^review_ids))
    Repo.delete_all(from(s in "tip_search", where: s.tip_id in ^tip_ids))
    Repo.delete_all(from(r in Review, where: r.id in ^review_ids))
    Repo.delete_all(from(t in Tip, where: t.id in ^tip_ids))
    Repo.delete_all(from(u in User, where: u.id in ^user_ids))
  end
end
