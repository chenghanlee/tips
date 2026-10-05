defmodule Tips.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Tips.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Tips.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Tips.DataCase
    end
  end

  setup tags do
    Tips.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.

  An `:isolation` tag, such as `"REPEATABLE READ"`, sets the test transaction's
  isolation before any query, so code under test can declare the same level.
  """
  def setup_sandbox(tags) do
    pid =
      Sandbox.start_owner!(Tips.Repo, shared: not tags[:async], isolation: tags[:isolation])

    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.register_user(%{email: "not valid"})
      assert "must have the @ sign and no spaces" in errors_on(changeset).email
      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
