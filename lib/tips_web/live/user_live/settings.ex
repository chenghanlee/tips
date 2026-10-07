defmodule TipsWeb.UserLive.Settings do
  use TipsWeb, :live_view

  on_mount {TipsWeb.UserAuth, :require_sudo_mode}

  alias Tips.Accounts
  alias TipsWeb.{AuthMailAdmission, UserAuth}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} unread={@unread_notifications}>
      <div class="space-y-1 text-center">
        <h1 class="text-2xl font-semibold">Account Settings</h1>
        <p class="text-sm text-muted-foreground">
          Manage your account email address
        </p>
      </div>

      <.form
        for={@email_form}
        id="email_form"
        phx-submit="update_email"
        phx-change="validate_email"
        class="space-y-4"
      >
        <UI.field
          field={@email_form[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          spellcheck="false"
        />
        <UI.button size="lg" phx-disable-with="Changing...">Change Email</UI.button>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)

    socket =
      socket
      |> assign(:page_title, "Account settings")
      |> assign(:email_form, to_form(email_changeset))
      |> AuthMailAdmission.assign_identity(session)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", %{"user" => user_params}, socket) do
    with {:ok, socket} <- UserAuth.readmit(socket),
         %{user: user} = socket.assigns.current_scope,
         {:sudo, true} <- {:sudo, Accounts.sudo_mode?(user)} do
      {:noreply, request_email_change(socket, user, user_params)}
    else
      {:error, :unauthenticated} -> {:noreply, UserAuth.require_login(socket)}
      {:sudo, false} -> {:noreply, UserAuth.require_reauthentication(socket)}
    end
  end

  # Only a valid new address is charged, to its own destination bucket, before the token.
  defp request_email_change(socket, user, user_params) do
    changeset = Accounts.change_user_email(user, user_params)
    socket = clear_flash(socket)

    with {:ok, %{email: new_email} = changed} <- Ecto.Changeset.apply_action(changeset, :insert),
         :ok <- AuthMailAdmission.admit(socket.assigns, new_email),
         {:ok, _email} <-
           Accounts.deliver_user_update_email_instructions(
             changed,
             user.email,
             &url(~p"/users/settings/confirm-email/#{&1}")
           ) do
      info = "A link to confirm your email change has been sent to the new address."
      put_flash(socket, :info, info)
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        assign(socket, :email_form, to_form(changeset))

      {:error, :invalid_identity} ->
        changeset = Ecto.Changeset.add_error(changeset, :email, "is invalid")
        assign(socket, :email_form, to_form(changeset, action: :insert))

      {:error, {:delivery, _category}} ->
        socket
        |> put_flash(:error, not_confirmed_message(Ecto.Changeset.get_field(changeset, :email)))
        |> assign(:email_form, to_form(changeset, action: :insert))

      {:error, reason} ->
        socket
        |> put_flash(:error, rejection_message(reason))
        |> assign(:email_form, to_form(changeset, action: :insert))
    end
  end

  defp not_confirmed_message(new_email) do
    "We couldn't confirm that the confirmation link was sent to #{new_email}. " <>
      "It may still arrive; if it doesn't, request it again. Your sign-in email has not changed."
  end

  defp rejection_message({:rate_limited, seconds}),
    do: "Too many email change requests. Try again in #{AuthMailAdmission.retry_in(seconds)}."

  defp rejection_message({:capacity, seconds}),
    do: "Email change is busy right now. Try again in #{AuthMailAdmission.retry_in(seconds)}."

  defp rejection_message(:no_client_ip), do: AuthMailAdmission.no_client_ip_message()
end
