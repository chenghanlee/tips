defmodule Tips.SearchFixtures do
  @moduledoc "Indexed contributions, search-row state and a controlled embedding transport."

  import Tips.AccountsFixtures
  import Tips.ContentFixtures

  alias Tips.Content.Search
  alias Tips.Content.Search.EmbeddingProvider
  alias Tips.Repo

  @doc "Inserts a tip and writes its search document, as publication does."
  def indexed_tip!(user \\ user_fixture(), attrs \\ %{}) do
    tip = tip_fixture(user, attrs)
    {:ok, :ok} = Repo.transact(fn -> {:ok, Search.write_tip_text(tip.id)} end)
    tip
  end

  @doc "Inserts a review and writes its search document, as publication does."
  def indexed_review!(tip, attrs \\ %{}) do
    review = review_fixture(tip, attrs)
    {:ok, :ok} = Repo.transact(fn -> {:ok, Search.write_review_text(review.id)} end)
    review
  end

  @doc "Changes persisted content and rewrites its document through the shared writer."
  def edit!(%module{id: id} = content, changes) do
    {:ok, :ok} =
      Repo.transact(fn ->
        content |> Ecto.Changeset.change(changes) |> Repo.update!()

        case module do
          Tips.Content.Tip -> {:ok, Search.write_tip_text(id)}
          Tips.Content.Review -> {:ok, Search.write_review_text(id)}
        end
      end)

    :ok
  end

  @doc "The search row of `{kind, id}`: text, freshness token, embedding and cooldown."
  def search_row({kind, id}) do
    %{rows: [[text, token, embedding, embed_after]]} =
      Repo.query!(
        "SELECT search_text, text_at, embedding::text, embed_after FROM #{table(kind)} " <>
          "WHERE #{id_column(kind)} = $1",
        [id]
      )

    %{text: text, token: token, embedding: embedding, embed_after: embed_after}
  end

  @doc "Stores `vector` (a pgvector literal) directly, as another writer would."
  def put_embedding!({kind, id}, vector \\ unit_literal()) do
    Repo.query!(
      "UPDATE #{table(kind)} SET embedding = $2::text::vector(1024) WHERE #{id_column(kind)} = $1",
      [id, vector]
    )
  end

  @doc "Sets the row's cooldown `seconds` from now; negative values make it due."
  def put_cooldown!({kind, id}, seconds) do
    Repo.query!(
      "UPDATE #{table(kind)} SET embed_after = clock_timestamp() + make_interval(secs => $2) " <>
        "WHERE #{id_column(kind)} = $1",
      [id, seconds]
    )
  end

  @doc "A valid provider vector: `value` first, then zeros."
  def provider_vector(value \\ 1.0), do: [value | List.duplicate(0.0, 1023)]

  def unit_literal, do: "[" <> Enum.join([1 | List.duplicate(0, 1023)], ",") <> "]"

  @doc """
  Routes provider requests to `respond`, called with the conn and the requested input.

  Each request sends `{:provider_input, input}` to `test`. The default responds as
  the selected runtime does.
  """
  def stub_provider(respond \\ &respond_vector/2, test \\ self()) do
    Req.Test.stub(EmbeddingProvider, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"input" => [input]} = JSON.decode!(body)
      send(test, {:provider_input, input})
      respond.(conn, input)
    end)
  end

  @doc "Responds with one embedding and the selected runtime's identity."
  def respond_vector(conn, _input, vector \\ provider_vector(), identity \\ %{}) do
    Req.Test.json(
      conn,
      Map.merge(
        %{
          "data" => [%{"object" => "embedding", "index" => 0, "embedding" => vector}],
          "model" => "Qwen/Qwen3-Embedding-8B",
          "provider" => "Nebius"
        },
        identity
      )
    )
  end

  @doc "Every provider input received so far, in request order."
  def provider_inputs(acc \\ []) do
    receive do
      {:provider_input, input} -> provider_inputs([input | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "The first line of each input: the tip title or review body in these fixtures."
  def first_lines(inputs), do: Enum.map(inputs, &(&1 |> String.split("\n") |> hd()))

  defp table(:tip), do: "tip_search"
  defp table(:review), do: "review_search"

  defp id_column(:tip), do: "tip_id"
  defp id_column(:review), do: "review_id"
end
