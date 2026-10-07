defmodule TipsWeb.TipLive.ShowTest do
  @moduledoc """
  Acceptance evidence for #77: `/tips/:id/:slug` renders the #76 tip projection
  as readable HTML, the same on the disconnected and first connected render.
  """
  use TipsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.ModerationFixtures
  import Tips.VisibilityFixtures
  import TipsWeb.ReaderPageHelpers

  @title "Ask for a written plan before a large refactor"
  @slug "ask-for-a-written-plan-before-a-large-refactor"

  describe "readable tip" do
    test "live tip renders title, Markdown body, verbatim prompt and result, setup, author and counts",
         %{conn: conn} do
      author = user_fixture()

      tip =
        tip_fixture(author, %{
          title: @title,
          body: "Steps:\n\n1. **Ask** for a plan\n2. Read it <script>alert(1)</script>",
          prompt: "  Before you edit,\n    write a <b>plan</b>.\n",
          output: "1. lib/a.ex\n\ttest: a_test.exs",
          model_id: "claude",
          environment_id: "cli",
          edited_at: DateTime.add(DateTime.utc_now(:second), 60)
        })

      vote_fixture(tip, %{value: 1})
      vote_fixture(tip, %{value: 1})
      vote_fixture(tip, %{value: -1})

      for {render, html, title} <- renders(conn, tip_path(tip)) do
        assert text(html, "h1") == @title, render
        assert title =~ @title, render

        assert has?(html, "#tip-body ol li strong"), render
        refute html =~ "<script>alert", render
        assert verbatim(html, "#tip-prompt pre") == tip.prompt, render
        assert verbatim(html, "#tip-result pre") == tip.output, render
        assert html =~ "write a &lt;b&gt;plan&lt;/b&gt;", render
        assert text(html, "#tip-prompt figcaption") == "Prompt", render
        assert text(html, "#tip-result figcaption") == "Result", render
        refute html =~ "Copy prompt", render

        assert attr(html, "#tip-header a", "Other technique", "href") == "/?technique=other"
        assert attr(html, "#tip-header a", "Claude", "href") == "/?model=claude"
        assert attr(html, "#tip-header a", "CLI", "href") == "/?environment=cli"
        assert text(html, "#tip-header") =~ author.handle, render
        assert text(html, "#tip-header") =~ "Published", render
        assert text(html, "#tip-header") =~ "Updated", render

        assert text(html, "#tip-vote") =~ "Helpful 2", render
        assert text(html, "#tip-vote") =~ "Not helpful 1", render
      end
    end

    test "wrong or stale slug redirects to the projected slug", %{conn: conn} do
      tip = tip_fixture(user_fixture(), %{title: "Old title"})
      stale = "/tips/#{tip.id}/old-title"

      tip = tip |> Ecto.Changeset.change(title: @title) |> Tips.Repo.update!()
      expected = "/tips/#{tip.id}/#{@slug}"

      for path <- [stale, "/tips/#{tip.id}/wrong", "/tips/#{tip.id}/deleted-tip"] do
        assert_redirects_to(conn, path, expected)
      end

      deleted = put_marker!(tip, :deleted)
      assert_redirects_to(conn, expected, "/tips/#{deleted.id}/deleted-tip")

      hidden = put_marker!(tip_fixture(user_fixture(), %{title: @title}), :hidden)
      assert_redirects_to(conn, "/tips/#{hidden.id}/#{@slug}", "/tips/#{hidden.id}/removed-tip")
    end
  end

  describe "unavailable tip" do
    test "deleted tip shows the placeholder to every viewer; original title is absent from body, page title, slug and links",
         %{conn: conn} do
      author = user_fixture()
      tip = secret_tip(author)
      put_marker!(tip, :deleted)

      for viewer <- [nil, user_fixture(), author, moderator!(user_fixture())],
          {render, html, title} <- renders(as(conn, viewer), "/tips/#{tip.id}/deleted-tip") do
        label = {render, viewer && viewer.id}

        assert text(html, "h1") == "Deleted tip", inspect(label)
        assert title =~ "Deleted tip", inspect(label)
        refute_secret(html, author, label)
        refute title =~ "Secret", inspect(label)
        refute has?(html, "#tip-body"), inspect(label)
        refute has?(html, "#tip-vote"), inspect(label)
      end
    end

    test "hidden tip shows the removed placeholder to readers and the content with a generic notice to its author",
         %{conn: conn} do
      author = user_fixture()
      tip = secret_tip(author)

      flag_fixture(user_fixture(%{handle: "reporter#{System.unique_integer([:positive])}"}), %{
        tip_id: tip.id,
        reason: :harmful,
        detail: "Reporter detail text"
      })

      put_marker!(tip, :hidden)

      for viewer <- [nil, user_fixture()],
          {render, html, title} <- renders(as(conn, viewer), "/tips/#{tip.id}/removed-tip") do
        label = {render, viewer && viewer.id}

        assert text(html, "h1") == "Removed tip", inspect(label)
        assert title =~ "Removed tip", inspect(label)
        refute_secret(html, author, label)
        refute html =~ "Removed by moderation", inspect(label)
      end

      author_path = "/tips/#{tip.id}/secret-plan-title"

      for {render, html, title} <- renders(as(conn, author), author_path) do
        assert text(html, "h1") == "Secret plan title", render
        assert title =~ "Secret plan title", render
        assert text(html, "#tip-body") =~ "Secret body", render

        notice = text(html, "#tip-removed-notice")
        assert notice =~ "Removed by moderation", render
        assert notice =~ "saving changes does not restore visibility", render

        assert attr(html, "#tip-header a", "Edit", "href") ==
                 "/editor/tips/#{tip.id}/edit"

        refute html =~ "Reporter detail text", render
        refute html =~ "reporter", render
        refute html =~ "harmful", render
      end
    end
  end

  describe "contribution control" do
    test "contribution control: own review, write, sign in, not accepting, none", %{conn: conn} do
      tip = tip_fixture(user_fixture(), %{title: @title})
      reviewer = user_fixture()
      review = review_fixture(tip, %{user_id: reviewer.id})
      path = tip_path(tip)

      for {render, html, _title} <- renders(as(conn, reviewer), path) do
        assert attr(html, "#contribution-control a", "Your review", "href") ==
                 "/reviews/#{review.id}",
               render
      end

      for {render, html, _title} <- renders(as(conn, user_fixture()), path) do
        assert attr(html, "#contribution-control a", "Tried this? Write a review", "href") ==
                 "/editor/tips/#{tip.id}/reviews/new",
               render
      end

      for {render, html, _title} <- renders(conn, path) do
        assert attr(html, "#contribution-control a", "Sign in to review", "href") ==
                 "/users/log-in?" <> URI.encode_query(return_to: path),
               render
      end

      for {render, html, _title} <- renders(as(conn, full_ban!(user_fixture())), path) do
        refute has?(html, "#contribution-control"), render
      end

      for marker <- [:hidden, :deleted] do
        tip = put_marker!(tip, marker)
        path = "/tips/#{tip.id}/#{placeholder_slug(marker)}"

        for viewer <- [nil, user_fixture()],
            {render, html, _title} <- renders(as(conn, viewer), path) do
          label = inspect({marker, render, viewer && viewer.id})

          assert has?(html, "#contribution-control button[disabled]"), label

          assert text(html, "#contribution-control") =~ "This tip is not accepting reviews.",
                 label

          refute has?(html, "#contribution-control a"), label
        end

        for {render, html, _title} <- renders(as(conn, reviewer), path) do
          assert attr(html, "#contribution-control a", "Your review", "href") ==
                   "/reviews/#{review.id}",
                 inspect({marker, render})
        end
      end
    end

    test "fully banned owner reaches Your review under hidden and deleted tips", %{conn: conn} do
      owner = user_fixture()

      for marker <- [:hidden, :deleted] do
        tip = tip_fixture(user_fixture(), %{title: "Secret plan title"})
        review = review_fixture(tip, %{user_id: owner.id, body: "My own **review** body"})
        put_marker!(review, :hidden)
        put_marker!(tip, marker)
        full_ban!(owner)
        conn = as(conn, owner)

        for {render, html, _title} <-
              renders(conn, "/tips/#{tip.id}/#{placeholder_slug(marker)}") do
          assert attr(html, "#contribution-control a", "Your review", "href") ==
                   "/reviews/#{review.id}",
                 inspect({marker, render})
        end

        for {render, html, _title} <- renders(conn, "/reviews/#{review.id}") do
          label = inspect({marker, render})
          assert text(html, "#review-#{review.id}") =~ "My own review body", label

          assert text(html, "#review-#{review.id}-removed-notice") =~ "Removed by moderation",
                 label

          refute html =~ "/editor/reviews/#{review.id}/edit", label
          refute html =~ "Secret plan title", label
        end
      end
    end
  end

  describe "review list" do
    test "a thirty-review page renders each review in full and pages through the URL",
         %{conn: conn} do
      tip = tip_fixture(user_fixture(), %{title: @title})
      start = DateTime.add(DateTime.utc_now(:second), -1000)

      reviews =
        for n <- 1..31 do
          review_fixture(tip, %{
            up_count: n,
            body: "Review **#{n}** body",
            prompt: "Prompt #{n}",
            output: "Result #{n}",
            model_id: "claude",
            environment_id: "cli",
            created_at: DateTime.add(start, n),
            edited_at: if(n == 31, do: DateTime.add(start, 500))
          })
        end

      [first | _rest] = best = Enum.reverse(reviews)
      path = tip_path(tip)

      for {render, html, _title} <- renders(conn, path) do
        cards = find(html, "#review-list > article")
        assert Enum.count(cards) == 30, render
        assert ids(cards) == best |> Enum.take(30) |> Enum.map(& &1.id), render

        card = "#review-#{first.id}"
        assert text(html, "#{card} strong") == "31", render
        assert text(html, card) =~ "Published", render
        assert text(html, card) =~ "Updated", render
        assert text(html, card) =~ ~r/Reviewer setup:\s*Claude\s*CLI/, render
        assert text(html, card) =~ "Helpful 31", render

        assert verbatim(html, "#{card} details:not([open]) #review-#{first.id}-prompt pre") =~
                 "Prompt 31",
               render

        assert attr(html, "#{card} h2 a", first |> author_handle(), "href") ==
                 "/reviews/#{first.id}",
               render

        assert attr(html, "nav[aria-label=Pages] a", "Next", "href") == path <> "?page=2", render
        refute has?(html, "nav[aria-label=Pages] a[rel=prev]"), render
      end

      for {render, html, _title} <- renders(conn, path <> "?page=2") do
        assert ids(find(html, "#review-list > article")) == [hd(reviews).id], render
        assert attr(html, "nav[aria-label=Pages] a", "Previous", "href") == path, render
        refute has?(html, "nav[aria-label=Pages] a[rel=next]"), render
      end

      for {render, html, _title} <- renders(conn, path <> "?page=3") do
        assert text(html, "#reviews-empty") == "No reviews on page 3.", render
        assert attr(html, "nav[aria-label=Pages] a", "First page", "href") == path, render
      end
    end

    test "sort and setup filters patch the URL on page one; All includes unspecified setups",
         %{conn: conn} do
      tip = tip_fixture(user_fixture(), %{title: @title})
      old = DateTime.add(DateTime.utc_now(:second), -100)
      claude = review_fixture(tip, %{model_id: "claude", up_count: 5, created_at: old})
      unspecified = review_fixture(tip, %{model_other: "claude"})
      path = tip_path(tip)

      {:ok, lv, html} = live(conn, path <> "?page=2")
      assert text(html, "#review-filters") =~ "reviews reporting this setup"

      lv |> form("#review-filters", %{sort: "new"}) |> render_change()
      assert_patch(lv, path <> "?sort=new")

      assert lv |> render() |> find("#review-list > article") |> ids() == [
               unspecified.id,
               claude.id
             ]

      lv |> form("#review-filters", %{sort: "new", model: "claude"}) |> render_change()
      assert_patch(lv, path <> "?sort=new&model=claude")
      assert lv |> render() |> find("#review-list > article") |> ids() == [claude.id]

      lv
      |> form("#review-filters", %{sort: "new", model: "claude", environment: "cli"})
      |> render_change()

      assert_patch(lv, path <> "?sort=new&model=claude&environment=cli")
      assert lv |> render() |> text("#reviews-empty") == "No reviews match these filters"

      lv |> element("#review-filters a", "Clear filters") |> render_click()
      assert_patch(lv, path <> "?sort=new")

      assert lv |> render() |> find("#review-list > article") |> ids() == [
               unspecified.id,
               claude.id
             ]

      # A review link keeps the sort for Show all reviews.
      assert attr(render(lv), "#review-#{claude.id} h2 a", author_handle(claude), "href") ==
               "/reviews/#{claude.id}?sort=new"
    end

    test "the earlier-review note appears only for a readable review older than the tip edit",
         %{conn: conn} do
      edited_at = DateTime.utc_now(:second)
      tip = tip_fixture(user_fixture(), %{title: @title, edited_at: edited_at})
      later = review_fixture(tip, %{created_at: DateTime.add(edited_at, 60)})
      note = "This tip has been updated; earlier reviews may describe an earlier version."

      for {render, html, _title} <- renders(conn, tip_path(tip)) do
        refute has?(html, "#earlier-reviews-note"), render
      end

      earlier = review_fixture(tip, %{created_at: DateTime.add(edited_at, -60)})
      earlier = put_marker!(earlier, :hidden)

      for {render, html, _title} <- renders(conn, tip_path(tip)) do
        refute has?(html, "#earlier-reviews-note"), render
      end

      put_marker!(earlier, :live)

      for {render, html, _title} <- renders(conn, tip_path(tip)) do
        assert text(html, "#earlier-reviews-note") == note, render
        assert has?(html, "#review-#{later.id}"), render
      end

      put_marker!(tip, :hidden)

      for {render, html, _title} <- renders(conn, "/tips/#{tip.id}/removed-tip") do
        refute has?(html, "#earlier-reviews-note"), render
        assert has?(html, "#review-#{earlier.id}"), render
      end
    end

    test "own review keeps its rank with a badge and the same Edit and Delete actions",
         %{conn: conn} do
      tip = tip_fixture(user_fixture(), %{title: @title})
      owner = user_fixture()
      review_fixture(tip, %{up_count: 9})
      own = review_fixture(tip, %{user_id: owner.id, up_count: 1})
      other = review_fixture(tip)
      card = "#review-#{own.id}"

      for {render, html, _title} <- renders(as(conn, owner), tip_path(tip)) do
        assert Enum.at(ids(find(html, "#review-list > article")), 1) == own.id, render
        assert text(html, "#{card} [data-badge]") == "Your review", render
        assert attr(html, "#{card} a", "Edit", "href") == "/editor/reviews/#{own.id}/edit"
        assert has?(html, "#{card}-delete"), render
        refute has?(html, "#review-#{other.id} [data-badge]"), render
        refute has?(html, "#review-#{other.id}-delete"), render
        refute html =~ "/editor/reviews/#{other.id}/edit", render
      end

      full_ban!(owner)

      for {render, html, _title} <- renders(as(conn, owner), tip_path(tip)) do
        assert has?(html, "#{card}-delete"), render
        refute html =~ "/editor/reviews/#{own.id}/edit", render
      end

      {:ok, lv, _html} = live(as(conn, owner), tip_path(tip))
      lv |> element("#{card}-delete") |> render_click()

      {:ok, _lv, html} =
        lv
        |> element("#{card}-delete-confirm button", "Delete review")
        |> render_click()
        |> follow_redirect(as(conn, owner), tip_path(tip))

      assert html =~ "Review deleted."
      refute has?(html, card)
      assert has?(html, "#review-#{other.id}")
    end
  end

  test "unknown and malformed tip ids are not found", %{conn: conn} do
    missing = tip_fixture().id + 1_000_000

    for id <- [missing, "abc", "0", "-1", "1.5", "99999999999999999999"],
        conn <- [conn, log_in_user(conn, user_fixture())] do
      assert_error_sent 404, fn -> get(conn, "/tips/#{id}/a-slug") end
      assert_error_sent 404, fn -> live(conn, "/tips/#{id}/a-slug") end
    end
  end

  defp secret_tip(author) do
    tip_fixture(author, %{
      title: "Secret plan title",
      body: "Secret body",
      prompt: "Secret prompt",
      output: "Secret output",
      model_id: "claude"
    })
  end

  defp refute_secret(html, author, label) do
    for secret <- ["Secret", "secret-plan", author.handle] do
      refute html =~ secret, inspect({label, secret})
    end
  end

  defp placeholder_slug(:hidden), do: "removed-tip"
  defp placeholder_slug(:deleted), do: "deleted-tip"

  defp tip_path(tip), do: "/tips/#{tip.id}/#{@slug}"

  defp ids(cards) do
    Enum.map(cards, fn card ->
      ["review-" <> id] = LazyHTML.attribute(card, "id")
      String.to_integer(id)
    end)
  end

  defp author_handle(review), do: Tips.Repo.get!(Tips.Accounts.User, review.user_id).handle

  defp assert_redirects_to(conn, path, expected) do
    assert redirected_to(get(conn, path)) == expected
    assert {:error, {_kind, %{to: ^expected}}} = live(conn, path)
  end
end
