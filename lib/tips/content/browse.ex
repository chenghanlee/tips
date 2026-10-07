defmodule Tips.Content.Browse do
  @moduledoc """
  The Hot and New browse feed. See "Browsing" in `Tips.Content`.
  """

  import Ecto.Query

  alias Tips.Accounts.{Scope, User}
  alias Tips.Content.{Projection, Tip, Vocabulary, Vote}
  alias Tips.Repo

  @page_size 20
  @filters [:tag_id, :model_id, :environment_id]
  @options [:sort, :offset | @filters]

  @type page :: %{entries: [Projection.summary()], has_more: boolean()}

  @doc false
  @spec list_tips(Scope.t() | nil, keyword()) :: {:ok, page()} | {:error, :invalid_option}
  def list_tips(scope, opts) do
    with {:ok, options} <- options(opts) do
      {rows, lookahead} = options |> query() |> Repo.all() |> Enum.split(@page_size)
      votes = viewer_votes(scope, Enum.map(rows, fn {tip, _author} -> tip.id end))
      labels = Vocabulary.label_maps()

      entries =
        Enum.map(rows, fn {tip, author} ->
          hydration = %{author: author, labels: labels, viewer_vote: votes[tip.id]}
          Projection.summary(scope, tip, hydration)
        end)

      {:ok, %{entries: entries, has_more: lookahead != []}}
    end
  end

  @doc false
  # The page query for valid `opts`, with the lookahead row. Tests EXPLAIN it.
  def query(opts) when is_list(opts) do
    {:ok, options} = options(opts)
    query(options)
  end

  def query(%{sort: sort, offset: offset, filters: filters}) do
    # Same predicate as the partial indexes, so the planner can use them.
    from(t in Tip,
      join: u in assoc(t, :user),
      where: is_nil(t.deleted_at) and is_nil(t.dead_at),
      where: ^filters,
      order_by: ^order(sort),
      limit: @page_size + 1,
      offset: ^offset,
      select:
        {struct(t, [
           :id,
           :user_id,
           :title,
           :tag_id,
           :model_id,
           :model_other,
           :environment_id,
           :score,
           :review_count,
           :created_at,
           :deleted_at,
           :dead_at
         ]), struct(u, [:id, :handle, :deleted_at])}
    )
  end

  defp order(:hot), do: [desc: :hot_score, desc: :id]
  defp order(:new), do: [desc: :created_at, desc: :id]

  defp options(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         [] <- keys -- @options,
         true <- keys == Enum.uniq(keys),
         sort when sort in [:hot, :new] <- Keyword.get(opts, :sort, :hot),
         offset when is_integer(offset) and offset >= 0 and rem(offset, @page_size) == 0 <-
           Keyword.get(opts, :offset, 0),
         filters = Keyword.take(opts, @filters),
         true <- Enum.all?(filters, fn {_key, id} -> is_binary(id) end) do
      {:ok, %{sort: sort, offset: offset, filters: filters}}
    else
      _invalid -> {:error, :invalid_option}
    end
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
end
