defmodule Tips.Repo.Migrations.AddMediaUploadEndpoint do
  use Ecto.Migration

  # A video's declared byte length and its tus endpoint, so a reloaded editor can
  # resume the same reservation (#85). Existing rows keep NULLs.

  def change do
    alter table(:media) do
      add :upload_length, :bigint
      add :upload_url, :text
    end

    create constraint(:media, :media_upload_length_chk,
             check:
               "upload_length is null or (kind = 'video' and upload_length between 1 and 1000000000)"
           )

    # The endpoint lives only while its transfer can still run.
    create constraint(:media, :media_upload_url_chk,
             check: """
             upload_url is null
               or (kind = 'video' and state = 'uploading' and stream_uid is not null and cleanup_at is null)
             """
           )
  end
end
