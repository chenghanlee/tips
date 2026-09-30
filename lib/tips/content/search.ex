defmodule Tips.Content.Search do
  @moduledoc """
  Owns search documents inside caller-managed content transactions.

  `write_tip_text/1` and `write_review_text/1` are the writers for
  publication, searchable edits, retagging and label rebuilds. Each reads the
  persisted contribution with its own curated labels, builds the document and
  stores it. A write replaces the document, advances its freshness token, and
  invalidates any prior embedding or retry cooldown.

  A tip document is its title, body, prompt, output, tag label, model label
  (or free-text model) and environment label. A review document is its body,
  prompt, output, model label (or free-text model) and environment label; it
  never includes the parent tip's tag or setup. Each part has its Unicode
  whitespace trimmed and collapsed to single spaces; blank parts are skipped
  and the rest are joined with newlines. Case, punctuation and Unicode
  normalization form are kept, and stored content is never changed.

  Writers participate in the caller's transaction; they do not authorize,
  lock or check versions. The caller holds the contribution row under the
  shared lock order (tips by id, then reviews by id) before writing, so the
  document is built from the content it commits.

  ## Label rebuilds

  After changing a curated label, the maintenance caller rebuilds every
  affected contribution in the same transaction, calling the writer for each
  id. A retired label still referenced by content is indexed like any other.
  Affected ids:

    * tag: tips with `tag_id` = the tag;
    * model: tips and reviews with `model_id` = the model;
    * environment: tips and reviews with `environment_id` = the environment.

  Embedding workers must guard both outcomes with the `text_at` value they read:

      update tip_search set embedding = $2
      where tip_id = $1 and embedding is null and text_at = $3

      update tip_search set embed_after = clock_timestamp() + interval '10 minutes'
      where tip_id = $1 and embedding is null and text_at = $3

  The corresponding review updates use `review_search` and `review_id`.
  """

  import Ecto.Query

  alias Tips.Content.{Review, Tip}
  alias Tips.Repo

  @doc """
  Rebuilds the tip's search document from its persisted content and labels.

  Raises `Ecto.NoResultsError` when the tip does not exist.
  """
  @spec write_tip_text(tip_id :: pos_integer()) :: :ok
  def write_tip_text(tip_id) do
    ensure_transaction!()

    parts =
      Repo.one!(
        from t in Tip,
          join: tag in assoc(t, :tag),
          left_join: m in assoc(t, :model),
          left_join: e in assoc(t, :environment),
          where: t.id == ^tip_id,
          select: [
            t.title,
            t.body,
            t.prompt,
            t.output,
            tag.label,
            coalesce(m.label, t.model_other),
            e.label
          ]
      )

    write_tip_text(tip_id, document(parts))
  end

  @doc """
  Rebuilds the review's search document from its persisted content and own labels.

  Raises `Ecto.NoResultsError` when the review does not exist.
  """
  @spec write_review_text(review_id :: pos_integer()) :: :ok
  def write_review_text(review_id) do
    ensure_transaction!()

    parts =
      Repo.one!(
        from r in Review,
          left_join: m in assoc(r, :model),
          left_join: e in assoc(r, :environment),
          where: r.id == ^review_id,
          select: [r.body, r.prompt, r.output, coalesce(m.label, r.model_other), e.label]
      )

    write_review_text(review_id, document(parts))
  end

  @doc "Stores already-built tip search text. Prefer `write_tip_text/1`."
  @spec write_tip_text(tip_id :: pos_integer(), search_text :: String.t()) :: :ok
  def write_tip_text(tip_id, search_text) do
    write_text(:tip, tip_id, search_text)
  end

  @doc "Stores already-built review search text. Prefer `write_review_text/1`."
  @spec write_review_text(review_id :: pos_integer(), search_text :: String.t()) :: :ok
  def write_review_text(review_id, search_text) do
    write_text(:review, review_id, search_text)
  end

  defp document(parts) do
    parts
    |> Enum.map(&normalize/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp normalize(nil), do: ""
  defp normalize(text), do: ~r/\s+/u |> Regex.split(text, trim: true) |> Enum.join(" ")

  defp write_text(kind, id, search_text) do
    ensure_transaction!()
    Repo.query!(upsert_sql(kind), [id, search_text])
    :ok
  end

  defp ensure_transaction! do
    unless Repo.in_transaction?() do
      raise ArgumentError, "search text writes require a caller transaction"
    end
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
