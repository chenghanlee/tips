defmodule TipsWeb.LiveSmokeTest do
  use Tips.FeatureCase, async: true

  @moduletag :browser

  feature "registers through the connected LiveView using the SQL sandbox", %{session: session} do
    email = Tips.AccountsFixtures.unique_user_email()
    handle = Tips.AccountsFixtures.valid_user_attributes().handle

    session
    |> resize_window(390, 844)
    |> visit("/users/register")
    |> assert_has(css(".phx-connected"))
    |> execute_script(
      """
      const probe = document.createElement("div");
      probe.style.color = "var(--input)";
      document.body.appendChild(probe);
      // Registration focuses email on mount; check its resting border first.
      const email = document.getElementById("user_email");
      email.blur();
      const input = getComputedStyle(email);
      const result = [input.borderTopColor, getComputedStyle(probe).color];
      probe.remove();
      return result;
      """,
      [],
      fn [border, input_token] ->
        assert border == input_token
      end
    )
    # Script focus, not a Tab from <body>: headless Chrome in CI does not move
    # focus on a page-level Tab. The button follows a focus-visible input, so
    # it matches :focus-visible too.
    |> execute_script(
      """
      const outline = (el) => {
        el.focus();
        const style = getComputedStyle(document.activeElement);
        return [style.outlineWidth, style.outlineStyle, describe(document.activeElement)];
      };
      const describe = (el) =>
        `${el.tagName}#${el.id}.${el.className} focus-visible=${el.matches(":focus-visible")}`;
      const button = [...document.querySelectorAll("button")].find(b => b.textContent.trim() === "Create an account");
      return [outline(document.getElementById("user_email")), outline(button)];
      """,
      [],
      fn [[input_width, input_style, input], [button_width, button_style, button]] ->
        assert {input_width, input_style} == {"2px", "solid"}, input
        assert {button_width, button_style} == {"2px", "solid"}, button
      end
    )
    |> fill_in(text_field("Email"), with: "invalid")
    |> assert_has(css("#registration_form", text: "must have the @ sign and no spaces"))
    |> fill_in(text_field("Email"), with: email)
    |> fill_in(text_field("Handle"), with: handle)
    |> click(button("Create an account"))
    |> assert_has(css("#flash-info", text: "An email was sent to #{email}"))

    assert %Tips.Accounts.User{email: ^email} = Tips.Accounts.get_user_by_email(email)
  end
end
