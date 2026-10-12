defmodule TipsWeb.ReviewLive.ShowTest do
  @moduledoc """
  Acceptance evidence for #77: `/reviews/:id` renders the #76 selected-review
  projection with its tip context, the same on the disconnected and first
  connected render.
  """
  use TipsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.ModerationFixtures
  import Tips.VisibilityFixtures
  import TipsWeb.ReaderPageHelpers

  @title "Ask for a written plan before a large refactor"
  @tip_path_suffix "ask-for-a-written-plan-before-a-large-refactor"

  test "selected review renders tip context, that review only, disclosure open and Show all reviews",
       %{conn: conn} do
    tip = tip_fixture(user_fixture(), %{title: @title})
    reviewer = user_fixture()

    review =
      review_fixture(tip, %{
        user_id: reviewer.id,
        body: "It **worked** on a 14-module rename.",
        prompt: "After each step,\n  run its test.",
        output: "10 tests, 0 failures",
        model_id: "gpt",
        environment_id: "ide"
      })

    vote_fixture(review, %{value: 1})
    review_fixture(tip, %{body: "Competitor body"})
    tip_path = "/tips/#{TipsWeb.TipId.encode(tip.id)}/#{@tip_path_suffix}"

    for {render, html, title} <- renders(conn, "/reviews/#{review.id}") do
      assert attr(html, "h1 a", @title, "href") == tip_path, render
      assert title =~ @title, render

      card = "#review-#{review.id}"
      assert text(html, card) =~ reviewer.handle, render
      assert attr(html, "#{card} a", reviewer.handle, "href") == "#review-#{review.id}", render
      assert text(html, card) =~ "Published", render
      assert has?(html, "#{card} strong"), render

      assert verbatim(html, "#{card} details[open] #review-#{review.id}-prompt pre") ==
               review.prompt

      assert verbatim(html, "#{card} details[open] #review-#{review.id}-result pre") ==
               review.output

      assert text(html, card) =~ "GPT", render
      assert text(html, card) =~ "IDE", render
      refute html =~ "/?model=gpt", render
      assert text(html, card) =~ "Helpful 1", render

      refute html =~ "Competitor body", render
      refute has?(html, "select"), render
      refute has?(html, "nav[aria-label=Pages]"), render
      assert attr(html, "a", "Show all reviews", "href") == tip_path, render
    end

    # List parameters do not change the selected review; Show all keeps only the sort.
    path = "/reviews/#{review.id}?sort=new&model=gpt&environment=ide&page=2"

    for {render, html, _title} <- renders(conn, path) do
      assert has?(html, "#review-#{review.id} details[open]"), render
      refute html =~ "Competitor body", render
      refute has?(html, "select"), render
      refute has?(html, "nav[aria-label=Pages]"), render
      assert attr(html, "a", "Show all reviews", "href") == tip_path <> "?sort=new", render
    end
  end

  test "review stays readable under hidden and deleted tips, with the placeholder as context",
       %{conn: conn} do
    for {marker, {placeholder, slug}} <- [
          hidden: {"Removed tip", "removed-tip"},
          deleted: {"Deleted tip", "deleted-tip"}
        ] do
      tip = tip_fixture(user_fixture(), %{title: "Secret plan title", body: "Secret body"})
      review = review_fixture(tip, %{body: "Readable review body"})
      put_marker!(tip, marker)
      tip_path = "/tips/#{TipsWeb.TipId.encode(tip.id)}/#{slug}"

      for viewer <- [nil, user_fixture()],
          {render, html, title} <- renders(as(conn, viewer), "/reviews/#{review.id}") do
        label = inspect({marker, render, viewer && viewer.id})

        assert text(html, "#review-#{review.id}") =~ "Readable review body", label
        assert attr(html, "h1 a", placeholder, "href") == tip_path, label
        assert title =~ placeholder, label
        assert attr(html, "a", "Show all reviews", "href") == tip_path, label
        refute html =~ "Secret", label
        refute title =~ "Secret", label
      end
    end
  end

  test "deleted and moderator-removed reviews show the supplied reason and no other review",
       %{conn: conn} do
    tip = tip_fixture(user_fixture(), %{title: @title})
    review_fixture(tip, %{body: "Competitor body"})
    tip_path = "/tips/#{TipsWeb.TipId.encode(tip.id)}/#{@tip_path_suffix}"

    for {marker, line} <- [
          deleted: "Review deleted by author",
          hidden: "Review removed by moderators",
          deleted_and_hidden: "Review deleted by author"
        ] do
      review = review_fixture(tip, %{body: "Gone review body", prompt: "Gone prompt"})
      put_marker!(review, marker)

      for viewer <- [nil, user_fixture()],
          {render, html, title} <- renders(as(conn, viewer), "/reviews/#{review.id}") do
        label = inspect({marker, render, viewer && viewer.id})

        assert text(html, "#review-unavailable") =~ line, label

        assert attr(html, "#review-unavailable a", "Show all reviews", "href") ==
                 tip_path,
               label

        assert attr(html, "h1 a", @title, "href") == tip_path, label
        assert title =~ @title, label
        refute html =~ "Gone review body", label
        refute html =~ "Gone prompt", label
        refute html =~ "Competitor body", label
      end
    end
  end

  test "author sees own hidden review with the generic notice and Edit when permitted",
       %{conn: conn} do
    tip = tip_fixture(user_fixture(), %{title: @title})
    author = user_fixture()
    review = review_fixture(tip, %{user_id: author.id, body: "Own hidden body"})

    flag_fixture(user_fixture(%{handle: "reporter#{System.unique_integer([:positive])}"}), %{
      review_id: review.id,
      reason: :spam,
      detail: "Reporter detail text"
    })

    put_marker!(review, :hidden)
    notice = "#review-#{review.id}-removed-notice"

    for {render, html, _title} <- renders(as(conn, author), "/reviews/#{review.id}") do
      assert text(html, "#review-#{review.id}") =~ "Own hidden body", render
      assert text(html, notice) =~ "Removed by moderation", render
      assert text(html, notice) =~ "saving changes does not restore visibility", render

      assert attr(html, "#review-#{review.id} a", "Edit", "href") ==
               "/editor/reviews/#{review.id}/edit",
             render

      refute html =~ "Reporter detail text", render
      refute html =~ "reporter", render
      refute html =~ "spam", render
    end

    for {render, html, _title} <- renders(as(conn, user_fixture()), "/reviews/#{review.id}") do
      assert text(html, "#review-unavailable") =~ "Review removed by moderators"
      refute html =~ "Own hidden body", render
    end

    full_ban!(author)

    for {render, html, _title} <- renders(as(conn, author), "/reviews/#{review.id}") do
      assert text(html, notice) =~ "Removed by moderation", render
      refute html =~ "/editor/reviews/#{review.id}/edit", render
      assert has?(html, "#review-#{review.id}-delete"), render
    end
  end

  test "Delete asks once, then shows the review as deleted by its author", %{conn: conn} do
    tip = tip_fixture(user_fixture(), %{title: @title})
    author = user_fixture()
    review = review_fixture(tip, %{user_id: author.id, body: "Own review body"})
    {:ok, lv, _html} = live(as(conn, author), "/reviews/#{review.id}")

    lv |> element("#review-#{review.id}-delete") |> render_click()
    assert lv |> render() |> text("#review-#{review.id}-delete-confirm") =~ "can't be undone"

    lv |> element("#review-#{review.id}-delete-confirm button", "Cancel") |> render_click()
    refute has_element?(lv, "#review-#{review.id}-delete-confirm")
    assert Tips.Repo.reload!(review).deleted_at == nil

    lv |> element("#review-#{review.id}-delete") |> render_click()

    {:ok, lv, html} =
      lv
      |> element("#review-#{review.id}-delete-confirm button", "Delete review")
      |> render_click()
      |> follow_redirect(as(conn, author), "/reviews/#{review.id}")

    assert text(html, "#review-unavailable") =~ "Review deleted by author"
    assert lv |> render() |> text("#flash-info") =~ "Review deleted."
    refute html =~ "Own review body"
  end

  test "a review with attachments is not deleted and says why", %{conn: conn} do
    author = user_fixture()
    review = review_fixture(tip_fixture(), %{user_id: author.id})
    Tips.MediaFixtures.image_fixture(review)
    {:ok, lv, _html} = live(as(conn, author), "/reviews/#{review.id}")

    lv |> element("#review-#{review.id}-delete") |> render_click()

    html =
      lv
      |> element("#review-#{review.id}-delete-confirm button", "Delete review")
      |> render_click()

    assert text(html, "#flash-error") =~ "with attachments can't be deleted yet"
    assert has_element?(lv, "#review-#{review.id}")
    assert Tips.Repo.reload!(review).deleted_at == nil
  end

  test "unknown and malformed review ids are not found, with no tip context", %{conn: conn} do
    tip = tip_fixture(user_fixture(), %{title: @title})
    missing = review_fixture(tip).id + 1_000_000

    for id <- [missing, "abc", "0", "-1", "1.5", "99999999999999999999"],
        conn <- [conn, log_in_user(conn, user_fixture())] do
      {404, _headers, body} = assert_error_sent 404, fn -> get(conn, "/reviews/#{id}") end
      refute body =~ @title
      assert_error_sent 404, fn -> live(conn, "/reviews/#{id}") end
    end
  end
end
