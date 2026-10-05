defmodule Tips.Accounts.UserNotifier do
  @moduledoc """
  Delivers account-related emails.

  Each email is one direct provider attempt, bounded by one total budget
  (`:delivery_budget_ms` in `config/config.exs`). The attempt runs in an unlinked
  task under `Tips.Accounts.MailTaskSupervisor`:

    * The deadline is fixed before the task starts. The caller waits only for
      the time left, then kills the task.
    * The task arms a kill timer for the same deadline, so it stops even if the
      caller dies. With no time left it does not call the provider.
    * Provider errors, exceptions, throws and exits stay inside the task.

  Results are `{:ok, email}`, `{:error, {:delivery, :timeout}}` when the
  deadline passed, or `{:error, {:delivery, :uncertain}}` for anything else.
  Neither error means no message was sent: the provider may have accepted it
  before failing or being killed, and killing the task cannot recall it.
  Acceptance does not guarantee inbox delivery either. Failures are logged by
  flow and category only, never the address, link or provider reason.

  There is no retry. The user asks again, as a new admitted request.
  """

  import Swoosh.Email

  require Logger

  alias Tips.Accounts.User
  alias Tips.Mailer

  @type result :: {:ok, Swoosh.Email.t()} | {:error, {:delivery, :timeout | :uncertain}}

  defp deliver(flow, recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"Tips", "contact@example.com"})
      |> subject(subject)
      |> text_body(body)

    case attempt_within_budget(email) do
      :ok ->
        {:ok, email}

      {:error, category} ->
        Logger.warning("Authentication mail not confirmed: flow=#{flow} category=#{category}")
        {:error, {:delivery, category}}
    end
  end

  defp attempt_within_budget(email) do
    deadline = System.monotonic_time(:millisecond) + budget_ms()

    task =
      Task.Supervisor.async_nolink(Tips.Accounts.MailTaskSupervisor, fn ->
        attempt(email, deadline)
      end)

    # A reply that arrives during shutdown is used as is; it is never sent again.
    case Task.yield(task, time_left(deadline)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, _reason} -> {:error, :uncertain}
    end
  end

  defp attempt(email, deadline) do
    case time_left(deadline) do
      0 ->
        {:error, :timeout}

      ms ->
        {:ok, timer} = :timer.kill_after(ms)
        result = provider_call(email)
        :timer.cancel(timer)
        result
    end
  end

  # Only the provider call is contained; the caller has already committed tokens.
  defp provider_call(email) do
    case Mailer.deliver(email) do
      {:ok, _metadata} -> :ok
      {:error, _reason} -> {:error, :uncertain}
    end
  rescue
    _exception -> {:error, :uncertain}
  catch
    _kind, _reason -> {:error, :uncertain}
  end

  defp time_left(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp budget_ms, do: Application.fetch_env!(:tips, __MODULE__)[:delivery_budget_ms]

  @doc """
  Deliver instructions to update a user email.
  """
  @spec deliver_update_email_instructions(User.t(), String.t()) :: result()
  def deliver_update_email_instructions(user, url) do
    deliver(:email_change, user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  @spec deliver_login_instructions(User.t(), String.t()) :: result()
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(:login, user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(:confirmation, user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end
end
