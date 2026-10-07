defmodule TipsWeb.VoteBanRaceTest do
  @moduledoc """
  A full ban that commits after a vote click's admission, before its guarded
  write (#110). The ban must hold its account lock in a concurrent
  transaction, which the SQL sandbox cannot interleave, so this test commits
  its rows and deletes them on exit.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Tips.AccountsFixtures, only: [user_fixture: 0]
  import Tips.FeatureHelpers, only: [await_found: 1]
  import Tips.SearchFixtures, only: [indexed_tip!: 2, stub_provider: 1]
  import Tips.VisibilityFixtures, only: [full_ban!: 1]
  import TipsWeb.ConnCase, only: [log_in_user: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Tips.Accounts.{User, UserToken}
  alias Tips.Content.Tip
  alias Tips.Repo

  @endpoint TipsWeb.Endpoint
  @moduletag :capture_log

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    Sandbox.mode(Repo, {:shared, self()})
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
  end

  test "search results that load across the refusal show no vote actions" do
    voter = user_fixture()
    author = user_fixture()
    tip = indexed_tip!(author, %{title: "Build flake"})

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(s in "tip_search", where: s.tip_id == ^tip.id))
        Repo.delete_all(where(Tip, id: ^tip.id))
        Repo.delete_all(from(t in UserToken, where: t.user_id in ^[voter.id, author.id]))
        Repo.delete_all(from(u in User, where: u.id in ^[voter.id, author.id]))
      end)
    end)

    test = self()
    {:ok, hold} = Agent.start_link(fn -> true end)

    stub_provider(fn conn, input ->
      if input =~ "flake" and Agent.get_and_update(hold, &{&1, false}) do
        send(test, {:searching, self()})
        receive do: (:answer -> :ok)
      end

      Plug.Conn.send_resp(conn, 503, "")
    end)

    {:ok, lv, _html} = live(log_in_user(build_conn(), voter), "/search?q=build")
    render_submit(lv, "search", %{"q" => "flake"})
    assert_receive {:searching, provider}

    banning =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transact(fn ->
            Repo.one!(from(u in User, where: u.id == ^voter.id, lock: "FOR NO KEY UPDATE"))
            |> full_ban!()

            send(test, {:ban_locked, self()})
            receive do: (:commit -> {:ok, :banned})
          end)
        end)
      end)

    assert_receive {:ban_locked, ban}
    # Admission reads the committed eligible account; the guarded write waits
    # for the ban's lock and then refuses.
    render_click(lv, "vote", %{"target" => "tip-#{tip.id}", "vote" => "helpful"})
    send(ban, :commit)
    assert {:ok, :banned} = Task.await(banning)
    await_found(fn -> if has_element?(lv, "#flash-error", "can't vote"), do: true end)

    send(provider, :answer)
    render_async(lv, 1_000)
    assert has_element?(lv, "#tip-#{tip.id}")
    refute has_element?(lv, ~s([phx-click="vote"]))
  end
end
