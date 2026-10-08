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
  URL, and the expiry worker (#66) retires the row locally at its deadline.

  ## Video status

  `get_video_uploads/3` reads Stream only for owned, unattached, known-uid rows
  that are `uploading` or `processing` and not in cleanup, including rows past
  their upload deadline. At most three reads run at once, outside any
  transaction. Each result goes through `transition_video/3`, the guarded
  transition the expiry worker (#66) shares: one conditional `UPDATE` whose
  `WHERE` Postgres re-evaluates on the current row after any lock wait, so a
  late result cannot change a row that has since moved on, been attached or
  entered cleanup. The first state after `pendingupload` sets the fixed
  recovery deadline, `created_at` plus 49 hours, whenever it is observed. A
  `pendingupload` result, a timeout, an error or a rate limit writes nothing.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Tips.Accounts
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
  # The recovery deadline of a completed upload after the row's `created_at`.
  @recovery_seconds 49 * 3600
  @max_video_seconds 180
  @max_id 9_223_372_036_854_775_807
  # Status reads in flight at once for one call.
  @status_concurrency 3
  # Each read has 5-second connect and receive timeouts; this ends one that outlives both.
  @status_timeout_ms 11_000

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

  @typedoc """
  An upload's committed state after a refresh. `:removed` is a row in cleanup
  or gone. `refresh` is `:uncertain` when its status read timed out or failed,
  and `:rate_limited` when Stream refused it; the state is then unchanged.
  """
  @type video_status :: %{
          media_id: Content.media_id(),
          state: :uploading | :processing | :ready | :failed | :removed,
          expires_at: DateTime.t() | nil,
          refresh: :ok | :uncertain | :rate_limited
        }

  @typedoc "A trusted Stream result that completes an upload or its processing."
  @type observation :: :processing | {:ready, duration_s :: float()} | :failed

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
  defp lock_target(user_id, target) do
    case target_query(user_id, target) do
      nil -> :ok
      query -> found(from(c in query, lock: "FOR SHARE"))
    end
  end

  defp live_target(user_id, target) do
    case target_query(user_id, target) do
      nil -> :ok
      query -> found(query)
    end
  end

  # The content an upload target needs: a live parent tip, or the author's own undeleted item.
  defp target_query(_user_id, {:new_tip, _key}), do: nil

  defp target_query(_user_id, {:new_review, tip_id, _key}),
    do: live(from(t in Tip, where: t.id == ^tip_id and is_nil(t.dead_at)))

  defp target_query(user_id, {:edit_tip, id}),
    do: live(from(t in Tip, where: t.id == ^id and t.user_id == ^user_id))

  defp target_query(user_id, {:edit_review, id}),
    do: live(from(r in Review, where: r.id == ^id and r.user_id == ^user_id))

  defp live(query), do: from(c in query, where: is_nil(c.deleted_at), select: c.id)

  defp found(query), do: if(Repo.one(query), do: :ok, else: {:error, :not_found})

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
            fragment(
              "? + ? * interval '1 second' > clock_timestamp()",
              a.created_at,
              ^@upload_seconds
            )
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

  @doc "See `Tips.Content.get_video_uploads/2`. `opts` are passed to `CloudflareStream.client!/1`."
  @spec get_video_uploads(Scope.t() | nil, term(), keyword()) ::
          {:ok, [video_status()]} | {:error, Content.video_status_error()}
  def get_video_uploads(scope, upload_ids, opts \\ []) do
    unknown_on_database_error(fn ->
      with {:ok, user} <- author(scope),
           {:ok, ids} <- validate_upload_ids(upload_ids),
           :ok <- readmit(user),
           {:ok, assets} <- owned_videos(user.id, ids),
           :ok <- live_targets(user.id, assets) do
        refreshes = assets |> Enum.filter(&pending?/1) |> refresh(opts)
        {:ok, statuses(ids, refreshes)}
      end
    end)
  end

  defp validate_upload_ids(upload_ids) do
    {%{}, %{upload_ids: {:array, :integer}}}
    |> cast(%{upload_ids: upload_ids}, [:upload_ids])
    |> validate_required([:upload_ids])
    |> validate_length(:upload_ids, max: @max_attachments)
    |> validate_change(:upload_ids, fn :upload_ids, ids ->
      cond do
        Enum.any?(ids, &(&1 not in 1..@max_id)) -> [upload_ids: "must be media ids"]
        Enum.uniq(ids) != ids -> [upload_ids: "must not repeat"]
        true -> []
      end
    end)
    |> apply_action(:validate)
    |> case do
      {:ok, %{upload_ids: ids}} -> {:ok, ids}
      {:error, _changeset} = error -> error
    end
  end

  # Unlocked: a stale answer allows only a status read, which grants nothing.
  defp readmit(%User{id: id}) do
    case Repo.get(User, id) do
      nil -> {:error, :unauthenticated}
      user -> Accounts.check_eligibility(user, :contribute)
    end
  end

  defp owned_videos(user_id, ids) do
    assets =
      Repo.all(
        from(a in Asset, where: a.id in ^ids and a.user_id == ^user_id and a.kind == :video)
      )

    if length(assets) == length(ids), do: {:ok, assets}, else: {:error, :not_found}
  end

  defp live_targets(user_id, assets) do
    assets
    |> Enum.map(& &1.target)
    |> Enum.uniq()
    |> Enum.find_value(:ok, fn target ->
      with :ok <- live_target(user_id, target), do: nil
    end)
  end

  defp pending?(%Asset{
         state: state,
         stream_uid: uid,
         cleanup_at: nil,
         tip_id: nil,
         review_id: nil
       })
       when state in [:uploading, :processing] and is_binary(uid),
       do: true

  defp pending?(_asset), do: false

  # Provider reads run in tasks; every write runs here, after the reads.
  defp refresh([], _opts), do: %{}

  defp refresh(assets, opts) do
    client = CloudflareStream.client!(opts)

    assets
    |> Task.async_stream(&CloudflareStream.status(client, &1.stream_uid),
      max_concurrency: @status_concurrency,
      timeout: @status_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.zip(assets)
    |> Map.new(fn {result, asset} -> {asset.id, apply_read(asset, result)} end)
  end

  defp apply_read(asset, {:ok, {:ok, status}}) do
    case observe(status) do
      nil ->
        :ok

      observation ->
        transition_video(asset.id, asset.stream_uid, observation)
        :ok
    end
  end

  defp apply_read(_asset, {:ok, {:error, {:http, 429}}}), do: :rate_limited
  defp apply_read(_asset, _uncertain), do: :uncertain

  # Ready means playable within the duration limit. `pendingupload` is no completion.
  defp observe(%{state: :pendingupload}), do: nil
  defp observe(%{state: :error}), do: :failed

  defp observe(%{ready_to_stream: true, duration_s: duration}) when duration > @max_video_seconds,
    do: :failed

  defp observe(%{ready_to_stream: true, duration_s: duration}) when duration > 0,
    do: {:ready, duration / 1}

  defp observe(_processing), do: :processing

  defp statuses(ids, refreshes) do
    assets = Map.new(Repo.all(from(a in Asset, where: a.id in ^ids)), &{&1.id, &1})

    for id <- ids do
      {state, expires_at} = committed(Map.get(assets, id))
      %{media_id: id, state: state, expires_at: expires_at, refresh: Map.get(refreshes, id, :ok)}
    end
  end

  # The expiry worker may delete a never-released row between the reads.
  defp committed(nil), do: {:removed, nil}
  defp committed(%Asset{cleanup_at: nil} = asset), do: {asset.state, asset.expires_at}
  defp committed(%Asset{} = asset), do: {:removed, asset.expires_at}

  @doc """
  Applies a trusted Stream result to the unattached video `id` with uid `uid`,
  never in cleanup. `:processing` moves only an `uploading` row; ready and
  failed results move an `uploading` or `processing` row. Every applied result
  sets the recovery deadline, `created_at` plus 49 hours, and clears the expiry
  cooldown. There is no wall-clock check. Returns `:unchanged` when the row no
  longer matches, so a late or out-of-order result never regresses a row,
  revives cleanup or restores an expiry that attachment cleared.
  """
  @spec transition_video(Content.media_id(), String.t(), observation()) :: :applied | :unchanged
  def transition_video(id, uid, observation) do
    {state, duration_s, from_states} = transition(observation)

    query =
      from(a in unattached(id, uid),
        where: a.state in ^from_states,
        update: [
          set: [
            state: ^state,
            duration_s: ^duration_s,
            reconcile_after: nil,
            expires_at: fragment("? + ? * interval '1 second'", a.created_at, ^@recovery_seconds)
          ]
        ]
      )

    case Repo.update_all(query, []) do
      {1, _} -> :applied
      {0, _} -> :unchanged
    end
  end

  # The new state and duration, and the states it may replace.
  defp transition(:processing), do: {:processing, nil, [:uploading]}
  defp transition({:ready, duration_s}), do: {:ready, duration_s, [:uploading, :processing]}
  defp transition(:failed), do: {:failed, nil, [:uploading, :processing]}

  defp unattached(id, uid) do
    from(a in Asset,
      where:
        a.id == ^id and a.stream_uid == ^uid and is_nil(a.cleanup_at) and is_nil(a.tip_id) and
          is_nil(a.review_id)
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
