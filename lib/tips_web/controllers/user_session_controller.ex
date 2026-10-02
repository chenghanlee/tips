defmodule TipsWeb.UserSessionController do
  use TipsWeb, :controller

  alias Tips.Accounts
  alias TipsWeb.UserAuth

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "User confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) when is_binary(token) do
    case Accounts.login_user_by_magic_link(token, get_session(conn, :user_token)) do
      {:ok, %{user: user, session_token: session_token, revoked_family_ids: family_ids}} ->
        UserAuth.disconnect_sessions(family_ids)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, session_token, user_params)

      {:error, :not_found} ->
        invalid_link(conn)
    end
  end

  # Anything else, such as email and password credentials, is not a login.
  defp create(conn, _params, _info), do: invalid_link(conn)

  # An expired registration is rejected like any other invalid link, and may already be
  # deleted, so every rejection carries the restart guidance.
  defp invalid_link(conn) do
    conn
    |> put_flash(
      :error,
      "The link is invalid or it has expired. " <>
        "If you signed up more than seven days ago without confirming, register again."
    )
    |> redirect(to: ~p"/users/log-in")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
