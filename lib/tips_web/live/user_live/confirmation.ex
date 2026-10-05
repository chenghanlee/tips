defmodule TipsWeb.UserLive.Confirmation do
  use TipsWeb, :live_view

  alias Tips.Accounts
  alias TipsWeb.UserAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-6">
        <h1 class="text-center text-2xl font-semibold">Welcome {@user.email}</h1>

        <.form
          :if={!@user.confirmed_at}
          for={@form}
          id="confirmation_form"
          phx-mounted={JS.focus_first()}
          phx-submit="submit"
          action={~p"/users/log-in?_action=confirmed"}
          phx-trigger-action={@trigger_submit}
          class="space-y-2"
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <input :if={@return_to} type="hidden" name="user[return_to]" value={@return_to} />
          <UI.button
            size="lg"
            class="w-full"
            name={@form[:remember_me].name}
            value="true"
            phx-disable-with="Confirming..."
          >
            Confirm and stay logged in
          </UI.button>
          <UI.button variant="outline" size="lg" class="w-full" phx-disable-with="Confirming...">
            Confirm and log in only this time
          </UI.button>
        </.form>

        <.form
          :if={@user.confirmed_at}
          for={@form}
          id="login_form"
          phx-submit="submit"
          phx-mounted={JS.focus_first()}
          action={~p"/users/log-in"}
          phx-trigger-action={@trigger_submit}
          class="space-y-2"
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <input :if={@return_to} type="hidden" name="user[return_to]" value={@return_to} />
          <%= if @current_scope do %>
            <UI.button size="lg" class="w-full" phx-disable-with="Logging in...">
              Log in
            </UI.button>
          <% else %>
            <UI.button
              size="lg"
              class="w-full"
              name={@form[:remember_me].name}
              value="true"
              phx-disable-with="Logging in..."
            >
              Keep me logged in on this device
            </UI.button>
            <UI.button variant="outline" size="lg" class="w-full" phx-disable-with="Logging in...">
              Log me in only this time
            </UI.button>
          <% end %>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token} = params, session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok,
       assign(socket,
         page_title: "Confirm account",
         user: user,
         form: form,
         # Validated here and again by the controller; kept out of the form, so a
         # submitted value cannot replace it.
         return_to: UserAuth.return_to(params["return_to"], session["user_return_to"]),
         trigger_submit: false
       ), temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(
         :error,
         "Magic link is invalid or it has expired. " <>
           "If you signed up more than seven days ago without confirming, register again."
       )
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
