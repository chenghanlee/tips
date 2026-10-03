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
        refute html =~ ~s(phx-click="vote"), render
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
                 "/users/log-in",
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

  defp assert_redirects_to(conn, path, expected) do
    assert redirected_to(get(conn, path)) == expected
    assert {:error, {_kind, %{to: ^expected}}} = live(conn, path)
  end
end
