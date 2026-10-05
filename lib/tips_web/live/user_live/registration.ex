defmodule TipsWeb.UserLive.Registration do
  use TipsWeb, :live_view

  alias Tips.Accounts
  alias Tips.Accounts.User
  alias TipsWeb.{AuthMailAdmission, UserAuth}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-6">
        <div class="space-y-1 text-center">
          <h1 class="text-2xl font-semibold">Register for an account</h1>
          <p class="text-sm text-muted-foreground">
            Already registered? <.link
              navigate={@log_in_path}
              class="font-semibold text-foreground underline"
              phx-no-format
            >Log in</.link> to your account now.
          </p>
        </div>

        <.form
          for={@form}
          id="registration_form"
          phx-submit="save"
          phx-change="validate"
          class="space-y-4"
        >
          <%!-- Disabled until the first join, which would overwrite anything typed earlier. --%>
          <fieldset disabled={!@connected} class="space-y-4">
            <UI.field
              field={@form[:handle]}
              label="Handle"
              autocomplete="nickname"
              spellcheck="false"
              helper="Your public name. You can keep this suggestion or choose another; it can't be changed after you sign up."
            />
            <UI.field
              field={@form[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              spellcheck="false"
              phx-mounted={JS.focus()}
            />

            <UI.notice :if={@email_registered} id="email-registered" role="status">
              This email is already registered. <.link
                navigate={@log_in_path}
                class="font-semibold underline"
                phx-no-format
              >Sign in</.link> instead.
            </UI.notice>

            <UI.button type="submit" size="lg" class="w-full" phx-disable-with="Creating account...">
              Create an account
            </UI.button>
          </fieldset>
          <p
            :if={!@connected}
            id="registration-connecting"
            role="status"
            class="text-center text-sm text-muted-foreground"
          >
            Connecting…
          </p>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: UserAuth.signed_in_path(socket))}
  end

  def mount(params, session, socket) do
    return_to = UserAuth.return_to(params["return_to"], session["user_return_to"])

    changeset =
      Accounts.change_user_registration(%User{}, %{handle: Accounts.suggest_handle()},
        validate_unique: false
      )

    socket =
      socket
      |> assign(
        page_title: "Register",
        connected: connected?(socket),
        return_to: return_to,
        log_in_path: UserAuth.with_return_to(~p"/users/log-in", return_to)
      )
      |> AuthMailAdmission.assign_identity(session)
      |> assign_form(changeset)

    {:ok, socket, temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_registration(%User{}, user_params, validate_unique: false)

    with {:ok, %User{email: email}} <- Ecto.Changeset.apply_action(changeset, :insert),
         :ok <- AuthMailAdmission.admit(socket.assigns, email),
         {:ok, user} <- Accounts.register_user(user_params) do
      {:noreply, deliver_confirmation(socket, user)}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, reason} ->
        {:noreply, reject(socket, changeset, reason)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_registration(%User{}, user_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp reject(socket, changeset, :invalid_identity) do
    changeset = Ecto.Changeset.add_error(changeset, :email, "is invalid")
    assign_form(socket, Map.put(changeset, :action, :insert))
  end

  defp reject(socket, changeset, reason) do
    socket
    |> put_flash(:error, rejection_message(reason))
    |> assign_form(Map.put(changeset, :action, :insert))
  end

  defp rejection_message({:rate_limited, seconds}),
    do: "Too many sign-up attempts. Try again in #{AuthMailAdmission.retry_in(seconds)}."

  defp rejection_message({:capacity, seconds}),
    do: "Sign-up is busy right now. Try again in #{AuthMailAdmission.retry_in(seconds)}."

  defp rejection_message(:no_client_ip), do: AuthMailAdmission.no_client_ip_message()

  defp rejection_message(:registration_invariant),
    do: "We couldn't complete your sign-up because of a problem on our end. Try again later."

  defp deliver_confirmation(socket, user) do
    return_to = socket.assigns.return_to
    url_fun = &UserAuth.with_return_to(url(~p"/users/log-in/#{&1}"), return_to)

    case Accounts.deliver_login_instructions(user, url_fun) do
      {:ok, _email} ->
        socket
        |> put_flash(
          :info,
          "An email was sent to #{user.email}, please access it to confirm your account."
        )
        |> push_navigate(to: socket.assigns.log_in_path)

      {:error, _reason} ->
        socket
        |> put_flash(:email, user.email)
        |> put_flash(
          :error,
          "Your account was created, but we couldn't confirm that the email was sent. " <>
            "Request a new link below."
        )
        |> push_navigate(to: socket.assigns.log_in_path)
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket,
      form: to_form(changeset, as: "user"),
      email_registered: email_registered?(changeset)
    )
  end

  defp email_registered?(%Ecto.Changeset{action: action, errors: errors}) when action != nil do
    Enum.any?(errors, fn
      {:email, {_message, meta}} ->
        meta[:validation] == :unsafe_unique or meta[:constraint] == :unique

      _error ->
        false
    end)
  end

  defp email_registered?(_changeset), do: false
end
