defmodule Tips.Content.Media do
  @moduledoc """
  One image attempt: validates the new image files of a selection and stores
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
  """

  alias Tips.Content
  alias Tips.Content.Media.{ImageParser, R2}

  @max_attachments 10
  @max_new_bytes 50_000_000

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
