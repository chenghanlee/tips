defmodule TipsWeb.VoteTest do
  @moduledoc """
  Acceptance evidence for #110: browse, search, the tip page and the
  single-review view share one vote control and `TipsWeb.VoteActions`.
  Summaries show the net score, detail both counts, each from the confirmed
  response.

  The embedding provider answers 503, so search uses keyword ranking.
  """
  # Search's BM25 corpus statistics include other sandbox transactions.
  use TipsWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.SearchFixtures, only: [indexed_tip!: 2, stub_provider: 1]
  import Tips.VisibilityFixtures
  import TipsWeb.ReaderPageHelpers

  alias Tips.Accounts.{User, UserToken}
  alias Tips.Content.{Tip, Vote}
  alias Tips.Repo

  @moduletag :capture_log

  setup do
    stub_provider(fn conn, _input -> Plug.Conn.send_resp(conn, 503, "") end)
    author = user_fixture()
    # Hot order puts the voted tip second; a confirmed vote must not move it.
    tip = indexed_tip!(author, %{title: "Bisect the flaky test", tag_id: "workflow"})
    indexed_tip!(author, %{title: "Bisect the build", tag_id: "workflow", up_count: 5})
    first = review_fixture(tip, %{body: "First review", up_count: 1})
    review = review_fixture(tip, %{body: "Second review"})
    tip_path = "/tips/#{tip.id}/bisect-the-flaky-test"

    pages = [
      {"browse", "/", "#tip-#{tip.id}-vote", tip, :summary},
      {"search", "/search?q=bisect", "#tip-#{tip.id}-vote", tip, :summary},
      {"tip page, tip", tip_path, "#tip-vote", tip, :detail},
      {"tip page, review", tip_path, "#review-#{review.id}-vote", review, :detail},
      {"review page", "/reviews/#{review.id}", "#review-#{review.id}-vote", review, :detail}
    ]

    %{tip: tip, first: first, review: review, tip_path: tip_path, pages: pages}
  end

  test "each page sets the desired vote and shows only the confirmed row change", %{
    conn: conn,
    pages: pages
  } do
    voter = user_fixture()
    conn = log_in_user(conn, voter)

    for {page, path, control, target, layout} <- pages do
      {:ok, lv, html} = live(conn, path)
      order = row_order(html)
      assert pressed(html, control) == [], page

      # The click reply shows the request in flight.
      html = lv |> element("#{control}-helpful") |> render_click()
      assert text(html, "#{control} [role=status]") == "Saving…", page
      assert has?(html, "#{control}-not_helpful[aria-disabled=true]"), page

      html = render_async(lv)
      assert pressed(html, control) == ["Helpful"], page
      assert text(html, "#{control} [role=status]") == "", page
      assert count(html, control, target, layout) == {1, 0}, page
      assert stored_votes(voter) == [1], page
      assert row_order(html) == order, page

      # Clicking the selected choice asks for no vote; the other asks for it.
      lv |> element("#{control}-helpful") |> render_click()
      html = render_async(lv)
      assert pressed(html, control) == [], page
      assert count(html, control, target, layout) == {0, 0}, page
      assert stored_votes(voter) == [], page

      lv |> element("#{control}-not_helpful") |> render_click()
      html = render_async(lv)
      assert pressed(html, control) == ["Not helpful"], page
      assert count(html, control, target, layout) == {0, 1}, page
      assert stored_votes(voter) == [-1], page

      Repo.delete_all(where(Vote, user_id: ^voter.id))
    end

    # A later page load hydrates the viewer's vote on every page.
    for {_page, _path, _control, target, _layout} <- Enum.uniq_by(pages, &elem(&1, 3)) do
      vote_fixture(target, %{user_id: voter.id, value: 1})
    end

    for {page, path, control, _target, _layout} <- pages,
        {render, html, _title} <- renders(conn, path) do
      assert pressed(html, control) == ["Helpful"], "#{page} #{render}"
    end
  end

  test "a signed-out or expired-session click signs in and returns to the target without voting",
       %{conn: conn, pages: pages, tip_path: tip_path, review: review} do
    voter = user_fixture()
    review_path = "/reviews/#{review.id}"

    for {page, path, control, _target, _layout} <- pages,
        reader <- [nil, voter] do
      {:ok, lv, _html} = live(as(conn, reader), path)
      if reader, do: Repo.delete_all(where(UserToken, user_id: ^reader.id))

      return = if String.starts_with?(control, "#review"), do: review_path, else: tip_path

      assert {:error, {:redirect, %{to: to}}} =
               lv |> element("#{control}-helpful") |> render_click()

      assert to == "/users/log-in?" <> URI.encode_query(return_to: return), page
    end

    assert Repo.all(Vote) == []
  end

  test "an uncertain vote shows the current stored state before another change", %{
    conn: conn,
    tip: tip,
    tip_path: tip_path
  } do
    voter = user_fixture()
    {:ok, lv, _html} = live(log_in_user(conn, voter), tip_path)

    # The counter trigger overflows, so the vote's outcome is unknown.
    {1, _} = Repo.update_all(where(Tip, id: ^tip.id), set: [up_count: 2_147_483_647])
    lv |> element("#tip-vote-helpful") |> render_click()
    render_async(lv)
    html = render_async(lv)

    assert text(html, "#tip-vote [role=status]") ==
             "We couldn't confirm your vote. This shows its current state."

    assert pressed(html, "#tip-vote") == []
    assert text(html, "#tip-vote-helpful") == "Helpful 2147483647"
    assert stored_votes(voter) == []

    lv |> element("#tip-vote-not_helpful") |> render_click()
    html = render_async(lv)
    assert pressed(html, "#tip-vote") == ["Not helpful"]
    assert stored_votes(voter) == [-1]
  end

  test "a full ban removes vote actions and keeps the author's Delete; detail keeps both counts",
       %{conn: conn, pages: pages, tip: tip, review: review} do
    vote_fixture(tip, %{value: 1})
    vote_fixture(review, %{value: -1})
    author = Repo.get!(User, review.user_id)
    conn = log_in_user(conn, author)
    views = for {_, path, _, _, _} <- pages, do: elem(live(conn, path), 1)
    full_ban!(author)

    # A page opened before the ban reloads at its next vote click.
    clicked =
      for {{page, path, control, target, layout}, lv} <- Enum.zip(pages, views) do
        lv |> element("#{control}-helpful") |> render_click()

        assert {^path, %{"error" => "Your account can't vote."}} = assert_redirect(lv, 1_000),
               page

        {:ok, _lv, html} = live(conn, path)
        {"#{page} after a click", html, control, target, layout}
      end

    loaded =
      for {page, path, control, target, layout} <- pages,
          {render, html, _title} <- renders(conn, path),
          do: {"#{page} #{render}", html, control, target, layout}

    for {label, html, control, target, layout} <- clicked ++ loaded do
      refute has?(html, "#{control} button"), label
      refute has?(html, ~s([phx-click="vote"])), label
      refute has?(html, ~s(a[href="/editor/reviews/#{review.id}/edit"])), label

      if String.starts_with?(control, "#review"),
        do: assert(has?(html, "#review-#{review.id}-delete"), label)

      case layout do
        :summary -> assert count(html, control, target, :summary) == {1, 0}, label
        :detail -> assert count(html, control, target, :plain) == expected(target), label
      end
    end
  end

  defp expected(%Tip{}), do: {1, 0}
  defp expected(_review), do: {0, 1}

  defp pressed(html, control) do
    html
    |> find("#{control} button[aria-pressed=true]")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s*\d+$/, "")))
  end

  # Detail buttons carry their counts; a summary row carries the net score.
  defp count(html, control, _target, :detail) do
    {number(html, "#{control}-helpful"), number(html, "#{control}-not_helpful")}
  end

  defp count(html, _control, %Tip{id: id}, :summary) do
    ["Net " <> net] =
      html
      |> find("#tip-#{id} span")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
      |> Enum.filter(&String.starts_with?(&1, "Net "))

    net |> String.trim_leading("+") |> String.to_integer() |> net_counts()
  end

  defp count(html, control, _target, :plain) do
    [_, helpful, not_helpful] =
      Regex.run(~r/Helpful (\d+)\s*Not helpful (\d+)/, text(html, control))

    {String.to_integer(helpful), String.to_integer(not_helpful)}
  end

  defp net_counts(net) when net >= 0, do: {net, 0}
  defp net_counts(net), do: {0, -net}

  defp number(html, selector) do
    [_, n] = Regex.run(~r/(\d+)$/, text(html, selector))
    String.to_integer(n)
  end

  defp row_order(html) do
    html
    |> find("#tip-rows > li, #result-rows > li, #review-list > article")
    |> Enum.map(&LazyHTML.attribute(&1, "id"))
  end

  defp stored_votes(user),
    do: Repo.all(from(v in Vote, where: v.user_id == ^user.id, select: v.value))
end
