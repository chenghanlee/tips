defmodule Tips.Content.Search.EmbeddingProviderTest do
  use ExUnit.Case, async: true

  import Tips.SearchFixtures

  alias Tips.Content.Search.EmbeddingProvider

  test "requests the selected runtime and returns the normalized vector" do
    test = self()
    document = String.duplicate("a", 29_998) <> "é"

    Req.Test.stub(EmbeddingProvider, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, JSON.decode!(body)})
      respond_vector(conn, nil, [3, 4 | List.duplicate(0, 1022)], %{"provider" => "nebius"})
    end)

    assert {:ok, vector} =
             EmbeddingProvider.embed_document(EmbeddingProvider.client!(api_key: "key"), document)

    assert [x, y | rest] =
             vector
             |> String.trim("[")
             |> String.trim("]")
             |> String.split(",")
             |> Enum.map(&String.to_float/1)

    assert_in_delta x, 0.6, 1.0e-7
    assert_in_delta y, 0.8, 1.0e-7
    assert rest == List.duplicate(0.0, 1022)

    assert_received {:request, conn, body}
    assert %{method: "POST", host: "openrouter.ai", request_path: "/api/v1/embeddings"} = conn
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer key"]

    assert body == %{
             "model" => "qwen/qwen3-embedding-8b",
             "input" => [document],
             "dimensions" => 1024,
             "provider" => %{"only" => ["nebius"], "allow_fallbacks" => false}
           }

    # Queries follow the gate's instruction directly, with no separator.
    assert {:ok, ^vector} =
             EmbeddingProvider.embed_query(EmbeddingProvider.client!(), "fix flaky tests")

    assert_received {:request, _conn, %{"input" => [query]}}

    assert query ==
             "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:fix flaky tests"
  end

  test "rejects invalid and oversized input without a request" do
    Req.Test.stub(EmbeddingProvider, fn _conn -> flunk("no request expected") end)
    client = EmbeddingProvider.client!()

    assert {:error, :too_large} =
             EmbeddingProvider.embed_document(client, String.duplicate("a", 30_001))

    assert {:error, :invalid_input} = EmbeddingProvider.embed_document(client, <<0xFF, "x">>)
    assert {:error, :invalid_input} = EmbeddingProvider.embed_document(client, " \n ")
  end

  test "classifies every response that is not one valid embedding" do
    zero = List.duplicate(0, 1024)

    cases = [
      {fn conn -> Plug.Conn.send_resp(conn, 200, "not json") end, :malformed},
      {&respond_vector(&1, nil, [1 | List.duplicate(0, 1022)]), :contract},
      {&respond_vector(&1, nil, provider_vector() ++ List.duplicate(0.0, 3072)), :contract},
      {&respond_vector(&1, nil, provider_vector(), %{"model" => "other/model"}), :contract},
      {&respond_vector(&1, nil, provider_vector(), %{"provider" => "DeepInfra"}), :contract},
      {&respond_vector(&1, nil, provider_vector(), %{"provider" => nil}), :malformed},
      {&respond_vector(&1, nil, zero), :malformed},
      {&respond_vector(&1, nil, provider_vector(1.0e39)), :malformed},
      {&respond_vector(&1, nil, ["1" | List.duplicate(0, 1023)]), :malformed},
      {&Req.Test.json(&1, %{"data" => [%{"index" => 1, "embedding" => provider_vector()}]}),
       :malformed},
      {&Req.Test.json(&1, %{"data" => []}), :malformed}
    ]

    for {respond, expected} <- cases do
      Req.Test.stub(EmbeddingProvider, respond)
      assert {:error, ^expected} = embed("document")
    end
  end

  test "makes exactly one attempt, whatever the outcome or caller options" do
    test = self()

    outcomes = [
      {fn conn -> Plug.Conn.send_resp(conn, 429, "") end, {:http, 429}},
      {fn conn -> Plug.Conn.send_resp(conn, 503, "") end, {:http, 503}},
      {fn conn -> Plug.Conn.send_resp(conn, 401, "") end, {:http, 401}},
      {&(&1
         |> Plug.Conn.put_resp_header("location", "/elsewhere")
         |> Plug.Conn.send_resp(307, "")), {:http, 307}},
      {&Req.Test.transport_error(&1, :econnrefused), :transport},
      {&Req.Test.transport_error(&1, :timeout), :deadline}
    ]

    for {respond, expected} <- outcomes do
      Req.Test.stub(EmbeddingProvider, fn conn ->
        send(test, {:attempt, conn.host, conn.request_path})
        respond.(conn)
      end)

      client = EmbeddingProvider.client!(retry: :transient, redirect: true, base_url: "http://x")
      assert {:error, ^expected} = EmbeddingProvider.embed_document(client, "document")
      assert_received {:attempt, "openrouter.ai", "/api/v1/embeddings"}
      refute_received {:attempt, _host, _path}
    end
  end

  test "the deadline kills the request, and so does the caller's exit" do
    test = self()

    Req.Test.stub(EmbeddingProvider, fn conn ->
      send(test, {:requesting, self()})
      Process.sleep(:infinity)
      conn
    end)

    assert %Req.Request{private: %{deadline: 30_000}} =
             EmbeddingProvider.client!(deadline: 60_000)

    # Long enough for the request to reach the stub under full-suite load.
    assert {:error, :deadline} =
             EmbeddingProvider.embed_document(
               EmbeddingProvider.client!(deadline: 500),
               "document"
             )

    assert_received {:requesting, request}
    refute Process.alive?(request)

    caller =
      spawn(fn ->
        receive do
          :go -> EmbeddingProvider.embed_document(EmbeddingProvider.client!(), "document")
        end
      end)

    Req.Test.allow(EmbeddingProvider, test, caller)
    send(caller, :go)
    assert_receive {:requesting, request}
    ref = Process.monitor(request)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^request, _reason}
  end

  @tag :capture_log
  test "a crashing or unstubbed request exits the caller instead of classifying" do
    test = self()
    Process.flag(:trap_exit, true)

    Req.Test.stub(EmbeddingProvider, fn _conn -> raise "provider adapter bug" end)
    assert {%RuntimeError{message: "provider adapter bug"}, _stack} = catch_exit(embed("x"))

    # A process with no stub reaches the test transport and fails, never the network.
    spawn(fn ->
      Process.flag(:trap_exit, true)
      send(test, {:unstubbed, catch_exit(embed("x"))})
    end)

    assert_receive {:unstubbed, {%RuntimeError{message: "cannot find mock/stub" <> _}, _stack}}
  end

  defp embed(text), do: EmbeddingProvider.embed_document(EmbeddingProvider.client!(), text)
end
