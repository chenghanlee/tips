defmodule Tips.Repo.Migrations.CreateVotesAndCounters do
  use Ecto.Migration

  def change do
    create table(:votes, primary_key: false) do
      add :user_id, references(:users, on_delete: :nothing), null: false
      add :tip_id, references(:tips, on_delete: :nothing)
      add :review_id, references(:reviews, on_delete: :nothing)
      add :value, :smallint, null: false
      add :created_at, :timestamptz, null: false, default: fragment("now()")
    end

    create constraint(:votes, :votes_one_target, check: "num_nonnulls(tip_id, review_id) = 1")
    create constraint(:votes, :votes_value_chk, check: "value in (-1, 1)")

    create unique_index(:votes, [:user_id, :tip_id],
             where: "tip_id is not null",
             name: :votes_one_per_tip
           )

    create unique_index(:votes, [:user_id, :review_id],
             where: "review_id is not null",
             name: :votes_one_per_review
           )

    create index(:votes, [:tip_id, "created_at DESC"],
             where: "tip_id is not null",
             name: :votes_by_tip
           )

    create index(:votes, [:review_id, "created_at DESC"],
             where: "review_id is not null",
             name: :votes_by_review
           )

    execute """
            create function vote_counts() returns trigger language plpgsql as $$
            declare d_up int := 0; d_down int := 0; tip bigint; rev bigint;
            begin
              if tg_op in ('UPDATE', 'DELETE') then
                if old.value = 1 then d_up := d_up - 1; else d_down := d_down - 1; end if; end if;
              if tg_op in ('INSERT', 'UPDATE') then
                if new.value = 1 then d_up := d_up + 1; else d_down := d_down + 1; end if; end if;
              if d_up = 0 and d_down = 0 then return null; end if;
              if tg_op = 'DELETE' then tip := old.tip_id; rev := old.review_id; else tip := new.tip_id; rev := new.review_id; end if;
              if tip is not null then update tips    set up_count = up_count + d_up, down_count = down_count + d_down where id = tip;
              else                    update reviews set up_count = up_count + d_up, down_count = down_count + d_down where id = rev; end if;
              return null;
            end $$;
            """,
            "DROP FUNCTION vote_counts()"

    execute "create trigger votes_counts after insert or update or delete on votes for each row execute function vote_counts();",
            "DROP TRIGGER votes_counts ON votes"

    execute """
            create function review_counts() returns trigger language plpgsql as $$
            declare was int := 0; is_ int := 0;
            begin
              if tg_op in ('UPDATE', 'DELETE') and old.deleted_at is null and old.dead_at is null then was := 1; end if;
              if tg_op in ('INSERT', 'UPDATE') and new.deleted_at is null and new.dead_at is null then is_ := 1; end if;
              if was = is_ then return null; end if;
              update tips set review_count = review_count + is_ - was where id = coalesce(new.tip_id, old.tip_id);
              return null;
            end $$;
            """,
            "DROP FUNCTION review_counts()"

    execute "create trigger reviews_counts after insert or update or delete on reviews for each row execute function review_counts();",
            "DROP TRIGGER reviews_counts ON reviews"
  end
end
