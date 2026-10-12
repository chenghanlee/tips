defmodule Tips.Workers.CleanupMedia do
  @moduledoc """
  Deletes the provider objects of one media row in cleanup, then the row.

  `Tips.Content.Media.retire/1` enqueues one job per row in the removal
  transaction; `Tips.Content.Media.enqueue_cleanup/1` re-creates one that
  pruning removed. Outside any transaction the job deletes the Stream video
  when the row has a uid, then the R2 object when it has a key. A missing
  object counts as deleted, and every step runs again on every attempt, so a
  lost confirmation is safe to repeat. Any provider error returns
  `{:error, reason}` for Oban to retry, and the row keeps its identifiers.
  After both steps the row is deleted, only while it is still in cleanup. A
  missing row, or one not in cleanup, cancels the job and deletes nothing.

  There is no cache purge until M4, so a deleted image may be served from the
  edge until its one-hour cache lifetime ends.
  """
  use Oban.Worker,
    queue: :media,
    max_attempts: 10,
    unique: [period: :infinity, states: :incomplete, keys: [:media_id]]

  import Ecto.Query

  alias Tips.Content.Media.{Asset, CloudflareStream, R2}
  alias Tips.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_id" => id}}) do
    case Repo.get(Asset, id) do
      %Asset{cleanup_at: %DateTime{}} = asset ->
        with :ok <- delete_video(asset.stream_uid),
             :ok <- delete_image(asset.key) do
          Repo.delete_all(from(a in Asset, where: a.id == ^id and not is_nil(a.cleanup_at)))
          :ok
        end

      %Asset{cleanup_at: nil} ->
        {:cancel, :not_in_cleanup}

      nil ->
        {:cancel, :not_found}
    end
  end

  defp delete_video(nil), do: :ok
  defp delete_video(uid), do: CloudflareStream.delete(CloudflareStream.client!(), uid)

  defp delete_image(nil), do: :ok
  defp delete_image(key), do: R2.delete(R2.client!(), key)
end
