defmodule TipsWeb.UserLive.Login do
  use TipsWeb, :live_view

  alias Tips.Accounts
  alias Tips.Accounts.User
  alias TipsWeb.UserAuth

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
    # The same validated destination the registration form accepts, so restarting signup
    # from here keeps it.
    return_to =
      UserAuth.allowed_return_to(params["return_to"]) ||
        UserAuth.allowed_return_to(session["user_return_to"])

    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok,
     assign(socket, page_title: "Log in", form: form, register_path: register_path(return_to))}
  end

  @impl true
  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    with %User{} = user <- Accounts.get_user_by_email(email),
         {:error, :not_found} <-
           Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}")) do
      # The registration expired, or cleanup deleted it after the lookup. Stay on the form:
      # the email, and the return destination kept in the session, carry into signup.
      {:noreply,
       socket
       |> put_flash(
         :error,
         "This sign-up was not confirmed within seven days and has expired. " <>
           "Register again to continue."
       )
       |> assign(form: to_form(%{"email" => email}, as: "user"))}
    else
      # No such account, mail accepted, or mail delivery failed: one answer for all.
      _other ->
        info =
          "If your email is in our system, you will receive instructions for logging in shortly."

        {:noreply,
         socket
         |> put_flash(:info, info)
         |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  defp register_path(nil), do: ~p"/users/register"
  defp register_path(return_to), do: ~p"/users/register?#{[return_to: return_to]}"

  defp local_mail_adapter? do
    Application.get_env(:tips, Tips.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
