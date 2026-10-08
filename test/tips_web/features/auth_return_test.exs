defmodule TipsWeb.AuthReturnFeatureTest do
  # Swoosh's global mode delivers the LiveView's mail to this test; it requires async: false.
  use Tips.FeatureCase, async: false

  import Swoosh.TestAssertions
  import Tips.AccountsFixtures
  import Tips.ContentFixtures

  @moduletag :browser

  setup :set_swoosh_global

  setup do
    tip = tip_fixture(user_fixture(), %{title: "Pin the model version"})
    %{tip: tip, tip_path: "/tips/#{TipsWeb.TipId.encode(tip.id)}/pin-the-model-version"}
  end

  @sessions 2
  feature "returning sign-in from the tip's Reader link lands on the tip in another browser",
          %{sessions: [asking, confirming], tip_path: tip_path} do
    user = user_fixture()
    flush_emails()

    asking
    |> visit(tip_path)
    |> click(link("Sign in to review"))
    |> request_sign_in(user.email)

    confirming
    |> visit(emailed_link(user.email))
    |> click(button("Log me in only this time"))
    |> assert_signed_in_at(tip_path, user.email)
  end

  @sessions 2
  feature "registration from the review page's header lands on the review in another browser",
          %{sessions: [asking, confirming], tip: tip} do
    review_path = "/reviews/#{review_fixture(tip).id}"
    email = unique_user_email()
    flush_emails()

    asking
    |> visit(review_path)
    |> click(link("Register"))
    |> assert_has(css(".phx-connected"))
    |> fill_in(text_field("Email"), with: email)
    |> fill_in(text_field("Handle"), with: "Returning_One")
    |> click(button("Create an account"))
    |> assert_has(css("#flash-info", text: "An email was sent to #{email}"))

    confirming
    |> visit(emailed_link(email))
    |> click(button("Confirm and log in only this time"))
    |> assert_signed_in_at(review_path, email)
  end

  @sessions 2
  feature "protected settings through sign-in lands on settings in another browser",
          %{sessions: [asking, confirming]} do
    user = user_fixture()
    flush_emails()

    asking
    |> visit("/users/settings")
    |> request_sign_in(user.email)

    confirming
    |> visit(emailed_link(user.email))
    |> click(button("Keep me logged in on this device"))
    |> assert_signed_in_at("/users/settings", user.email)
  end

  defp request_sign_in(session, email) do
    session
    |> assert_has(css("#login_form_magic"))
    |> assert_has(css(".phx-connected"))
    |> fill_in(text_field("Email"), with: email)
    |> click(button("Log in with email"))
    |> assert_has(css("#flash-info", text: "check your inbox"))
  end

  # The actual link from the delivered email, opened as a path on the test server.
  defp emailed_link(email) do
    assert_receive {:email, %Swoosh.Email{to: [{_name, ^email}], text_body: body}}, 5_000
    [link] = Regex.run(~r{http\S+/users/log-in/\S+}, body)
    %URI{path: path, query: query} = URI.parse(link)
    "#{path}?#{query}"
  end

  defp assert_signed_in_at(session, path, email) do
    session
    |> assert_has(css(".phx-connected"))
    |> assert_has(css("header", text: email))

    assert current_path(session) == path
    session
  end

  defp flush_emails do
    receive do
      {:email, _email} -> flush_emails()
    after
      0 -> :ok
    end
  end
end
