defmodule TipsWeb.VoteFeatureTest do
  @moduledoc """
  Real-browser tests of vote results that arrive late or never (#110). The
  server answers at once; the test holds or drops the frames it sends, as a slow
  or lost connection would.
  """
  use Tips.FeatureCase, async: true

  import Ecto.Query
  import Tips.AccountsFixtures, only: [user_fixture: 0]
  import Tips.ContentFixtures, only: [tip_fixture: 2]

  alias Tips.Content.Vote
  alias Tips.Repo

  @moduletag :browser

  setup %{session: session} do
    tip = tip_fixture(user_fixture(), %{title: "Plan first"})
    voter = user_fixture()
    sign_in(session, voter)
    %{voter: voter, path: "/tips/#{TipsWeb.TipId.encode(tip.id)}/plan-first"}
  end

  feature "a newer choice made while an older result is delayed is the one that stays",
          %{session: session, voter: voter, path: path} do
    session
    |> visit(path)
    |> assert_has(css(".phx-connected"))

    hold_frames(session)
    click(session, css("#tip-vote-helpful"))
    # The server has sent the Helpful result; the page has not shown it.
    await_held(session, "diff")

    session
    |> assert_has(css("#tip-vote-helpful[aria-pressed=false]", text: "Helpful 0"))
    |> click(css("#tip-vote-not_helpful"))

    release_frames(session)

    session
    |> assert_has(css("#tip-vote-not_helpful[aria-pressed=true]", text: "Not helpful 1"))
    |> assert_has(css("#tip-vote-helpful[aria-pressed=false]", text: "Helpful 0"))

    assert votes(voter) == [-1]
  end

  feature "a lost result shows the stored vote after the reconnect, and a newer choice replaces it",
          %{session: session, voter: voter, path: path} do
    session
    |> visit(path)
    |> assert_has(css(".phx-connected"))

    drop_frames(session, ["phx_reply", "diff"])
    click(session, css("#tip-vote-helpful"))
    await_found(fn -> votes(voter) |> List.first() end)
    reconnect_live(session)

    session
    |> assert_has(css("#tip-vote-helpful[aria-pressed=true]", text: "Helpful 1"))
    |> click(css("#tip-vote-not_helpful"))
    |> assert_has(css("#tip-vote-not_helpful[aria-pressed=true]", text: "Not helpful 1"))
    |> assert_has(css("#tip-vote-helpful[aria-pressed=false]", text: "Helpful 0"))

    assert votes(voter) == [-1]
  end

  defp votes(user), do: Repo.all(from(v in Vote, where: v.user_id == ^user.id, select: v.value))
end
