defmodule Tips.Content.PublicationConcurrencyTest do
  # Each publication and opposing write runs on its own backend and commits for real.
  # The test observes the actual lock wait before letting the first transaction commit.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.LockSessions

  alias Tips.Accounts.{Scope, User}
  alias Tips.Content
  alias Tips.Content.{Model, Notification, Review, Tag, Tip, Vote}
  alias Tips.Repo

  @attrs %{
    tip: %{
      title: "Race the same key",
      body: "Both tabs submit the same draft.",
      tag_id: "workflow",
      model_id: nil,
      model_other: nil,
      environment_id: nil,
      prompt: nil,
      output: nil
    },
    review: %{
      body: "Both tabs submit the same review.",
      model_id: nil,
      model_other: nil,
      environment_id: nil,
      prompt: nil,
      output: nil
    }
  }

  setup do
    {author, parent_author, parent} =
      unboxed(fn ->
        parent_author = user_fixture()
        {user_fixture(), parent_author, tip_fixture(parent_author)}
      end)

    # Committed active choices this test may retire; the shared seeds stay active.
    suffix = System.unique_integer([:positive])

    choices = %{
      tip: {:tag_id, Tag, "race-tag-#{suffix}"},
      review: {:model_id, Model, "race-model-#{suffix}"}
    }

    unboxed(fn ->
      for {_field, schema, id} <- Map.values(choices),
          do: Repo.insert!(struct(schema, id: id, label: id, sort_order: 99))
    end)

    on_exit(fn ->
      unboxed(fn ->
        delete_content([author.id, parent_author.id])

        for {_field, schema, id} <- Map.values(choices),
            do: Repo.delete_all(from(c in schema, where: c.id == ^id))
      end)
    end)

    %{
      author: author,
      scope: Scope.for_user(author),
      parent: parent,
      choices: choices,
      supervisor: start_supervised!(Task.Supervisor)
    }
  end

  for kind <- [:tip, :review], loser <- [:equivalent, :different, :unknown] do
    test "concurrent same key returns one created receipt and one reconciled receipt " <>
           "(#{kind}, #{loser} loser)",
         data do
      kind = unquote(kind)
      key = Ecto.UUID.generate()
      winner = open(data.supervisor)

      assert {:ok, %{outcome: :created, id: id}} =
               run(winner, fn -> publish(kind, data, key, @attrs[kind]) end)

      {loser_attrs, outcome} =
        case unquote(loser) do
          :equivalent ->
            {@attrs[kind], :existing_equivalent}

          :different ->
            {%{@attrs[kind] | body: "The other tab changed the body."}, :existing_different}

          :unknown ->
            # The author deletes the original before it commits; a deleted original compares as unknown.
            run(winner, fn -> delete!(kind, id) end)
            {@attrs[kind], :existing_unknown}
        end

      racer = call(data.supervisor, fn -> publish(kind, data, key, loser_attrs) end)
      watch_constraints(racer)
      await_blocked(racer, winner)
      commit(winner)

      assert {:ok, %{outcome: ^outcome, id: ^id, submission_key: ^key}} = finish(racer)
      assert_received {:constraint_rejected, constraint}
      assert constraint == "#{kind}s_submission_unique"
      unboxed(fn -> assert_one_effect_set(kind, data, key) end)
    end
  end

  describe "review uniqueness race reconciles the key before already reviewed" do
    test "a different key loses to the one-review index", data do
      winner = open(data.supervisor)

      assert {:ok, %{outcome: :created}} =
               run(winner, fn -> publish(:review, data, Ecto.UUID.generate(), @attrs.review) end)

      other_key = Ecto.UUID.generate()
      racer = call(data.supervisor, fn -> publish(:review, data, other_key, @attrs.review) end)
      watch_constraints(racer)
      await_blocked(racer, winner)
      commit(winner)

      assert {:error, :already_reviewed} = finish(racer)
      assert_received {:constraint_rejected, "reviews_one_per_user"}

      unboxed(fn ->
        assert {:ok, nil} =
                 Content.get_publication(data.scope, {:review, data.parent.id}, other_key, nil)

        assert [%Review{}] = Repo.all_by(Review, user_id: data.author.id)
      end)
    end

    test "the same key returns the original review", data do
      key = Ecto.UUID.generate()
      winner = open(data.supervisor)

      assert {:ok, %{outcome: :created, id: id}} =
               run(winner, fn -> publish(:review, data, key, @attrs.review) end)

      racer = call(data.supervisor, fn -> publish(:review, data, key, @attrs.review) end)
      watch_constraints(racer)
      await_blocked(racer, winner)
      commit(winner)

      # Both unique indexes match this row; either may report first.
      assert {:ok, %{outcome: :existing_equivalent, id: ^id}} = finish(racer)
      assert_received {:constraint_rejected, constraint}
      assert constraint in ["reviews_submission_unique", "reviews_one_per_user"]
      unboxed(fn -> assert_one_effect_set(:review, data, key) end)
    end
  end

  describe "publication serializes with author ban" do
    for kind <- [:tip, :review] do
      test "a committed #{kind} ban rejects the stale admitted scope", data do
        kind = unquote(kind)
        key = Ecto.UUID.generate()
        ban = open(data.supervisor)
        assert {1, _} = run(ban, fn -> ban!(data.author) end)

        publication = call(data.supervisor, fn -> publish(kind, data, key, @attrs[kind]) end)
        await_blocked(publication, ban)
        commit(ban)

        assert {:error, :forbidden} = finish(publication)
        unboxed(fn -> assert_no_effects(data) end)
      end

      test "a committed #{kind} publication completes before the ban", data do
        kind = unquote(kind)
        key = Ecto.UUID.generate()
        publication = open(data.supervisor)

        assert {:ok, %{outcome: :created}} =
                 run(publication, fn -> publish(kind, data, key, @attrs[kind]) end)

        ban = open(data.supervisor)
        banned = submit(ban, fn -> ban!(data.author) end)
        await_blocked(ban, publication)
        commit(publication)
        assert {1, _} = await(ban, banned)
        commit(ban)

        unboxed(fn ->
          assert %User{ban: :full} = Repo.get!(User, data.author.id)
          assert_one_effect_set(kind, data, key)
        end)
      end
    end
  end

  describe "review publication serializes with parent hide or delete" do
    for marker <- [:dead_at, :deleted_at] do
      test "a committed parent #{marker} change rejects the review", data do
        key = Ecto.UUID.generate()
        change = open(data.supervisor)
        assert {1, _} = run(change, fn -> mark_parent!(data.parent, unquote(marker)) end)

        publication = call(data.supervisor, fn -> publish(:review, data, key, @attrs.review) end)
        await_blocked(publication, change)

        # The waiting publication already holds its author: accounts lock before the parent.
        probe = open(data.supervisor)
        author_lock = submit(probe, fn -> lock_user(data.author.id) end)
        await_blocked(probe, publication)

        commit(change)
        assert {:error, :not_found} = finish(publication)
        assert [_id] = await(probe, author_lock)
        commit(probe)

        unboxed(fn ->
          assert_no_effects(data)
          assert %Tip{review_count: 0} = Repo.get!(Tip, data.parent.id)
        end)
      end

      test "a committed review completes before the parent #{marker} change", data do
        key = Ecto.UUID.generate()
        publication = open(data.supervisor)

        assert {:ok, %{outcome: :created}} =
                 run(publication, fn -> publish(:review, data, key, @attrs.review) end)

        change = open(data.supervisor)
        changed = submit(change, fn -> mark_parent!(data.parent, unquote(marker)) end)
        await_blocked(change, publication)
        commit(publication)
        assert {1, _} = await(change, changed)
        commit(change)

        unboxed(fn ->
          assert_one_effect_set(:review, data, key)
          assert %Tip{review_count: 1} = Repo.get!(Tip, data.parent.id)
        end)
      end
    end
  end

  describe "publication serializes with curated choice retirement" do
    for kind <- [:tip, :review] do
      test "a #{kind} choice retired during the author lock wait is not available", data do
        kind = unquote(kind)
        {field, schema, id} = data.choices[kind]
        holder = open(data.supervisor)
        assert [_id] = run(holder, fn -> lock_user(data.author.id) end)

        publication =
          call(data.supervisor, fn ->
            publish(kind, data, Ecto.UUID.generate(), Map.put(@attrs[kind], field, id))
          end)

        await_blocked(publication, holder)
        assert {1, _} = unboxed(fn -> retire!(schema, id) end)
        commit(holder)

        assert {:error, changeset} = finish(publication)
        assert [{^field, {"is not available", []}}] = changeset.errors
        unboxed(fn -> assert_no_effects(data) end)
      end

      test "a committed #{kind} completes before its choice retires", data do
        kind = unquote(kind)
        {field, schema, id} = data.choices[kind]
        key = Ecto.UUID.generate()
        publication = open(data.supervisor)

        assert {:ok, %{outcome: :created}} =
                 run(publication, fn ->
                   publish(kind, data, key, Map.put(@attrs[kind], field, id))
                 end)

        retirement = open(data.supervisor)
        retired = submit(retirement, fn -> retire!(schema, id) end)
        await_blocked(retirement, publication)
        commit(publication)
        assert {1, _} = await(retirement, retired)
        commit(retirement)

        unboxed(fn ->
          assert_one_effect_set(kind, data, key)
          assert %{active: false} = Repo.get!(schema, id)
        end)
      end
    end
  end

  describe "a same-key loser reconciles before a retirement that wins the choice" do
    for kind <- [:tip, :review], loser <- [:equivalent, :different, :unknown] do
      test "#{kind}, #{loser} loser", data do
        kind = unquote(kind)
        {field, schema, choice} = data.choices[kind]
        attrs = Map.put(@attrs[kind], field, choice)
        key = Ecto.UUID.generate()
        winner = open(data.supervisor)

        assert {:ok, %{outcome: :created, id: id}} =
                 run(winner, fn -> publish(kind, data, key, attrs) end)

        {loser_attrs, outcome} =
          case unquote(loser) do
            :equivalent ->
              {attrs, :existing_equivalent}

            :different ->
              {%{attrs | body: "The other tab changed the body."}, :existing_different}

            :unknown ->
              run(winner, fn -> delete!(kind, id) end)
              {attrs, :existing_unknown}
          end

        racer = call(data.supervisor, fn -> publish(kind, data, key, loser_attrs) end)
        await_blocked(racer, winner)

        # The retirement queues behind the winner's share lock, then the racer behind it.
        retirement = open(data.supervisor)
        retired = submit(retirement, fn -> retire!(schema, choice) end)
        await_blocked(retirement, winner)
        commit(winner)
        assert {1, _} = await(retirement, retired)
        await_blocked(racer, retirement)
        commit(retirement)

        assert {:ok, %{outcome: ^outcome, id: ^id, submission_key: ^key}} = finish(racer)
        unboxed(fn -> assert_one_effect_set(kind, data, key) end)
      end
    end
  end

  describe "a same-key loser reconciles before a locked eligibility rejection" do
    for kind <- [:tip, :review] do
      test "#{kind}: a ban queued ahead of the loser", data do
        kind = unquote(kind)
        key = Ecto.UUID.generate()
        winner = open(data.supervisor)

        assert {:ok, %{outcome: :created, id: id}} =
                 run(winner, fn -> publish(kind, data, key, @attrs[kind]) end)

        ban = open(data.supervisor)
        banned = submit(ban, fn -> ban!(data.author) end)
        await_blocked(ban, winner)
        racer = call(data.supervisor, fn -> publish(kind, data, key, @attrs[kind]) end)
        await_blocked(racer, [winner, ban])
        commit(winner)
        assert {1, _} = await(ban, banned)
        await_blocked(racer, ban)
        commit(ban)

        assert {:ok, %{outcome: :existing_equivalent, id: ^id}} = finish(racer)
        unboxed(fn -> assert_one_effect_set(kind, data, key) end)
      end
    end

    test "review: a parent hide that wins the parent lock", data do
      key = Ecto.UUID.generate()
      winner = open(data.supervisor)

      assert {:ok, %{outcome: :created, id: id}} =
               run(winner, fn -> publish(:review, data, key, @attrs.review) end)

      racer = call(data.supervisor, fn -> publish(:review, data, key, @attrs.review) end)
      await_blocked(racer, winner)
      hide = open(data.supervisor)
      hidden = submit(hide, fn -> mark_parent!(data.parent, :dead_at) end)
      await_blocked(hide, winner)
      commit(winner)
      assert {1, _} = await(hide, hidden)
      await_blocked(racer, hide)
      commit(hide)

      assert {:ok, %{outcome: :existing_equivalent, id: ^id, state: :live}} = finish(racer)
      unboxed(fn -> assert_one_effect_set(:review, data, key) end)
    end
  end

  defp publish(:tip, data, key, attrs), do: Content.publish_tip(data.scope, key, attrs, [])

  defp publish(:review, data, key, attrs),
    do: Content.publish_review(data.scope, data.parent.id, key, attrs, [])

  defp delete!(:tip, id),
    do: Repo.update_all(from(t in Tip, where: t.id == ^id), set: [deleted_at: now()])

  defp delete!(:review, id),
    do: Repo.update_all(from(r in Review, where: r.id == ^id), set: [deleted_at: now()])

  defp ban!(%User{id: id}),
    do: Repo.update_all(from(u in User, where: u.id == ^id), set: [ban: :full, banned_at: now()])

  defp mark_parent!(%Tip{id: id}, marker),
    do: Repo.update_all(from(t in Tip, where: t.id == ^id), set: [{marker, now()}])

  defp retire!(schema, id),
    do: Repo.update_all(from(c in schema, where: c.id == ^id), set: [active: false])

  defp lock_user(id),
    do: Repo.all(from(u in User, where: u.id == ^id, lock: "FOR NO KEY UPDATE", select: u.id))

  defp now, do: DateTime.utc_now(:second)

  # Reports each named constraint that rejects one of the racer's statements.
  defp watch_constraints(%{task: %{pid: pid}}) do
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(id, [:tips, :repo, :query], &__MODULE__.report_constraint/4, {pid, test})
    on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def report_constraint(_event, _measurements, metadata, {pid, test}) do
    with true <- self() == pid,
         {:error, %Postgrex.Error{postgres: %{constraint: constraint}}} <- metadata.result do
      send(test, {:constraint_rejected, constraint})
    end
  end

  defp assert_one_effect_set(:tip, data, key) do
    assert [%Tip{id: id, up_count: 1}] =
             Repo.all_by(Tip, user_id: data.author.id, submission_key: key)

    assert [%Vote{}] = Repo.all_by(Vote, tip_id: id)
    assert Repo.aggregate(from(s in "tip_search", where: s.tip_id == ^id), :count) == 1
  end

  defp assert_one_effect_set(:review, data, key) do
    assert [%Review{id: id, up_count: 1}] =
             Repo.all_by(Review, user_id: data.author.id, submission_key: key)

    assert [%Vote{}] = Repo.all_by(Vote, review_id: id)
    assert Repo.aggregate(from(s in "review_search", where: s.review_id == ^id), :count) == 1
    assert [%Notification{count: 1}] = Repo.all_by(Notification, review_id: id)
  end

  defp assert_no_effects(data) do
    assert Repo.all_by(Tip, user_id: data.author.id) == []
    assert Repo.all_by(Review, user_id: data.author.id) == []
    assert Repo.all_by(Vote, user_id: data.author.id) == []
    assert Repo.all_by(Notification, actor_id: data.author.id) == []
  end

  defp delete_content(user_ids) do
    tip_ids = Repo.all(from(t in Tip, where: t.user_id in ^user_ids, select: t.id))

    review_ids =
      Repo.all(
        from(r in Review, where: r.user_id in ^user_ids or r.tip_id in ^tip_ids, select: r.id)
      )

    Repo.delete_all(from(n in Notification, where: n.user_id in ^user_ids))
    Repo.delete_all(from(v in Vote, where: v.tip_id in ^tip_ids or v.review_id in ^review_ids))
    Repo.delete_all(from(s in "review_search", where: s.review_id in ^review_ids))
    Repo.delete_all(from(s in "tip_search", where: s.tip_id in ^tip_ids))
    Repo.delete_all(from(r in Review, where: r.id in ^review_ids))
    Repo.delete_all(from(t in Tip, where: t.id in ^tip_ids))
    Repo.delete_all(from(u in User, where: u.id in ^user_ids))
  end
end
