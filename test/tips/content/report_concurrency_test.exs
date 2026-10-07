defmodule Tips.Content.ReportConcurrencyTest do
  # Committed transactions on separate backends. A report locks the reporter,
  # then only its direct target `FOR SHARE`, which author deletion's row lock
  # waits for or makes the report wait for.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.LockSessions
  import Tips.ModerationFixtures

  alias Tips.Accounts.{Scope, User}
  alias Tips.Content
  alias Tips.Content.{Flag, Review, Tip}
  alias Tips.Repo

  setup do
    data =
      unboxed(fn ->
        # One transaction, so a failed setup leaves no committed rows behind.
        {:ok, data} =
          Repo.transaction(fn ->
            author = user_fixture()
            tip = tip_fixture(author)

            review =
              Repo.insert!(%Review{
                tip_id: tip.id,
                user_id: author.id,
                submission_key: Ecto.UUID.generate(),
                body: "The technique helped in this synthetic test."
              })

            %{author: author, reporter: user_fixture(), tip: tip, review: review}
          end)

        data
      end)

    on_exit(fn -> unboxed(fn -> purge(data) end) end)
    Map.put(data, :supervisor, start_supervised!(Task.Supervisor))
  end

  for kind <- [:tip, :review] do
    test "a #{kind} report committed first is resolved by the waiting deletion", data do
      kind = unquote(kind)

      holder = open(data.supervisor)
      assert {:ok, %{outcome: :stored, report_id: id}} = run(holder, fn -> report(data, kind) end)

      call = call(data.supervisor, fn -> delete(data, kind) end)
      await_blocked(call, holder)
      commit(holder)

      assert {:ok, %{state: :deleted, outcome: :changed}} = finish(call)

      unboxed(fn ->
        assert %Flag{resolved_at: %DateTime{}, resolved_by: nil} = Repo.get!(Flag, id)
      end)
    end

    test "a #{kind} report waiting on a committed deletion is rejected", data do
      kind = unquote(kind)

      holder = open(data.supervisor)
      assert {:ok, %{state: :deleted}} = run(holder, fn -> delete(data, kind) end)

      call = call(data.supervisor, fn -> report(data, kind) end)
      await_blocked(call, holder)
      commit(holder)

      assert finish(call) == {:error, :not_found}
      unboxed(fn -> assert flags(data) == [] end)
    end
  end

  test "a review report does not wait for its parent tip", data do
    holder = open(data.supervisor)

    assert [_id] =
             run(holder, fn ->
               Repo.all(
                 from(t in Tip, where: t.id == ^data.tip.id, lock: "FOR UPDATE", select: t.id)
               )
             end)

    assert {:ok, %{outcome: :stored}} =
             finish(call(data.supervisor, fn -> report(data, :review) end))

    commit(holder)
  end

  test "a duplicate waiting on the first report returns that report's receipt", data do
    holder = open(data.supervisor)

    assert {:ok, %{outcome: :stored, report_id: id}} =
             run(holder, fn -> report(data, :tip, "The first explanation.") end)

    call = call(data.supervisor, fn -> report(data, :tip, "A second explanation.") end)
    await_blocked(call, holder)
    commit(holder)

    assert {:ok, %{outcome: :already_open, report_id: ^id}} = finish(call)

    unboxed(fn ->
      assert [%Flag{id: ^id, detail: "The first explanation."}] = flags(data)
    end)
  end

  test "a resolution racing the receipt read is uncertain and stores nothing", data do
    open = unboxed(fn -> flag_fixture(data.reporter, tip_id: data.tip.id) end)

    # A moderator's resolution has locked the open report but not yet written it.
    holder = open(data.supervisor)
    run(holder, fn -> lock_flag(open.id) end)

    call = call(data.supervisor, fn -> report(data, :tip, "Submitted again.") end)
    await_blocked(call, holder)

    run(holder, fn ->
      Repo.update_all(where(Flag, id: ^open.id), set: [resolved_at: DateTime.utc_now(:second)])
    end)

    commit(holder)

    assert finish(call) == {:error, :outcome_unknown}

    unboxed(fn ->
      assert [%Flag{id: id, resolved_at: %DateTime{}}] = flags(data)
      assert id == open.id
    end)
  end

  defp report(data, kind, detail \\ nil),
    do:
      Content.report_content(
        Scope.for_user(data.reporter),
        kind,
        Map.fetch!(data, kind).id,
        %{reason: :harmful, detail: detail}
      )

  defp delete(data, kind),
    do: Content.delete_content(Scope.for_user(data.author), kind, Map.fetch!(data, kind).id)

  defp lock_flag(id),
    do: Repo.all(from(f in Flag, where: f.id == ^id, lock: "FOR NO KEY UPDATE", select: f.id))

  defp flags(data),
    do:
      Repo.all(
        from(f in Flag,
          where: f.tip_id == ^data.tip.id or f.review_id == ^data.review.id,
          order_by: f.id
        )
      )

  defp purge(data) do
    user_ids = [data.author.id, data.reporter.id]

    Repo.delete_all(
      from(f in Flag, where: f.tip_id == ^data.tip.id or f.review_id == ^data.review.id)
    )

    Repo.delete_all(from(s in "review_search", where: s.review_id == ^data.review.id))
    Repo.delete_all(from(s in "tip_search", where: s.tip_id == ^data.tip.id))
    Repo.delete_all(from(r in Review, where: r.id == ^data.review.id))
    Repo.delete_all(from(t in Tip, where: t.id == ^data.tip.id))
    Repo.delete_all(from(u in User, where: u.id in ^user_ids))
  end
end
