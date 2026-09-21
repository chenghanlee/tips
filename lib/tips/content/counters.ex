defmodule Tips.Content.Counters do
  @moduledoc "Operator repair for the counters normally maintained by database triggers."

  alias Tips.Repo

  @doc """
  Recounts stored votes and live reviews in one transaction.

  Operator-only: pause writes and wait for open write transactions to finish first.
  This function does not enforce that precondition. Returns
  `{tips_updated, reviews_updated}`, counting only rows that needed correction.
  """
  def recount! do
    {:ok, counts} =
      Repo.transaction(fn ->
        %{num_rows: tips} =
          Repo.query!("""
          with v as (select tip_id, count(*) filter (where value = 1) as up, count(*) filter (where value = -1) as down
                     from votes where tip_id is not null group by tip_id),
               r as (select tip_id, count(*) as n from reviews where deleted_at is null and dead_at is null group by tip_id)
          update tips t set up_count = coalesce(v.up, 0), down_count = coalesce(v.down, 0), review_count = coalesce(r.n, 0)
          from tips x left join v on v.tip_id = x.id left join r on r.tip_id = x.id
          where t.id = x.id and (t.up_count, t.down_count, t.review_count) is distinct from (coalesce(v.up, 0), coalesce(v.down, 0), coalesce(r.n, 0));
          """)

        %{num_rows: reviews} =
          Repo.query!("""
          with v as (select review_id, count(*) filter (where value = 1) as up, count(*) filter (where value = -1) as down
                     from votes where review_id is not null group by review_id)
          update reviews r set up_count = coalesce(v.up, 0), down_count = coalesce(v.down, 0)
          from reviews x left join v on v.review_id = x.id
          where r.id = x.id and (r.up_count, r.down_count) is distinct from (coalesce(v.up, 0), coalesce(v.down, 0));
          """)

        {tips, reviews}
      end)

    counts
  end
end
