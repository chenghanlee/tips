defmodule Tips.Content.Search do
  @moduledoc """
  Owns search documents and bounded hybrid retrieval.

  ## Retrieval

  `search/3` is the internal retrieval step behind the future public
  `Tips.Content.search_tips/3`, which owns query embedding, deadlines and
  keyword fallback. It ranks with `rank/2`, then projects with `hydrate/3`:

      {:ok, %{entries: [entry()], offset: offset, has_more: boolean()}}
      {:error, reason}

  Options:

    * `:offset` - final ranking offset; 0 through 180, divisible by 20.
      Default 0.
    * `:tag_id`, `:model_id`, `:environment_id` - an active curated id. Each
      filters the parent tip in every branch; a review's own setup or text
      never satisfies it.
    * `:embedding` - the query vector: 1024 numbers within float32 range, not
      all zero once rounded to float32. Only its direction is used.
      `nil` (default) runs only the two keyword branches.

  Errors, all returned before retrieval except `:unavailable`:

    * `:blank_query` - nothing but whitespace or NUL;
    * `:invalid_query` - not a valid UTF-8 string;
    * `:invalid_option` - not a keyword list, an unknown key or a repeated key;
    * `:invalid_offset`, `:invalid_filter`, `:invalid_embedding`;
    * `:unavailable` - a database error or timeout during ranking or
      hydration. It is never reported as an empty page.

  The query is ordinary text: NUL becomes a space and Unicode whitespace is
  collapsed. The pinned pg_textsearch parser reads it as a bag of English
  lexemes, so quotes, `&`, `|`, `!`, `:*` and pasted error text carry no
  engine syntax.

  ### Ranking

  Four branches each contribute at most 50 tips: tip keywords, tip vectors,
  review keywords and review vectors. A review branch first takes the best
  1000 reviews, then keeps the best review per tip. Keyword branches drop
  nonnegative BM25 scores, which are nonmatches, after their bounded
  candidate scan. Vector branches set `hnsw.iterative_scan = relaxed_order`
  for the transaction and re-sort the materialized candidates by distance.
  Reciprocal rank fusion (`1 / (60 + rank)`) sums each tip's branch scores
  into a window of at most 200 tips, ordered by score, then tip id. The best
  contributing review is the tip's matched review. The offset applies only to
  that window; candidate limits never grow with it. Search is public and
  live-only for every viewer, authors and moderators included.

  ### Hydration

  `hydrate/3` reloads the current rows; candidates authorize nothing. It drops
  a tip that is no longer live and omits a matched review that is no longer
  live or belongs to another tip, keeping the remaining order without
  refilling. Reads are batched: tips with authors, matched reviews, the
  viewer's votes and the curated labels. Each entry is:

      %{
        tip: Tips.Content.Projection.summary(),
        matched_review_id: pos_integer() | nil,
        excerpt: Tips.Content.Projection.excerpt() | nil
      }

  The excerpt comes from the first of the review's body, prompt, result and
  setup that shares an English lexeme with the query, or the body for a
  vector-only match. Its text is at most 280 characters around the first
  literal query word, with "…" marking cut ends.

  `has_more` is `true` when the returned page is not empty and the window
  continues past it. No total count is returned.

  ## Documents

  Search documents are written inside caller-managed content transactions.

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

  ### Label rebuilds

  Curated labels are stable in the MVP; a label change is rare, controlled
  maintenance, not a live edit. Before it starts, pause every content writer
  and let in-flight content transactions finish. Keep them paused until the
  maintenance transaction commits or rolls back. Otherwise a publication,
  edit or retag that read the old label, or moved content into the label,
  can keep a stale document. Nothing here enforces this precondition.

  In one transaction, the maintenance caller changes the label, selects the
  affected ids, locks them in the shared lock order and calls the writer for
  each. A retired label still referenced by content is indexed like any other.
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

  require Logger

  alias Tips.Accounts.{Scope, User}
  alias Tips.Content.{Environment, Model, Projection, Review, Tag, Tip, Vote}
  alias Tips.Repo

  @page_size 20
  @last_offset 180
  @branch_limit 50
  @review_cap 1000
  @rrf_k 60
  @dimensions 1024
  @float32_max 3.402_823_466_385_288_6e38
  @excerpt_length 280
  @excerpt_lead 80
  @filters [tag_id: Tag, model_id: Model, environment_id: Environment]
  @options [:offset, :embedding | Keyword.keys(@filters)]
  @sources [:body, :prompt, :result, :setup]

  @typedoc "One search result. See \"Hydration\"."
  @type entry :: %{
          tip: Projection.summary(),
          matched_review_id: pos_integer() | nil,
          excerpt: Projection.excerpt() | nil
        }

  @typedoc "A ranked tip and its best matching review, produced by `rank/2`."
  @type candidate :: %{tip_id: pos_integer(), review_id: pos_integer() | nil, score: float()}

  @type error ::
          :blank_query
          | :invalid_query
          | :invalid_option
          | :invalid_offset
          | :invalid_filter
          | :invalid_embedding
          | :unavailable

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

  @doc """
  Ranks and hydrates one page of search results. See "Retrieval".
  """
  @spec search(Scope.t() | nil, String.t(), keyword()) ::
          {:ok, %{entries: [entry()], offset: non_neg_integer(), has_more: boolean()}}
          | {:error, error()}
  def search(scope, query, opts \\ []) do
    with {:ok, %{candidates: candidates, offset: offset, total: total}} <- rank(query, opts) do
      entries = hydrate(scope, query, candidates)
      has_more = entries != [] and offset + @page_size < total
      {:ok, %{entries: entries, offset: offset, has_more: has_more}}
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> unavailable(error)
  end

  @doc """
  Retrieves one page of the bounded ranking, without hydration.

  `total` is the window size, at most 200; it is 0 when the page is empty.
  Internal: the result is server-produced input for `hydrate/3`.
  """
  @spec rank(String.t(), keyword()) ::
          {:ok, %{candidates: [candidate()], offset: non_neg_integer(), total: non_neg_integer()}}
          | {:error, error()}
  def rank(query, opts) do
    with {:ok, statement} <- ranking_statement(query, opts), do: retrieve(statement)
  end

  @doc false
  # The validated ranking SQL, its parameters and the transaction-local
  # settings it runs with. Tests EXPLAIN this exact statement.
  def ranking_statement(query, opts) do
    with {:ok, query} <- normalize_query(query),
         {:ok, options} <- options(opts),
         :ok <- active_filters(options.filters) do
      {:ok, statement(query, options)}
    end
  end

  @doc """
  Projects ranked candidates from current rows, in rank order. See "Hydration".

  Internal: `candidates` must come from `rank/2` for the same `query`.
  """
  @spec hydrate(Scope.t() | nil, String.t(), [
          %{required(:tip_id) => pos_integer(), required(:review_id) => pos_integer() | nil}
        ]) :: [entry()]
  def hydrate(_scope, _query, []), do: []

  def hydrate(scope, query, candidates) do
    {:ok, query} = normalize_query(query)

    case live_tips(Enum.map(candidates, & &1.tip_id)) do
      tips when map_size(tips) == 0 ->
        []

      tips ->
        candidates = Enum.filter(candidates, &Map.has_key?(tips, &1.tip_id))

        loaded = %{
          tips: tips,
          reviews: matched_reviews(query, candidates),
          votes: viewer_votes(scope, Map.keys(tips)),
          labels: labels()
        }

        Enum.map(candidates, &entry(scope, query, &1, loaded))
    end
  end

  defp unavailable(error) do
    Logger.error("search retrieval failed: " <> Exception.message(error))
    {:error, :unavailable}
  end

  ## Validation

  defp normalize_query(query) when is_binary(query) do
    if String.valid?(query) do
      case query |> String.replace("\0", " ") |> normalize() do
        "" -> {:error, :blank_query}
        query -> {:ok, query}
      end
    else
      {:error, :invalid_query}
    end
  end

  defp normalize_query(_query), do: {:error, :invalid_query}

  defp options(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         [] <- keys -- @options,
         true <- keys == Enum.uniq(keys),
         {:ok, offset} <- offset(Keyword.get(opts, :offset, 0)),
         {:ok, vector} <- vector(Keyword.get(opts, :embedding)) do
      {:ok,
       %{offset: offset, vector: vector, filters: Keyword.take(opts, Keyword.keys(@filters))}}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_option}
    end
  end

  defp offset(offset)
       when is_integer(offset) and offset in 0..@last_offset and rem(offset, @page_size) == 0,
       do: {:ok, offset}

  defp offset(_offset), do: {:error, :invalid_offset}

  defp vector(nil), do: {:ok, nil}

  # pgvector stores float32 values and sums float32 products, so cosine needs a
  # direction that survives both. A vector that rounds to zero has none. Any
  # other is scaled by its largest magnitude before squaring, so no square
  # overflows or underflows, then sent as a unit vector.
  defp vector(values) when is_list(values) and length(values) == @dimensions do
    with true <- Enum.all?(values, &finite?/1),
         floats = Enum.map(values, &float32/1),
         largest when largest > 0 <- floats |> Enum.map(&abs/1) |> Enum.max() do
      scaled = Enum.map(floats, &(&1 / largest))
      norm = :math.sqrt(Enum.reduce(scaled, 0.0, &(&1 * &1 + &2)))
      {:ok, "[" <> Enum.map_join(scaled, ",", &Float.to_string(float32(&1 / norm))) <> "]"}
    else
      _zero_or_out_of_range -> {:error, :invalid_embedding}
    end
  end

  defp vector(_values), do: {:error, :invalid_embedding}

  defp finite?(value), do: is_number(value) and abs(value) <= @float32_max

  defp float32(value) do
    <<float::float-32>> = <<value::float-32>>
    float
  end

  defp active_filters(filters) do
    if Enum.all?(filters, fn {key, id} -> is_binary(id) and active?(@filters[key], id) end),
      do: :ok,
      else: {:error, :invalid_filter}
  end

  defp active?(schema, id), do: Repo.exists?(from c in schema, where: c.id == ^id and c.active)

  ## Ranking

  defp statement(query, %{offset: offset, vector: vector, filters: filters}) do
    vector_params = if vector, do: [vector], else: []
    first_filter = 3 + length(vector_params)

    predicates =
      filters
      |> Enum.with_index(first_filter)
      |> Enum.map_join(fn {{column, _id}, index} -> " AND t.#{column} = $#{index}" end)

    branches = [{"tips_bm25", false}, {"reviews_bm25", true}]
    vector_branches = if vector, do: [{"tips_vec", false}, {"reviews_vec", true}], else: []

    ctes =
      [lexical_ctes(predicates) | if(vector, do: [vector_ctes(predicates)], else: [])]
      |> Enum.join(",\n")

    %{
      sql: ranking_sql(ctes, branches ++ vector_branches),
      params: [query, offset | vector_params] ++ Keyword.values(filters),
      settings: if(vector, do: ["SET LOCAL hnsw.iterative_scan = relaxed_order"], else: []),
      offset: offset
    }
  end

  @live_tip "t.deleted_at IS NULL AND t.dead_at IS NULL"
  @live_review "r.deleted_at IS NULL AND r.dead_at IS NULL"

  # Keyword scans keep their bounded ORDER BY ... LIMIT candidate subquery
  # and drop nonmatches (scores >= 0) outside it, before rank and collapse.
  defp lexical_ctes(predicates) do
    """
    tips_bm25 AS (
      SELECT tip_id, row_number() OVER (ORDER BY d, tip_id) AS rank
      FROM (
        SELECT s.tip_id, s.search_text <@> to_bm25query($1, 'tips_bm25') AS d
        FROM tip_search s
        JOIN tips t ON t.id = s.tip_id AND #{@live_tip}#{predicates}
        ORDER BY d, s.tip_id
        LIMIT #{@branch_limit}
      ) c
      WHERE d < 0
    ),
    reviews_bm25 AS (
      SELECT tip_id, review_id, row_number() OVER (ORDER BY d, tip_id) AS rank
      FROM (
        SELECT DISTINCT ON (tip_id) tip_id, review_id, d
        FROM (
          SELECT s.review_id, r.tip_id, s.search_text <@> to_bm25query($1, 'reviews_bm25') AS d
          FROM review_search s
          JOIN reviews r ON r.id = s.review_id AND #{@live_review}
          JOIN tips t ON t.id = r.tip_id AND #{@live_tip}#{predicates}
          ORDER BY d, s.review_id
          LIMIT #{@review_cap}
        ) c
        WHERE d < 0
        ORDER BY tip_id, d, review_id
      ) best
      ORDER BY d, tip_id
      LIMIT #{@branch_limit}
    )
    """
  end

  # Relaxed iterative HNSW scans can return candidates slightly out of order,
  # so each scan is materialized and sorted again; `d + 0` forces that sort.
  defp vector_ctes(predicates) do
    """
    tips_vec_c AS MATERIALIZED (
      SELECT s.tip_id, s.embedding <=> $3::text::vector(#{@dimensions}) AS d
      FROM tip_search s
      JOIN tips t ON t.id = s.tip_id AND #{@live_tip}#{predicates}
      WHERE s.embedding IS NOT NULL
      ORDER BY d
      LIMIT #{@branch_limit}
    ),
    tips_vec AS (
      SELECT tip_id, row_number() OVER (ORDER BY d + 0, tip_id) AS rank FROM tips_vec_c
    ),
    reviews_vec_c AS MATERIALIZED (
      SELECT s.review_id, r.tip_id, s.embedding <=> $3::text::vector(#{@dimensions}) AS d
      FROM review_search s
      JOIN reviews r ON r.id = s.review_id AND #{@live_review}
      JOIN tips t ON t.id = r.tip_id AND #{@live_tip}#{predicates}
      WHERE s.embedding IS NOT NULL
      ORDER BY d
      LIMIT #{@review_cap}
    ),
    reviews_vec AS (
      SELECT tip_id, review_id, row_number() OVER (ORDER BY d + 0, tip_id) AS rank
      FROM (
        SELECT DISTINCT ON (tip_id) tip_id, review_id, d
        FROM reviews_vec_c
        ORDER BY tip_id, d + 0, review_id
      ) best
      ORDER BY d + 0, tip_id
      LIMIT #{@branch_limit}
    )
    """
  end

  defp ranking_sql(ctes, branches) do
    fused =
      Enum.map_join(branches, "\n  UNION ALL\n", fn {name, review?} ->
        review_id = if review?, do: "review_id", else: "NULL::bigint"
        "  SELECT tip_id, #{review_id} AS review_id, 1.0 / (#{@rrf_k} + rank) AS s FROM #{name}"
      end)

    """
    WITH #{ctes},
    fused AS (
    #{fused}
    ),
    ranked AS (
      SELECT tip_id, sum(s) AS score,
             (array_agg(review_id ORDER BY s DESC, review_id)
                FILTER (WHERE review_id IS NOT NULL))[1] AS review_id
      FROM fused
      GROUP BY tip_id
    )
    SELECT tip_id, review_id, score::float8, count(*) OVER () AS total
    FROM ranked
    ORDER BY score DESC, tip_id
    LIMIT #{@page_size} OFFSET $2
    """
  end

  defp retrieve(statement) do
    case Repo.transact(fn -> run(statement) end) do
      {:ok, result} -> {:ok, result}
      {:error, error} -> unavailable(error)
    end
  end

  defp run(%{settings: settings, sql: sql, params: params, offset: offset}) do
    with :ok <- apply_settings(settings),
         {:ok, %{rows: rows}} <- Repo.query(sql, params) do
      candidates =
        Enum.map(rows, fn [tip_id, review_id, score, _total] ->
          %{tip_id: tip_id, review_id: review_id, score: score}
        end)

      total =
        case rows do
          [[_tip_id, _review_id, _score, total] | _rest] -> total
          [] -> 0
        end

      {:ok, %{candidates: candidates, offset: offset, total: total}}
    end
  end

  defp apply_settings(settings) do
    Enum.reduce_while(settings, :ok, fn setting, :ok ->
      case Repo.query(setting) do
        {:ok, _result} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  ## Hydration

  defp entry(scope, query, %{tip_id: tip_id, review_id: review_id}, loaded) do
    {tip, author} = Map.fetch!(loaded.tips, tip_id)
    hydration = %{author: author, labels: loaded.labels, viewer_vote: loaded.votes[tip_id]}
    summary = Projection.summary(scope, tip, hydration)

    case excerpt(scope, query, tip, loaded.reviews[review_id], loaded.labels) do
      nil -> %{tip: summary, matched_review_id: nil, excerpt: nil}
      excerpt -> %{tip: summary, matched_review_id: review_id, excerpt: excerpt}
    end
  end

  defp live_tips(ids) do
    from(t in Tip,
      join: u in assoc(t, :user),
      where: t.id in ^ids and is_nil(t.deleted_at) and is_nil(t.dead_at),
      select: {t, u}
    )
    |> Repo.all()
    |> Map.new(fn {tip, author} -> {tip.id, {tip, author}} end)
  end

  defmacrop shares_lexeme(text, query) do
    quote do
      fragment(
        "tsvector_to_array(to_tsvector('english', coalesce(?, ''))) && tsvector_to_array(to_tsvector('english', ?))",
        unquote(text),
        unquote(query)
      )
    end
  end

  # Reloads live matched reviews of their candidate tips, with the first source
  # that shares an English lexeme with the query.
  defp matched_reviews(query, candidates) do
    parents = for %{review_id: id, tip_id: tip_id} <- candidates, id, into: %{}, do: {id, tip_id}

    if map_size(parents) == 0 do
      %{}
    else
      ids = Map.keys(parents)

      from(r in Review,
        left_join: m in assoc(r, :model),
        left_join: e in assoc(r, :environment),
        where: r.id in ^ids and is_nil(r.deleted_at) and is_nil(r.dead_at),
        select:
          {r,
           [
             shares_lexeme(r.body, ^query),
             shares_lexeme(r.prompt, ^query),
             shares_lexeme(r.output, ^query),
             shares_lexeme(
               fragment("concat_ws(' ', coalesce(?, ?), ?)", m.label, r.model_other, e.label),
               ^query
             )
           ]}
      )
      |> Repo.all()
      |> Enum.filter(fn {review, _matches} -> parents[review.id] == review.tip_id end)
      |> Map.new(fn {review, matches} -> {review.id, {review, source(matches)}} end)
    end
  end

  defp source(matches) do
    Enum.find_value(Enum.zip(@sources, matches), :body, fn {source, match?} ->
      match? && source
    end)
  end

  defp viewer_votes(%Scope{user: %User{id: user_id}}, tip_ids) do
    from(v in Vote,
      where: v.user_id == ^user_id and v.tip_id in ^tip_ids,
      select: {v.tip_id, v.value}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp viewer_votes(nil, _tip_ids), do: %{}

  defp labels do
    %{tags: label_map(Tag), models: label_map(Model), environments: label_map(Environment)}
  end

  defp label_map(schema), do: Map.new(Repo.all(from c in schema, select: {c.id, c.label}))

  defp excerpt(_scope, _query, _tip, nil, _labels), do: nil

  defp excerpt(scope, query, tip, {review, source}, labels) do
    case Projection.excerpt(scope, review, source, %{parent: tip, labels: labels}) do
      %{text: text} = excerpt -> %{excerpt | text: window(normalize(text), query)}
      nil -> nil
    end
  end

  defp window(text, query) do
    length = String.length(text)

    if length <= @excerpt_length do
      text
    else
      start =
        (first_match(text, query) - @excerpt_lead) |> max(0) |> min(length - @excerpt_length)

      prefix = if start > 0, do: "…", else: ""
      suffix = if start + @excerpt_length < length, do: "…", else: ""
      prefix <> String.slice(text, start, @excerpt_length) <> suffix
    end
  end

  # Character position of the earliest literal query word, or 0.
  defp first_match(text, query) do
    haystack = String.downcase(text)

    ~r/[\p{L}\p{N}]+/u
    |> Regex.scan(String.downcase(query))
    |> List.flatten()
    |> Enum.flat_map(fn word ->
      case :binary.match(haystack, word) do
        {byte, _length} -> [String.length(binary_part(haystack, 0, byte))]
        :nomatch -> []
      end
    end)
    |> Enum.min(fn -> 0 end)
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
