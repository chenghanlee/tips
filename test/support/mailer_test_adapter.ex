defmodule Tips.MailerTestAdapter do
  @moduledoc """
  The test mail adapter. It delegates to `Swoosh.Adapters.Test` unless the
  delivering test scripted its own outcome with `script/1`.

  A script belongs to the test process that registered it and reaches only
  deliveries whose process or `$callers` include that test: its LiveViews and
  their delivery tasks. Other async tests are unaffected, and nothing touches
  application config. A delivery that loses its owner falls back to the default
  adapter, so the test's failure assertions fail.

  Each scripted attempt first sends `{:mail_attempt, attempt_pid}` to the owner,
  so the test can count attempts and monitor the attempt process.
  """

  use Swoosh.Adapter

  alias Swoosh.Adapters.Test

  @type behaviour ::
          :reject | :block | {:raise, String.t()} | {:throw, term()} | {:exit, term()}

  @doc "Scripts every delivery started by the calling test. Call it once per test."
  @spec script(behaviour()) :: :ok
  def script(behaviour) do
    {:ok, _owner} = Registry.register(__MODULE__, self(), behaviour)
    :ok
  end

  @impl true
  def deliver(email, config) do
    case scripted_owner() do
      {owner, behaviour} ->
        send(owner, {:mail_attempt, self()})
        run(behaviour)

      nil ->
        Test.deliver(email, config)
    end
  end

  defp scripted_owner do
    Enum.find_value([self() | Process.get(:"$callers", [])], fn pid ->
      case Registry.lookup(__MODULE__, pid) do
        [{^pid, behaviour}] -> {pid, behaviour}
        [] -> nil
      end
    end)
  end

  defp run(:reject), do: {:error, {422, %{"message" => "synthetic provider rejection"}}}
  defp run(:block), do: Process.sleep(:infinity)
  defp run({:raise, message}), do: raise(message)
  defp run({:throw, value}), do: throw(value)
  defp run({:exit, reason}), do: exit(reason)
end
