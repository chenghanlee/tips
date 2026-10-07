defmodule TipsWeb.InboxLiveTest do
  @moduledoc """
  Acceptance evidence for #101: `/inbox` pages notifications, and each
  connected visit marks the unread rows it captured once.
  """
  use TipsWeb.ConnCase, async: true

  # The inbox snapshot declares this level; the sandbox transaction must match.
  @moduletag isolation: "REPEATABLE READ"

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.ModerationFixtures
  import TipsWeb.ReaderPageHelpers

  alias Tips.Content.Notification
  alias Tips.Repo

  setup %{conn: conn} do
    recipient = user_fixture()
    %{conn: log_in_user(conn, recipient), recipient: recipient}
  end

  test "the disconnected render reads only; the first connected visit marks every captured row",
       %{conn: conn, recipient: recipient} do
    rows = unread!(recipient, 21)

    html = conn |> get(~p"/inbox") |> html_response(200)
    assert has?(html, "#notification-#{List.last(rows).id}")
    assert badge(html) == "21"
    assert unread_count(recipient) == 21

    {:ok, lv, html} = live(conn, ~p"/inbox")

    # Rows of the marking visit render unread from the snapshot; the twenty-first,
    # not loaded, is marked too, and the badge is cleared.
    assert text(html, "#notification-#{List.last(rows).id} [data-role=unread]") == "Unread"
    refute has?(html, "#notification-#{hd(rows).id}")
    assert unread_count(recipient) == 0
    assert badge(render(lv)) == nil

    # A later arrival stays unread through page changes in the same visit.
    later = notification_fixture(recipient)
    html = lv |> element("a[rel=next]") |> render_click()
    assert_patch(lv, ~p"/inbox?page=2")
    assert text(html, "#notification-#{hd(rows).id} [data-role=unread]") == ""
    lv |> element("a[rel=prev]") |> render_click()
    assert_patch(lv, ~p"/inbox")
    assert unread_count(recipient) == 1

    # A remount is a new visit and marks it.
    {:ok, _lv, html} = live(conn, ~p"/inbox")
    assert text(html, "#notification-#{later.id} [data-role=unread]") == "Unread"
    assert unread_count(recipient) == 0
  end

  test "a connected visit to a later page marks the rows of every page", %{
    conn: conn,
    recipient: recipient
  } do
    unread!(recipient, 21)

    for {render, html, title} <- renders(conn, ~p"/inbox?page=2") do
      assert title =~ "Inbox", render
      assert text(html, "[aria-current=page]") == "Page 2", render
      assert has?(html, "a[rel=prev]"), render
      refute has?(html, "a[rel=next]"), render
    end

    assert unread_count(recipient) == 0
  end

  test "rows describe recent activity without actor names or vote totals", %{
    conn: conn,
    recipient: recipient
  } do
    tip = tip_fixture(recipient, %{title: "Bisect first"})
    own_review = review_fixture(tip_fixture(user_fixture()), %{user_id: recipient.id})
    reviewer = user_fixture()
    review = review_fixture(tip, %{user_id: reviewer.id})

    tip_votes =
      notification_fixture(recipient, %{tip_id: tip.id, actor_id: reviewer.id, count: 7})

    review_votes =
      notification_fixture(recipient, %{
        type: :review_upvoted,
        review_id: own_review.id,
        actor_id: reviewer.id,
        count: 3
      })

    reviewed =
      notification_fixture(recipient, %{
        type: :tip_reviewed,
        review_id: review.id,
        actor_id: reviewer.id
      })

    {:ok, _lv, html} = live(conn, ~p"/inbox")

    assert text(html, "main") =~ "Recent activity on your tips and reviews"
    assert text(html, "main") =~ "Opening this page clears the unread badge"

    assert squished(html, "#notification-#{tip_votes.id} [data-role=message]") ==
             "Your tip got new helpful votes"

    assert attr(html, "#notification-#{tip_votes.id} a", "Bisect first", "href") ==
             "/tips/#{tip.id}/bisect-first"

    assert squished(html, "#notification-#{review_votes.id} [data-role=message]") ==
             "Your review got new helpful votes"

    assert attr(html, "#notification-#{review_votes.id} a", "Your review", "href") ==
             "/reviews/#{own_review.id}"

    assert squished(html, "#notification-#{reviewed.id} [data-role=message]") ==
             "#{reviewer.handle} reviewed your tip"

    assert attr(html, "#notification-#{reviewed.id} a", "Read the review", "href") ==
             "/reviews/#{review.id}"

    for row <- [tip_votes, review_votes] do
      row_text = text(html, "#notification-#{row.id}")
      refute row_text =~ reviewer.handle
      refute row_text =~ Integer.to_string(row.count)
    end
  end

  test "an empty inbox and an out-of-range page", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/inbox")
    assert text(html, "#notifications-empty") =~ "No notifications yet"

    {:ok, _lv, html} = live(conn, ~p"/inbox?page=3")
    assert text(html, "#notifications-empty") =~ "No notifications on page 3"
    assert attr(html, "nav[aria-label=Pages] a", "First page", "href") == "/inbox"
  end

  test "the header bell links to the inbox with a capped badge", %{
    conn: conn,
    recipient: recipient
  } do
    unread!(recipient, 3)
    {:ok, _lv, html} = live(conn, ~p"/")
    assert find(html, "#inbox-link") |> LazyHTML.attribute("href") == ["/inbox"]
    assert find(html, "#inbox-link") |> LazyHTML.attribute("aria-label") == ["Inbox, 3 unread"]
    assert badge(html) == "3"

    unread!(recipient, 97)
    assert conn |> get(~p"/") |> html_response(200) |> badge() == "99+"

    {:ok, _lv, html} = live(build_conn(), ~p"/")
    refute has?(html, "#inbox-link")
  end

  test "signed-out readers are sent to log in" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/inbox")
  end

  defp unread!(recipient, n) do
    author = user_fixture()
    start = DateTime.add(DateTime.utc_now(:second), -86_400)

    # Oldest first, so the last row is the newest.
    for i <- 1..n do
      notification_fixture(recipient, %{
        tip_id: tip_fixture(author).id,
        updated_at: DateTime.add(start, i * 60)
      })
    end
  end

  defp unread_count(user) do
    Repo.aggregate(
      from(n in Notification, where: n.user_id == ^user.id and is_nil(n.read_at)),
      :count
    )
  end

  defp badge(html) do
    case find(html, "#inbox-badge") |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim())) do
      [] -> nil
      [count] -> count
    end
  end

  defp squished(html, selector), do: html |> text(selector) |> String.split() |> Enum.join(" ")
end
