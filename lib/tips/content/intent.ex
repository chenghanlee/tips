defmodule Tips.Content.Intent do
  @moduledoc """
  Normalizes and compares complete editable intent for `Tips.Content`.

  See "Complete intent and comparison" in `Tips.Content`. This is comparison
  only: it validates nothing and authorizes no write.
  """

  @fields %{
    tip: [:title, :body, :tag_id, :model_id, :model_other, :environment_id, :prompt, :output],
    review: [:body, :model_id, :model_other, :environment_id, :prompt, :output]
  }

  @doc "The author-editable fields of `kind`, in a stable order."
  @spec fields(Tips.Content.kind()) :: [atom()]
  def fields(kind), do: Map.fetch!(@fields, kind)

  @doc """
  Compares two intents of one kind. Either side that is not a complete, known
  intent makes the result `:unknown`, whatever else differs.
  """
  @spec compare(Tips.Content.kind(), term(), term()) :: Tips.Content.comparison()
  def compare(kind, left, right) when is_map_key(@fields, kind) do
    with {:ok, left} <- normalize(kind, left),
         {:ok, right} <- normalize(kind, right) do
      if left == right, do: :equivalent, else: :different
    end
  end

  # The kind's editable fields and the whole ordered selection, nothing else.
  defp normalize(kind, %{attrs: attrs, uploads: uploads}) when is_map(attrs) do
    with {:ok, fields} <- fields(@fields[kind], attrs),
         {:ok, media} <- media(uploads) do
      {:ok, {fields, media}}
    end
  end

  defp normalize(_kind, _intent), do: :unknown

  defp fields(names, attrs) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, fields} ->
      case attrs do
        %{^name => value} when is_binary(value) or is_nil(value) ->
          {:cont, {:ok, [text(value) | fields]}}

        _missing_or_malformed ->
          {:halt, :unknown}
      end
    end)
  end

  # Media identity is the media id alone. A file or slot the page holds proves
  # no saved bytes, so it has no identity.
  defp media([]), do: {:ok, []}

  defp media([{:retained, id, description} | rest])
       when is_integer(id) and id > 0 and (is_binary(description) or is_nil(description)),
       do: media(rest, {id, text(description)})

  defp media([{:staged_video, id} | rest]) when is_integer(id) and id > 0,
    do: media(rest, {id, nil})

  defp media(_unknown), do: :unknown

  defp media(rest, item) do
    with {:ok, items} <- media(rest), do: {:ok, [item | items]}
  end

  # The changesets' rule: a blank or whitespace-only value is `nil`; any other
  # value is kept byte-for-byte.
  defp text(nil), do: nil
  defp text(value), do: if(String.trim(value) == "", do: nil, else: value)
end
