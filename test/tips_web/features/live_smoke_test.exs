defmodule TipsWeb.LiveSmokeTest do
  use Tips.FeatureCase, async: true

  @moduletag :browser

  feature "validates email through a connected LiveView", %{session: session} do
    session
    |> resize_window(1280, 800)
    |> visit("/users/register")
    |> assert_has(css(".phx-connected"))
    |> fill_in(text_field("Email"), with: "invalid")
    |> assert_has(css("#registration_form", text: "must have the @ sign and no spaces"))
  end

  feature "shows the registration form on a mobile viewport", %{session: session} do
    session
    |> resize_window(390, 844)
    |> visit("/users/register")
    |> assert_has(css(".phx-connected"))
    |> assert_has(text_field("Email"))
    |> assert_has(button("Create an account"))
  end

  feature "registers through the connected LiveView using the SQL sandbox", %{session: session} do
    email = Tips.AccountsFixtures.unique_user_email()

    session
    |> resize_window(1280, 800)
    |> visit("/users/register")
    |> assert_has(css(".phx-connected"))
    |> fill_in(text_field("Email"), with: email)
    |> click(button("Create an account"))
    |> assert_has(css("#flash-info", text: "An email was sent to #{email}"))

    assert %Tips.Accounts.User{email: ^email} = Tips.Accounts.get_user_by_email(email)
  end
end
