defmodule Tips.Content.Media do
  @moduledoc """
  Image attempts in R2 and video reservations in Cloudflare Stream.

  ## Images

  One image attempt validates the new image files of a selection and stores
  them in R2 for the content transaction.

  `store_images/2` takes the whole ordered `t:Tips.Content.attachment/0`
  selection. It counts every slot against the ten-attachment limit and the
  new files against the 50,000,000-byte allowance; retained attachments are
  counted but never re-uploaded. It parses every new file with
  `Tips.Content.Media.ImageParser` before storing any, one file at a time,
  so a rejected file stores nothing. It then puts each file under a fresh
  `media/<uuid>.<ext>` key with the extension and Content-Type of its parsed
  format, never its file name.

  The result is explicit data for the caller's transaction and cleanup:

    * `{:ok, images}` - one `t:stored_image/0` per new file, in selection
      order. The objects are unattached until the transaction commits. If it
      is known to have rolled back, the caller deletes them with
      `delete_images/2`. If its outcome is unknown, the caller deletes
      nothing; the orphan sweep removes objects that no media row references.
    * `{:error, :too_many_attachments}` and `{:error, :too_many_new_bytes}`.
    * `{:error, {:rejected_images, [{slot, reason}]}}` - every file the parser
      rejected, with `:too_large`, `:unsupported` or `:invalid`.
    * `{:error, :busy}` - no parser slot was free.
    * `{:error, {:upload_failed, [slot]}}` - a put failed. The attempt has
      deleted the objects it knows were stored; an object whose put outcome
      is unknown is left to the orphan sweep.

  Every error leaves the page's files in place for a retry, which stores
  them under new keys. Paths are valid only during the page attempt that
  owns them; nothing here keeps them.

  ## Video reservations

  `begin_video_upload/3` follows "Video states and deadlines" in the data
  model. One transaction locks the author, then share-locks the target's
  content, and inserts the `uploading` row with its one-hour deadline. After
  that commit, one Stream reservation request runs outside any lock, with
  privacy, the 180-second limit and the row's deadline as server-set
  metadata. A second transaction locks the row, then stores the uid only
  while the row is still `uploading`, without a uid, not in cleanup and
  before its deadline by wall time at that moment. The upload URL is returned
  only after that commit.

  No reservation is retried on the same row; a fresh upload gets a new row.
  A response that rejects the reservation marks the row `failed`. A lost
  response, or one the guard refuses, leaves the uid NULL: no browser has the
  URL, and the expiry worker retires the row locally at its deadline.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Tips.Accounts.{Scope, User}
  alias Tips.AdmissionLimiter
  alias Tips.Content
  alias Tips.Content.Media.{Asset, CloudflareStream, ImageParser, R2, Target}
  alias Tips.Content.{Publication, Review, Tip}
  alias Tips.Repo

  require Logger

  @max_attachments 10
  @max_new_bytes 50_000_000
  @max_video_bytes 1_000_000_000
  # The upload deadline after the row's `created_at`, also the reservation's expiry.
  @upload_seconds 3600

  @types %{
    png: {"png", "image/png"},
    jpeg: {"jpg", "image/jpeg"},
    webp: {"webp", "image/webp"},
    gif: {"gif", "image/gif"}
  }

  @typedoc "A new image stored in R2 but not yet attached."
  @type stored_image :: %{
          slot: Content.slot(),
          key: String.t(),
          content_type: String.t(),
          is_animated: boolean(),
          description: String.t() | nil
        }

  @type error ::
          :too_many_attachments
          | :too_many_new_bytes
          | {:rejected_images, [{Content.slot(), :too_large | :unsupported | :invalid}]}
          | :busy
          | {:upload_failed, [Content.slot()]}

  @typedoc "A reserved upload: the browser sends the bytes to `upload_url` by tus."
  @type video_upload :: %{
          media_id: Content.media_id(),
          upload_url: String.t(),
          expires_at: DateTime.t()
        }

  @doc "See `Tips.Content.begin_video_upload/3`."
  @spec begin_video_upload(Scope.t() | nil, term(), term(), keyword()) ::
          {:ok, video_upload()} | {:error, Content.video_upload_error()}
  def begin_video_upload(scope, target, file_attrs, opts \\ []) do
    unknown_on_database_error(fn ->
      with {:ok, user} <- author(scope),
           {:ok, %{target: target, size: size}} <- validate_upload(target, file_attrs),
           client = CloudflareStream.client!(opts),
           :ok <- unpublished(scope, target),
           :ok <- admit_upload(scope),
           {:ok, asset} <- insert_upload(user, target) do
        provision(client, asset, size)
      end
    end)
  end

  defp author(%Scope{user: %User{id: id} = user}) when is_integer(id), do: {:ok, user}
  defp author(_scope), do: {:error, :unauthenticated}

  defp validate_upload(target, file_attrs) do
    size = if is_map(file_attrs), do: Map.get(file_attrs, :size)

    {%{}, %{target: Target, size: :integer}}
    |> cast(%{target: target, size: size}, [:target, :size])
    |> validate_required([:target, :size])
    |> validate_number(:size, greater_than: 0, less_than_or_equal_to: @max_video_bytes)
    |> apply_action(:insert)
  end

  # A new-submission key the author already published needs an edit, not a new upload.
  defp unpublished(scope, {:new_tip, key}), do: published(Publication.get(scope, :tip, key, nil))

  defp unpublished(scope, {:new_review, tip_id, key}),
    do: published(Publication.get(scope, {:review, tip_id}, key, nil))

  defp unpublished(_scope, _edit_target), do: :ok

  defp published({:ok, nil}), do: :ok
  defp published({:ok, receipt}), do: {:error, {:published, receipt}}
  defp published({:error, _reason} = error), do: error

  defp admit_upload(scope) do
    case AdmissionLimiter.check_upload(scope) do
      :ok -> :ok
      {:error, {limit, _seconds}} = denied when limit in [:rate_limited, :capacity] -> denied
      {:error, :invalid_identity} -> {:error, :unauthenticated}
    end
  end

  defp insert_upload(user, target) do
    Repo.transact(fn ->
      with :ok <- Publication.lock_author(user.id),
           :ok <- lock_target(user.id, target) do
        created_at = DateTime.utc_now(:second)

        Repo.insert(%Asset{
          user_id: user.id,
          kind: :video,
          state: :uploading,
          target: target,
          created_at: created_at,
          expires_at: DateTime.add(created_at, @upload_seconds)
        })
      end
    end)
  end

  # The share lock holds the checked content until commit, after the author lock.
  defp lock_target(_user_id, {:new_tip, _key}), do: :ok

  defp lock_target(_user_id, {:new_review, tip_id, _key}),
    do: share_lock(from(t in Tip, where: t.id == ^tip_id and is_nil(t.dead_at)))

  defp lock_target(user_id, {:edit_tip, id}),
    do: share_lock(from(t in Tip, where: t.id == ^id and t.user_id == ^user_id))

  defp lock_target(user_id, {:edit_review, id}),
    do: share_lock(from(r in Review, where: r.id == ^id and r.user_id == ^user_id))

  defp share_lock(query) do
    query = from(c in query, where: is_nil(c.deleted_at), select: c.id, lock: "FOR SHARE")
    if Repo.one(query), do: :ok, else: {:error, :not_found}
  end

  defp provision(client, asset, size) do
    case CloudflareStream.reserve(client, size, asset.expires_at, "tips-media-#{asset.id}") do
      {:ok, %{uid: uid, url: url}} -> release(asset, uid, url)
      {:error, {:http, _status}} -> fail(asset)
      {:error, _uncertain} -> {:error, {:upload_failed, [asset.id]}}
    end
  end

  defp release(asset, uid, url) do
    Repo.transact(fn ->
      # The guard below reads the wall clock after this lock wait.
      Repo.all(
        from(a in Asset, where: a.id == ^asset.id, select: a.id, lock: "FOR NO KEY UPDATE")
      )

      reservable =
        from(a in unfinished(asset.id),
          where:
            datetime_add(a.created_at, ^@upload_seconds, "second") > fragment("clock_timestamp()")
        )

      case Repo.update_all(reservable, set: [stream_uid: uid]) do
        {1, _} -> {:ok, %{media_id: asset.id, upload_url: url, expires_at: asset.expires_at}}
        {0, _} -> {:error, {:upload_failed, [asset.id]}}
      end
    end)
  end

  defp fail(asset) do
    Repo.update_all(unfinished(asset.id), set: [state: :failed])
    {:error, {:upload_failed, [asset.id]}}
  end

  # A row no response has changed: a failed or cleanup row is never revived.
  defp unfinished(id) do
    from(a in Asset,
      where:
        a.id == ^id and a.state == :uploading and is_nil(a.stream_uid) and is_nil(a.cleanup_at)
    )
  end

  # A database error or lost connection leaves the outcome unknown: no URL is returned.
  defp unknown_on_database_error(fun) do
    fun.()
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.error("Video upload outcome unknown: #{database_reason(error)}")
      {:error, :outcome_unknown}
  end

  # Postgres details can quote submitted values; log only the code and message.
  defp database_reason(%Postgrex.Error{postgres: %{code: code, message: message}}),
    do: "#{code}: #{message}"

  defp database_reason(error), do: Exception.message(error)

  @doc """
  Validates and stores the new image files in `selection`. See the module
  documentation. `opts` are passed to `R2.client!/1`.
  """
  @spec store_images([Content.attachment()], keyword()) ::
          {:ok, [stored_image()]} | {:error, error()}
  def store_images(selection, opts \\ []) do
    files = for {:image_file, slot, file, description} <- selection, do: {slot, file, description}

    with :ok <- check_count(selection),
         :ok <- check_new_bytes(files),
         {:ok, parsed} <- parse(files) do
      put(parsed, opts)
    end
  end

  @doc """
  Deletes stored images whose transaction is known to have rolled back.
  Returns the keys whose deletion failed; the orphan sweep removes them.
  `opts` are passed to `R2.client!/1`.
  """
  @spec delete_images([stored_image()], keyword()) :: [String.t()]
  def delete_images(images, opts \\ []), do: delete(R2.client!(opts), images)

  defp delete(client, images) do
    for %{key: key} <- images, R2.delete(client, key) != :ok, do: key
  end

  defp check_count(selection) when length(selection) > @max_attachments,
    do: {:error, :too_many_attachments}

  defp check_count(_selection), do: :ok

  defp check_new_bytes(files) do
    sizes =
      for {_slot, %{path: path}, _description} <- files do
        case File.stat(path) do
          {:ok, %{size: size}} -> size
          {:error, _reason} -> 0
        end
      end

    if Enum.sum(sizes) > @max_new_bytes, do: {:error, :too_many_new_bytes}, else: :ok
  end

  defp parse(files) do
    files
    |> Enum.reduce_while({[], []}, fn {slot, file, description}, {parsed, rejected} ->
      case ImageParser.classify(file.path) do
        {:ok, image} -> {:cont, {[{slot, file, description, image} | parsed], rejected}}
        {:error, :busy} -> {:halt, :busy}
        {:error, reason} -> {:cont, {parsed, [{slot, reason} | rejected]}}
      end
    end)
    |> case do
      :busy -> {:error, :busy}
      {parsed, []} -> {:ok, Enum.reverse(parsed)}
      {_parsed, rejected} -> {:error, {:rejected_images, Enum.reverse(rejected)}}
    end
  end

  # A selection without new images needs no R2 client or settings.
  defp put([], _opts), do: {:ok, []}

  defp put(parsed, opts) do
    client = R2.client!(opts)

    parsed
    |> Enum.reduce_while([], fn {slot, file, description, image}, stored ->
      {extension, content_type} = @types[image.format]
      key = "media/#{Ecto.UUID.generate()}.#{extension}"

      with {:ok, body} <- File.read(file.path),
           :ok <- R2.put(client, key, body, content_type) do
        image = %{
          slot: slot,
          key: key,
          content_type: content_type,
          is_animated: image.animated,
          description: description(description)
        }

        {:cont, [image | stored]}
      else
        _error -> {:halt, {:failed, slot, stored}}
      end
    end)
    |> case do
      {:failed, slot, stored} ->
        delete(client, stored)
        {:error, {:upload_failed, [slot]}}

      stored ->
        {:ok, Enum.reverse(stored)}
    end
  end

  # Blank is no description, matching `media_description_chk`; anything else is kept verbatim.
  defp description(nil), do: nil
  defp description(text), do: if(String.trim(text) == "", do: nil, else: text)
end
