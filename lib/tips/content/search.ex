defmodule Tips.Content.Search do
  @moduledoc """
  Owns search persistence inside caller-managed content transactions.

  Search text writes replace the document, advance its freshness token, and
  invalidate any prior embedding or retry cooldown. Document construction and
  normalization belong to the calling content operation.

  Embedding workers must guard both outcomes with the `text_at` value they read:

      update tip_search set embedding = $2
      where tip_id = $1 and embedding is null and text_at = $3

      update tip_search set embed_after = clock_timestamp() + interval '10 minutes'
      where tip_id = $1 and embedding is null and text_at = $3

  The corresponding review updates use `review_search` and `review_id`.
  """

  alias Tips.Repo

  @spec write_tip_text(tip_id :: pos_integer(), search_text :: String.t()) :: :ok
  def write_tip_text(tip_id, search_text) do
    write_text(:tip, tip_id, search_text)
  end

  @spec write_review_text(review_id :: pos_integer(), search_text :: String.t()) :: :ok
  def write_review_text(review_id, search_text) do
    write_text(:review, review_id, search_text)
  end

  defp write_text(kind, id, search_text) do
    unless Repo.in_transaction?() do
      raise ArgumentError, "search text writes require a caller transaction"
    end

    Repo.query!(upsert_sql(kind), [id, search_text])
    :ok
  end

  defp upsert_sql(:tip) do
    """
    INSERT INTO tip_search AS s
      (tip_id, search_text, text_at, embedding, embed_after)
    VALUES ($1, $2, clock_timestamp(), NULL, NULL)
    ON CONFLICT (tip_id) DO UPDATE SET
      search_text = EXCLUDED.search_text,
      text_at = greatest(clock_timestamp(), s.text_at + interval '1 microsecond'),
      embedding = NULL,
      embed_after = NULL
    """
  end

  defp upsert_sql(:review) do
    """
    INSERT INTO review_search AS s
      (review_id, search_text, text_at, embedding, embed_after)
    VALUES ($1, $2, clock_timestamp(), NULL, NULL)
    ON CONFLICT (review_id) DO UPDATE SET
      search_text = EXCLUDED.search_text,
      text_at = greatest(clock_timestamp(), s.text_at + interval '1 microsecond'),
      embedding = NULL,
      embed_after = NULL
    """
  end
end
