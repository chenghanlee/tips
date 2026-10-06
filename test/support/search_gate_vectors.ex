defmodule Tips.SearchGateVectors do
  @moduledoc """
  The frozen vectors of #365, `test/fixtures/search_probe/vectors-60.json`:
  the 40 document and ten query vectors that `scripts/search_gate_vectors.exs`
  recorded from the configured runtime, so tests can replay the gate's
  retrieval without the provider.

  `load!/2` writes the document vectors into the search tables of a corpus
  seeded with `Tips.SearchGate.seed_corpus/1`. It raises when a document is
  missing or its stored search text is not the text that was embedded.
  """

  import Ecto.Query

  alias Tips.Repo

  @path "test/fixtures/search_probe/vectors-60.json"

  @doc "Reads the fixture."
  def read!, do: @path |> File.read!() |> JSON.decode!()

  @doc """
  Stores each document vector of `fixture` on its row in `ids`, the map
  `Tips.SearchGate.seed_corpus/1` returns. Returns `fixture`.
  """
  def load!(ids, fixture \\ read!()) do
    for %{"id" => id, "search_text_sha256" => sha, "embedding" => embedding} <-
          fixture["documents"] do
      rows = rows(Map.fetch!(ids, id))

      unless rows |> select([s], s.search_text) |> Repo.one!() |> sha256() == sha do
        raise "#{id}: the stored search text is not the text that was embedded"
      end

      {1, _rows} =
        rows
        |> update([s], set: [embedding: fragment("?::text::vector", ^embedding)])
        |> Repo.update_all([])
    end

    fixture
  end

  @doc "Each recorded query vector by query id, as `Tips.Content.Search.search/3` takes it."
  def queries(fixture \\ read!()) do
    Map.new(fixture["queries"], fn %{"id" => id, "embedding" => embedding} ->
      {id, embedding |> String.slice(1..-2//1) |> String.split(",") |> Enum.map(&float/1)}
    end)
  end

  defp rows({:tip, id}), do: from(s in "tip_search", where: s.tip_id == ^id)
  defp rows({:review, id}), do: from(s in "review_search", where: s.review_id == ^id)

  defp float(value) do
    {float, ""} = Float.parse(value)
    float
  end

  defp sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
