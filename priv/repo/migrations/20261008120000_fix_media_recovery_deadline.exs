defmodule Tips.Repo.Migrations.FixMediaRecoveryDeadline do
  use Ecto.Migration

  # Stream records no completion time (#243). A completed upload keeps the fixed
  # recovery deadline `created_at + 49 hours`; see "Video states and deadlines" in
  # the data model.

  def up do
    drop constraint(:media, :media_storage_chk)
    drop constraint(:media, :media_ready_chk)

    alter table(:media) do
      remove :completed_at
    end

    create constraint(:media, :media_storage_chk,
             check: """
             (kind = 'image' and is_animated is not null and key is not null and stream_uid is null and state is null
               and target is null and duration_s is null
               and expires_at is null and reconcile_after is null
               and num_nonnulls(tip_id, review_id) = 1)
             or
             (kind = 'video' and description is null and is_animated is null and key is null and target is not null and state is not null
               and (state not in ('processing', 'ready') or stream_uid is not null))
             """
           )

    create constraint(:media, :media_ready_chk,
             check: """
             state is distinct from 'ready'
               or (duration_s is not null and duration_s > 0 and duration_s <= 180 and stream_uid is not null)
             """
           )

    # A known-uid row that left 'uploading' has completed its transfer and holds the recovery deadline.
    # Existing deadlines move to that fixed value first; a NULL expiry stays NULL.
    execute """
    update media set expires_at = created_at +
      case when stream_uid is not null and state <> 'uploading' then interval '49 hours' else interval '1 hour' end
    where expires_at is not null
    """

    create constraint(:media, :media_deadline_chk,
             check: """
             expires_at is null or expires_at = created_at +
               case when stream_uid is not null and state <> 'uploading' then interval '49 hours' else interval '1 hour' end
             """
           )
  end

  def down do
    drop constraint(:media, :media_deadline_chk)
    drop constraint(:media, :media_ready_chk)
    drop constraint(:media, :media_storage_chk)

    alter table(:media) do
      add :completed_at, :timestamptz
    end

    # The old ready check needs a completion time no row recorded; the reservation time stands in.
    execute "update media set completed_at = created_at where state = 'ready'"

    create constraint(:media, :media_storage_chk,
             check: """
             (kind = 'image' and is_animated is not null and key is not null and stream_uid is null and state is null
               and target is null and duration_s is null and completed_at is null
               and expires_at is null and reconcile_after is null
               and num_nonnulls(tip_id, review_id) = 1)
             or
             (kind = 'video' and description is null and is_animated is null and key is null and target is not null and state is not null
               and (state not in ('processing', 'ready') or stream_uid is not null))
             """
           )

    create constraint(:media, :media_ready_chk,
             check: """
             state is distinct from 'ready'
               or (duration_s is not null and duration_s > 0 and duration_s <= 180
                   and completed_at is not null and stream_uid is not null)
             """
           )
  end
end
