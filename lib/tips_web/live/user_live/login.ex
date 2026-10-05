defmodule TipsWeb.UserLive.Login do
  use TipsWeb, :live_view

  alias Tips.Accounts
  alias Tips.Accounts.User
  alias TipsWeb.{AuthMailAdmission, UserAuth}

  # One answer for unknown addresses, sent links and unconfirmed delivery, so the
  # page never reveals whether an account exists or whether its mail was sent.
  @requested "If this email has an account, check your inbox for a sign-in link. " <>
               "If it hasn't arrived in a few minutes, request another."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-6">
        <div class="space-y-1 text-center">
          <h1 class="text-2xl font-semibold">Log in</h1>
          <p class="text-sm text-muted-foreground">
            <%= if @current_scope do %>
              You need to reauthenticate to perform sensitive actions on your account.
            <% else %>
              Don't have an account? <.link
                navigate={@register_path}
                class="font-semibold text-foreground underline"
                phx-no-format
              >Sign up</.link> for an account now.
            <% end %>
          </p>
        </div>

        <UI.notice :if={local_mail_adapter?()} icon="hero-information-circle">
          You are running the local mail adapter. To see sent emails, visit <.link
            href="/dev/mailbox"
            class="underline"
          >the mailbox page</.link>.
        </UI.notice>

        <.form
          :let={f}
          for={@form}
          id="login_form_magic"
          action={~p"/users/log-in"}
          phx-submit="submit_magic"
          class="space-y-4"
        >
          <UI.field
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            phx-mounted={JS.focus()}
          />
          <UI.button size="lg" class="w-full">
            Log in with email <span aria-hidden="true">→</span>
          </UI.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, session, socket) do
    # The same validated destination the registration form accepts: the emailed link
    # carries it, and restarting signup from here keeps it.
    return_to = UserAuth.return_to(params["return_to"], session["user_return_to"])

    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok,
     socket
     |> assign(
       page_title: "Log in",
       form: form,
       return_to: return_to,
       register_path: UserAuth.with_return_to(~p"/users/register", return_to)
     )
     |> AuthMailAdmission.assign_identity(session)}
  end

  @impl true
  def handle_event("submit_magic", %{"user" => %{"email" => typed}}, socket) do
    # Reauthentication always uses the signed-in account's own address; the event cannot
    # replace it.
    email = reauthentication_email(socket.assigns.current_scope) || typed

    # Charged before the lookup, for known and unknown addresses alike. Every answer stays
    # on the form with the email and the register link's destination.
    socket = clear_flash(socket)

    socket =
      case AuthMailAdmission.admit(socket.assigns, email) do
        :ok -> request_link(socket, email)
        {:error, reason} -> reject(socket, email, reason)
      end

    {:noreply, socket}
  end

  defp request_link(socket, email) do
    with %User{} = user <- Accounts.get_user_by_email(email),
         {:error, :not_found} <-
           Accounts.deliver_login_instructions(user, &link_url(socket, &1)) do
      # The registration expired, or cleanup deleted it after the lookup.
      socket
      |> put_flash(
        :error,
        "This sign-up was not confirmed within seven days and has expired. " <>
          "Register again to continue."
      )
      |> assign_email(email)
    else
      nil -> requested(socket, email)
      {:ok, _email} -> requested(socket, email)
      {:error, {:delivery, _category}} -> requested(socket, email)
    end
  end

  defp reauthentication_email(%{user: %User{email: email}}), do: email
  defp reauthentication_email(nil), do: nil

  defp requested(socket, email), do: socket |> put_flash(:info, @requested) |> assign_email(email)

  defp reject(socket, email, :invalid_identity),
    do: assign_email(socket, email, errors: [email: {"is invalid", []}])

  defp reject(socket, email, reason) do
    socket |> put_flash(:error, rejection_message(reason)) |> assign_email(email)
  end

  defp rejection_message({:rate_limited, seconds}),
    do: "Too many sign-in requests. Try again in #{AuthMailAdmission.retry_in(seconds)}."

  defp rejection_message({:capacity, seconds}),
    do: "Sign-in is busy right now. Try again in #{AuthMailAdmission.retry_in(seconds)}."

  defp rejection_message(:no_client_ip), do: AuthMailAdmission.no_client_ip_message()

  defp assign_email(socket, email, opts \\ []) do
    email = if is_binary(email), do: email, else: ""
    assign(socket, form: to_form(%{"email" => email}, [as: "user"] ++ opts))
  end

  defp link_url(socket, token),
    do: UserAuth.with_return_to(url(~p"/users/log-in/#{token}"), socket.assigns.return_to)

  defp local_mail_adapter? do
    Application.get_env(:tips, Tips.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
