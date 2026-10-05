defmodule Tips.Workers.EmbedSearchTest do
  # A real Oban instance executes scans in its own processes over committed
  # rows, so this module switches the sandbox to auto mode and owns cleanup.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Tips.AccountsFixtures
  import Tips.SearchFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Tips.Accounts.User
  alias Tips.Content.Search.EmbeddingProvider
  alias Tips.Content.Tip
  alias Tips.Repo
  alias Tips.Workers.EmbedSearch

  setup do
    Sandbox.mode(Repo, :auto)
    Req.Test.set_req_test_to_shared()
    delete_jobs!()

    on_exit(fn ->
      Req.Test.set_req_test_to_private()
      Sandbox.mode(Repo, :manual)
    end)

    author = user_fixture()
    on_exit(fn -> delete_owned!(author) end)

    name = {__MODULE__, System.unique_integer([:positive])}

    start_supervised!(
      {Oban,
       name: name,
       repo: Repo,
       queues: [embeddings: 1],
       plugins: false,
       testing: :disabled,
       notifier: Oban.Notifiers.Isolated,
       peer: Oban.Peers.Isolated}
    )

    %{oban: name, author: author}
  end

  test "ticks coalesce while a scan executes; a finished scan admits the next", context do
    test = self()
    tip = indexed_tip!(context.author, %{title: "Waiting"})

    stub_provider(fn conn, input ->
      send(test, {:requesting, self()})

      receive do
        :release -> respond_vector(conn, input)
      end
    end)

    {:ok, first} = insert(context)
    assert_receive {:requesting, request}, 5_000
    assert %{state: "executing"} = Repo.get!(Oban.Job, first.id)

    assert {:ok, %Oban.Job{id: id, conflict?: true}} = insert(context)
    assert id == first.id

    send(request, :release)
    await_state(first, "completed")
    assert %{embedding: "[" <> _} = search_row({:tip, tip.id})

    assert {:ok, %Oban.Job{conflict?: false} = next} = insert(context)
    await_state(next, "completed")
  end

  @tag :capture_log
  test "a request process crash after admission fails the scan; the next scan moves past it",
       context do
    [done, crashing, later] =
      for title <- ~w(Done Crashing Later), do: indexed_tip!(context.author, %{title: title})

    stub_provider(fn conn, input ->
      if input =~ "Crashing", do: raise("provider adapter bug"), else: respond_vector(conn, input)
    end)

    {:ok, failed} = insert(context)
    await_state(failed, "discarded")
    assert ["Done" <> _, "Crashing" <> _] = provider_inputs()
    assert %{embedding: "[" <> _} = search_row({:tip, done.id})
    assert %{embedding: nil, embed_after: %DateTime{}} = search_row({:tip, crashing.id})
    assert %{embedding: nil, embed_after: nil} = search_row({:tip, later.id})

    {:ok, next} = insert(context)
    await_state(next, "completed")
    assert ["Later" <> _] = provider_inputs()
    assert %{embedding: "[" <> _} = search_row({:tip, later.id})
    assert %{embedding: nil} = search_row({:tip, crashing.id})
  end

  test "an empty scan needs no provider key; a missing key fails before any admission",
       context do
    provider = Application.fetch_env!(:tips, EmbeddingProvider)
    provider_config = Application.fetch_env!(:tips, Tips.ProviderConfig)

    on_exit(fn ->
      Application.put_env(:tips, EmbeddingProvider, provider)
      Application.put_env(:tips, Tips.ProviderConfig, provider_config)
    end)

    # Defeat both the synthetic test key and any key in the checkout's .env.
    Application.put_env(:tips, EmbeddingProvider, Keyword.delete(provider, :api_key))
    Application.put_env(:tips, Tips.ProviderConfig, Keyword.put(provider_config, :values, %{}))
    stub_provider()

    {:ok, empty} = insert(context)
    await_state(empty, "completed")

    tip = indexed_tip!(context.author, %{title: "Unconfigured"})
    {:ok, failed} = insert(context)
    await_state(failed, "discarded")
    assert %{errors: [%{"error" => error}]} = Repo.get!(Oban.Job, failed.id)
    assert error =~ "OPENROUTER_API_KEY is missing or blank"
    assert %{embedding: nil, embed_after: nil} = search_row({:tip, tip.id})
    assert provider_inputs() == []
  end

  defp insert(%{oban: oban}), do: Oban.insert(oban, EmbedSearch.new(%{}))

  # Polls the committed job row until it reaches `state`, for at most five seconds.
  defp await_state(job, state, attempts \\ 500) do
    case Repo.get!(Oban.Job, job.id) do
      %{state: ^state} ->
        :ok

      %{state: other} when attempts == 0 ->
        flunk("job #{job.id} is #{other}, expected #{state}")

      _not_yet ->
        Process.sleep(10)
        await_state(job, state, attempts - 1)
    end
  end

  defp delete_jobs! do
    Repo.delete_all(from(j in Oban.Job, where: j.worker == "Tips.Workers.EmbedSearch"))
  end

  defp delete_owned!(author) do
    delete_jobs!()
    tip_ids = Repo.all(from(t in Tip, where: t.user_id == ^author.id, select: t.id))
    Repo.query!("DELETE FROM tip_search WHERE tip_id = ANY($1)", [tip_ids])
    Repo.delete_all(from(t in Tip, where: t.id in ^tip_ids))
    Repo.delete_all(from(u in User, where: u.id == ^author.id))
  end
end
