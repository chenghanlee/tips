defmodule TipsWeb.EditorSubmitTest do
  @moduledoc """
  Real-browser tests of submit-time validation and refused saves (#79): the
  error summary takes focus, an error opens the evidence disclosure, a
  summary link focuses its field, and an expired sign-in keeps the input
  without a reload.
  """
  use Tips.FeatureCase, async: true

  import Ecto.Query
  import Tips.AccountsFixtures
  import Tips.ContentFixtures

  alias Tips.Accounts.UserToken
  alias Tips.Repo

  @moduletag :browser

  setup %{session: session} do
    user = user_fixture()
    sign_in(session, user)

    %{
      user: user,
      form: "#editor-#{user.id}-review",
      path: "/editor/tips/#{tip_fixture().id}/reviews/new"
    }
  end

  feature "a refused publish focuses the summary and opens the evidence around an error",
          %{session: session, form: form, path: path} do
    session
    |> visit(path)
    |> assert_has(css(".phx-connected"))

    # Too long a prompt, inside the closed disclosure, and an untouched body.
    js(session, ~s|document.getElementById("review_prompt").value = "p".repeat(20001)|)
    assert js(session, ~s|return document.querySelector("#{form} details").open|) == false

    session
    |> click(button("Publish"))
    |> assert_has(css("#{form}-errors a", count: 2))

    summary = String.trim_leading(form, "#") <> "-errors"
    assert focused(session, summary) == summary
    assert js(session, ~s|return document.querySelector("#{form} details").open|) == true

    click(session, css("#{form}-errors a[href='#review_body']"))
    assert focused(session, "review_body") == "review_body"

    js(session, ~s|document.querySelector("#{form} details").open = false|)
    click(session, css("#{form}-errors a[href='#review_prompt']"))
    assert focused(session, "review_prompt") == "review_prompt"
    assert js(session, ~s|return document.querySelector("#{form} details").open|) == true
  end

  feature "an expired sign-in keeps the typed review on the page and offers Sign in",
          %{session: session, user: user, form: form, path: path} do
    session
    |> visit(path)
    |> assert_has(css(".phx-connected"))
    |> fill_in(text_field("Review"), with: "Worked on a rename.")

    js(session, "window.notReloaded = true")
    Repo.delete_all(from t in UserToken, where: t.user_id == ^user.id)

    session
    |> click(button("Publish"))
    |> assert_has(css("#{form}-refusal", text: "Your sign-in has expired"))
    |> assert_has(
      css("#{form}-refusal a[href='/users/log-in?#{URI.encode_query(return_to: path)}']")
    )

    assert js(session, "return window.notReloaded") == true

    assert js(session, ~s|return document.getElementById("review_body").value|) ==
             "Worked on a rename."
  end

  defp sign_in(session, user) do
    {token, _hashed} = generate_user_magic_link_token(user)

    session
    |> visit("/users/log-in/#{token}")
    |> click(button("Log me in only this time"))
    |> assert_has(css("header", text: user.email))
  end

  defp js(session, script) do
    execute_script(session, script, [], &send(self(), {:js, &1}))
    assert_received {:js, value}
    value
  end

  # The focused element's id, once it is `id` or after two seconds.
  defp focused(session, id, tries \\ 40) do
    value = js(session, "return document.activeElement.id")

    if value != id and tries > 1 do
      Process.sleep(50)
      focused(session, id, tries - 1)
    else
      value
    end
  end
end
