defmodule Tips.Workers.EmbedSearchTest do
  use Tips.EmbeddingCase, async: false

  alias Tips.Content.Search.EmbeddingProvider.OpenRouter

  setup do
    %{oban: start_oban!()}
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
    provider = Application.fetch_env!(:tips, OpenRouter)
    provider_config = Application.fetch_env!(:tips, Tips.ProviderConfig)

    on_exit(fn ->
      Application.put_env(:tips, OpenRouter, provider)
      Application.put_env(:tips, Tips.ProviderConfig, provider_config)
    end)

    # Defeat both the synthetic test key and any key in the checkout's .env.
    Application.put_env(:tips, OpenRouter, Keyword.delete(provider, :api_key))
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

  defp insert(%{oban: oban}), do: insert_scan(oban)
end
