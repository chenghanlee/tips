defmodule Tips.Content.EditConcurrencyTest do
  # Each edit and opposing write runs on its own backend and commits for real.
  # The test observes the actual lock wait before letting the first transaction commit.
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.LockSessions
  import Tips.MediaFixtures

  alias Tips.Accounts.{Scope, User}
  alias Tips.Content
  alias Tips.Content.{Notification, Review, Tip, Vote}
  alias Tips.Content.Media.Asset
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
    {author, parent_author, tip, review} =
      unboxed(fn ->
        author = user_fixture()
        parent_author = user_fixture()
        tip = tip_fixture(author, @attrs.tip)
        parent = tip_fixture(parent_author)
        review = review_fixture(parent, Map.put(@attrs.review, :user_id, author.id))
        {author, parent_author, tip, review}
      end)

    on_exit(fn -> unboxed(fn -> delete_content([author.id, parent_author.id]) end) end)

    %{
      author: author,
      scope: Scope.for_user(author),
      rows: %{tip: tip, review: review},
      supervisor: start_supervised!(Task.Supervisor)
    }
  end

  for kind <- [:tip, :review], loser <- [:same, :different] do
    test "two editors with one expected version permit one change (#{kind}, #{loser} loser)",
         data do
      kind = unquote(kind)
      winner_attrs = %{@attrs[kind] | body: "The first tab saved."}

      loser_attrs =
        if unquote(loser) == :same, do: winner_attrs, else: %{winner_attrs | body: "Other tab."}

      winner = open(data.supervisor)
      assert {:ok, %{edit_version: 2}} = run(winner, fn -> edit(data, kind, 1, winner_attrs) end)

      racer = call(data.supervisor, fn -> edit(data, kind, 1, loser_attrs) end)
      await_blocked(racer, winner)
      commit(winner)

      assert {:error, :conflict} = finish(racer)
      unboxed(fn -> assert %{edit_version: 2, body: "The first tab saved."} = row(data, kind) end)
    end
  end

  describe "edit serializes with author ban and deletion" do
    for kind <- [:tip, :review], {change, error} <- [ban: :forbidden, delete: :unauthenticated] do
      test "a committed #{change} rejects the stale admitted scope (#{kind})", data do
        kind = unquote(kind)
        account = open(data.supervisor)
        assert {1, _} = run(account, fn -> change_account!(data.author, unquote(change)) end)

        editor = call(data.supervisor, fn -> edit(data, kind, 1, changed(kind)) end)
        await_blocked(editor, account)
        commit(account)

        assert {:error, unquote(error)} = finish(editor)
        unboxed(fn -> assert %{edit_version: 1, edited_at: nil} = row(data, kind) end)
      end

      test "a committed #{kind} edit completes before the #{change}", data do
        kind = unquote(kind)
        editor = open(data.supervisor)

        assert {:ok, %{edit_version: 2}} =
                 run(editor, fn -> edit(data, kind, 1, changed(kind)) end)

        account = open(data.supervisor)
        changed = submit(account, fn -> change_account!(data.author, unquote(change)) end)
        await_blocked(account, editor)
        commit(editor)
        assert {1, _} = await(account, changed)
        commit(account)

        unboxed(fn ->
          assert %{edit_version: 2} = row(data, kind)
          refute Repo.get!(User, data.author.id) == data.author
        end)
      end
    end
  end

  describe "edit versus hide restore or delete preserves the version guard" do
    # Moderator hide/restore advances the single edit version; author deletion does not.
    for kind <- [:tip, :review],
        {change, error} <- [hide: :conflict, restore: :conflict, delete: :not_found] do
      test "a committed #{change} rejects the edit (#{kind})", data do
        kind = unquote(kind)
        if unquote(change) == :restore, do: unboxed(fn -> mark!(data, kind, :hide) end)
        base = unboxed(fn -> row(data, kind) end)
        content = open(data.supervisor)
        assert {1, _} = run(content, fn -> mark!(data, kind, unquote(change)) end)

        editor =
          call(data.supervisor, fn -> edit(data, kind, base.edit_version, changed(kind)) end)

        await_blocked(editor, content)
        commit(content)

        assert {:error, unquote(error)} = finish(editor)
        assert %{edited_at: nil, body: body} = unboxed(fn -> row(data, kind) end)
        assert body == base.body
      end

      test "a committed #{kind} edit completes before the #{change}", data do
        kind = unquote(kind)
        if unquote(change) == :restore, do: unboxed(fn -> mark!(data, kind, :hide) end)
        base = unboxed(fn -> row(data, kind) end)
        editor = open(data.supervisor)

        assert {:ok, %{outcome: :updated, state: state}} =
                 run(editor, fn -> edit(data, kind, base.edit_version, changed(kind)) end)

        assert state == if(base.dead_at, do: :hidden, else: :live)

        content = open(data.supervisor)
        changed = submit(content, fn -> mark!(data, kind, unquote(change)) end)
        await_blocked(content, editor)
        commit(editor)
        assert {1, _} = await(content, changed)
        commit(content)

        unboxed(fn ->
          assert %{body: "Saved before the change.", edited_at: %DateTime{}} = row(data, kind)
        end)
      end
    end
  end

  test "snapshot never combines fields version and media from different commits", data do
    tip = data.rows.tip
    image = unboxed(fn -> image_fixture(tip, description: "Old description") end)
    writer = open(data.supervisor)

    assert {1, _} =
             run(writer, fn ->
               Repo.update_all(from(t in Tip, where: t.id == ^tip.id),
                 set: [title: "New title"],
                 inc: [edit_version: 1]
               )

               Repo.update_all(from(a in Asset, where: a.id == ^image.id),
                 set: [description: "New description"]
               )
             end)

    # The writer commits as soon as the reader has read the content row.
    pause_after_content_read()

    reader =
      call(data.supervisor, fn ->
        Process.put(:pause_after_content_read, self())
        Content.get_edit_form(data.scope, :tip, tip.id)
      end)

    assert_receive {:paused, pid}, 1_000
    commit(writer)
    send(pid, :resume)

    assert {:ok, form} = finish(reader)
    assert %{edit_version: 1, base: %{attrs: %{title: "Race the same version"}}} = form
    assert form.base.uploads == [{:retained, image.id, "Old description"}]
    assert [%{id: image_id, description: "Old description"}] = form.media
    assert image_id == image.id

    unboxed(fn ->
      assert {:ok, %{edit_version: 2, media: [%{description: "New description"}]}} =
               Content.get_edit_form(data.scope, :tip, tip.id)
    end)
  end

  for parent_state <- [:live, :hidden, :deleted] do
    test "review text edit completes while another connection locks the parent " <>
           "(#{parent_state} parent)",
         data do
      parent_id = data.rows.review.tip_id

      unboxed(fn ->
        case unquote(parent_state) do
          :live -> :ok
          :hidden -> Repo.update_all(where(Tip, id: ^parent_id), set: [dead_at: now()])
          :deleted -> Repo.update_all(where(Tip, id: ^parent_id), set: [deleted_at: now()])
        end
      end)

      holder = open(data.supervisor)
      assert [^parent_id] = run(holder, fn -> lock_tip(parent_id) end)

      editor = call(data.supervisor, fn -> edit(data, :review, 1, changed(:review)) end)
      assert {:ok, %{outcome: :updated, edit_version: 2}} = finish(editor)
      commit(holder)
    end
  end

  test "a lost connection during an edit reports an unknown outcome", data do
    holder = open(data.supervisor)
    assert [_id] = run(holder, fn -> lock_user(data.author.id) end)

    editor = call(data.supervisor, fn -> edit(data, :tip, 1, changed(:tip)) end)
    await_blocked(editor, holder)

    log =
      capture_log(fn ->
        unboxed(fn -> Repo.query!("SELECT pg_terminate_backend($1)", [editor.backend]) end)
        assert {:error, :outcome_unknown} = finish(editor)
      end)

    assert log =~ "outcome unknown"
    commit(holder)
    unboxed(fn -> assert %{edit_version: 1, edited_at: nil} = row(data, :tip) end)
  end

  defp edit(data, :tip, version, attrs),
    do: Content.edit_tip(data.scope, data.rows.tip.id, version, attrs, [])

  defp edit(data, :review, version, attrs),
    do: Content.edit_review(data.scope, data.rows.review.id, version, attrs, [])

  defp changed(kind), do: %{@attrs[kind] | body: "Saved before the change."}

  defp row(data, kind), do: Repo.reload!(data.rows[kind])

  defp change_account!(%User{id: id}, :ban),
    do: Repo.update_all(where(User, id: ^id), set: [ban: :full, banned_at: now()])

  defp change_account!(%User{id: id}, :delete),
    do:
      Repo.update_all(where(User, id: ^id),
        set: [deleted_at: now(), handle: nil, email: nil]
      )

  defp mark!(data, kind, change) do
    %schema{id: id} = data.rows[kind]
    query = where(schema, id: ^id)

    case change do
      :hide -> Repo.update_all(query, set: [dead_at: now()], inc: [edit_version: 1])
      :restore -> Repo.update_all(query, set: [dead_at: nil], inc: [edit_version: 1])
      :delete -> Repo.update_all(query, set: [deleted_at: now()])
    end
  end

  defp lock_user(id),
    do: Repo.all(from(u in User, where: u.id == ^id, lock: "FOR NO KEY UPDATE", select: u.id))

  defp lock_tip(id),
    do: Repo.all(from(t in Tip, where: t.id == ^id, lock: "FOR UPDATE", select: t.id))

  defp now, do: DateTime.utc_now(:second)

  # Pauses the marked process after its first statement that reads a tip or
  # review row, until the test sends `:resume`.
  defp pause_after_content_read do
    test = self()
    id = {__MODULE__, make_ref()}
    :telemetry.attach(id, [:tips, :repo, :query], &__MODULE__.pause/4, test)
    on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def pause(_event, _measurements, %{source: source}, test) when source in ["tips", "reviews"] do
    if Process.get(:pause_after_content_read) == self() do
      Process.delete(:pause_after_content_read)
      send(test, {:paused, self()})

      receive do
        :resume -> :ok
      end
    end
  end

  def pause(_event, _measurements, _metadata, _test), do: :ok

  defp delete_content(user_ids) do
    tip_ids = Repo.all(from(t in Tip, where: t.user_id in ^user_ids, select: t.id))

    review_ids =
      Repo.all(
        from(r in Review, where: r.user_id in ^user_ids or r.tip_id in ^tip_ids, select: r.id)
      )

    Repo.delete_all(from(a in Asset, where: a.user_id in ^user_ids))
    Repo.delete_all(from(n in Notification, where: n.user_id in ^user_ids))
    Repo.delete_all(from(v in Vote, where: v.tip_id in ^tip_ids or v.review_id in ^review_ids))
    Repo.delete_all(from(s in "review_search", where: s.review_id in ^review_ids))
    Repo.delete_all(from(s in "tip_search", where: s.tip_id in ^tip_ids))
    Repo.delete_all(from(r in Review, where: r.id in ^review_ids))
    Repo.delete_all(from(t in Tip, where: t.id in ^tip_ids))
    Repo.delete_all(from(u in User, where: u.id in ^user_ids))
  end
end
