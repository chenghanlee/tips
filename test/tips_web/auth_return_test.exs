defmodule TipsWeb.AuthReturnTest do
  use TipsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tips.AccountsFixtures
  import Tips.AdmissionFixtures
  import Tips.ContentFixtures
  import Tips.ModerationFixtures
  import Tips.VisibilityFixtures
  import TipsWeb.ReaderPageHelpers

  alias Tips.Accounts
  alias Tips.Content.{Flag, Notification, Review, Tip, Vote}
  alias Tips.Repo

  @peer {198, 51, 100, 7}

  # Every test owns an isolated limiter and a fixed transport peer for its mail requests.
  setup %{conn: conn} do
    %{limiter: limiter} = start_limiter()

    conn =
      conn
      |> init_test_session(%{"admission_limiter" => limiter})
      |> Plug.Test.put_peer_data(%{address: @peer, port: 40_000, ssl_cert: nil})

    # Above the sequence's ids, where base36 and decimal differ.
    tip =
      tip_fixture(user_fixture(), %{id: 9_223_372_036_854_775_806, title: "Pin the model version"})

    %{
      conn: conn,
      tip: tip,
      review: review_fixture(tip),
      tip_path: "/tips/1y2p0ij32e8e6/pin-the-model-version"
    }
  end

  describe "public sign-in links" do
    test "the header links carry the current tip or review permalink", %{
      conn: conn,
      review: review,
      tip_path: tip_path
    } do
      for path <- [tip_path, "/reviews/#{review.id}"],
          {render, html, _title} <- renders(conn, path),
          {label, auth_path} <- [{"Log in", "/users/log-in"}, {"Register", "/users/register"}] do
        assert attr(html, "header a", label, "href") == with_return_to(auth_path, path),
               inspect({path, render, label})
      end
    end
  end

  describe "returning through the emailed link in another browser" do
    # Only an existing account can own the review its edit route opens.
    for form <- [:login, :registration],
        destination <- [:tip, :review, :settings, :new_review, :edit_review],
        form == :login or destination != :edit_review do
      @form form
      @destination destination
      test "#{form} started from #{destination} returns there and writes no product state",
           context do
        %{conn: conn, tip: tip, review: review} = context
        user = if @form == :login, do: user_fixture()
        email = if user, do: user.email, else: unique_user_email()
        # Existing product state the authentication must leave untouched.
        voter = user || user_fixture()
        vote_fixture(tip, %{user_id: voter.id})
        flag_fixture(voter, %{review_id: review.id})
        notification_fixture(voter, %{tip_id: tip.id})
        context = Map.put(context, :own_review, user && review_fixture(tip, %{user_id: user.id}))
        before = product_state()

        {destination, entry, conn} = enter(conn, @destination, @form, context)
        {:ok, lv, _html} = live(conn, entry)
        flush_emails()
        request_link(lv, @form, email)

        assert_received {:email, %Swoosh.Email{text_body: body}}
        [link] = Regex.run(~r{http\S+/users/log-in/\S+}, body)
        %URI{path: link_path, query: query} = URI.parse(link)
        assert URI.decode_query(query || "") == %{"return_to" => destination}

        # Another browser: no cookie or session from the one that asked.
        other_browser = build_conn()
        {:ok, confirm, _html} = live(other_browser, "#{link_path}?#{query}")
        form = form(confirm, if(user, do: "#login_form", else: "#confirmation_form"))
        render_submit(form)
        signed_in = follow_trigger_action(form, other_browser)

        assert redirected_to(signed_in) == destination
        assert signed_in |> get(destination) |> html_response(200) =~ email
        assert product_state() == before
      end
    end
  end

  describe "access after sign-in" do
    test "the destination shows what the newly signed-in account may see", %{conn: conn} do
      author = user_fixture()
      tip = tip_fixture(author, %{title: "Quietly removed"})
      path = "/tips/#{TipsWeb.TipId.encode(tip.id)}/quietly-removed"
      author_link = magic_link(author, path)
      other_link = magic_link(user_fixture(), path)
      # Moderation hides the tip after both links were sent.
      put_marker!(tip, :hidden)

      as_author = confirm(conn, author_link)
      assert redirected_to(as_author) == path
      html = as_author |> get(path) |> html_response(200)
      assert has?(html, "#tip-removed-notice")
      assert html =~ "Quietly removed"

      # The same browser switches accounts; the carried destination still wins.
      switched = confirm(as_author, other_link)
      assert redirected_to(switched) == path

      assert switched |> get(path) |> redirected_to() ==
               "/tips/#{TipsWeb.TipId.encode(tip.id)}/removed-tip"

      html =
        switched |> get("/tips/#{TipsWeb.TipId.encode(tip.id)}/removed-tip") |> html_response(200)

      refute html =~ "Quietly removed"
    end
  end

  # The page a journey starts on, the auth page its link opens, and the browser.
  defp enter(conn, :tip, form, %{tip_path: path}) do
    label = if form == :login, do: "Sign in to review", else: "Register"
    {path, link_href(conn, path, label), conn}
  end

  defp enter(conn, :review, form, %{review: review}) do
    path = "/reviews/#{review.id}"
    {path, link_href(conn, path, if(form == :login, do: "Log in", else: "Register")), conn}
  end

  # Settings and the editors are protected: the GET stores the destination in this
  # browser's session, and the log-in page, or its Sign up link, carries it on.
  defp enter(conn, :settings, form, _context),
    do: enter_protected(conn, ~p"/users/settings", form)

  defp enter(conn, :new_review, form, %{tip: tip}),
    do: enter_protected(conn, ~p"/editor/tips/#{tip}/reviews/new", form)

  defp enter(conn, :edit_review, form, %{own_review: review}),
    do: enter_protected(conn, ~p"/editor/reviews/#{review}/edit", form)

  defp enter_protected(conn, path, form) do
    conn = get(conn, path)
    assert redirected_to(conn) == ~p"/users/log-in"

    entry =
      if form == :login,
        do: ~p"/users/log-in",
        else: link_href(conn, ~p"/users/log-in", "Sign up")

    {path, entry, conn}
  end

  defp link_href(conn, path, label) do
    {:ok, _lv, html} = live(conn, path)

    html
    |> find("a")
    |> Enum.find(&(LazyHTML.text(&1) =~ label))
    |> LazyHTML.attribute("href")
    |> hd()
  end

  defp request_link(lv, :login, email) do
    lv |> form("#login_form_magic", user: %{email: email}) |> render_submit()
  end

  defp request_link(lv, :registration, email) do
    lv
    |> form("#registration_form", user: %{handle: "Returning_One", email: email})
    |> render_submit()
  end

  defp magic_link(user, path) do
    token = extract_user_token(&Accounts.deliver_login_instructions(user, &1))
    "/users/log-in/#{token}?" <> URI.encode_query(return_to: path)
  end

  defp confirm(conn, link) do
    {:ok, lv, _html} = live(conn, link)
    form = form(lv, "#login_form")
    render_submit(form)
    follow_trigger_action(form, conn)
  end

  defp with_return_to(path, return_to), do: path <> "?" <> URI.encode_query(return_to: return_to)

  defp flush_emails do
    receive do
      {:email, _email} -> flush_emails()
    after
      0 -> :ok
    end
  end

  defp product_state do
    Map.new([Tip, Review, Vote, Flag, Notification], &{&1, &1 |> Repo.all() |> Enum.sort()})
  end
end
