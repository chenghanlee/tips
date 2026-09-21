defmodule Tips.Content.Media.Target do
  @moduledoc "The canonical persistence encoding for a server-owned media upload target."

  use Ecto.Type

  @type t ::
          {:new_tip, Ecto.UUID.t()}
          | {:new_review, pos_integer(), Ecto.UUID.t()}
          | {:edit_tip, pos_integer()}
          | {:edit_review, pos_integer()}

  @impl Ecto.Type
  @spec type() :: :string
  def type, do: :string

  @impl Ecto.Type
  @spec cast(term()) :: {:ok, t()} | :error
  def cast({:new_tip, submission_key}) do
    with {:ok, submission_key} <- normalize_uuid(submission_key) do
      {:ok, {:new_tip, submission_key}}
    end
  end

  def cast({:new_review, tip_id, submission_key}) do
    with {:ok, tip_id} <- positive_integer(tip_id),
         {:ok, submission_key} <- normalize_uuid(submission_key) do
      {:ok, {:new_review, tip_id, submission_key}}
    end
  end

  def cast({:edit_tip, tip_id}) do
    with {:ok, tip_id} <- positive_integer(tip_id), do: {:ok, {:edit_tip, tip_id}}
  end

  def cast({:edit_review, review_id}) do
    with {:ok, review_id} <- positive_integer(review_id), do: {:ok, {:edit_review, review_id}}
  end

  def cast(_value), do: :error

  @impl Ecto.Type
  @spec dump(term()) :: {:ok, String.t()} | :error
  def dump(value) do
    with {:ok, target} <- cast(value), do: {:ok, encode(target)}
  end

  @impl Ecto.Type
  @spec load(term()) :: {:ok, t()} | :error
  def load(value) when is_binary(value) do
    case String.split(value, ":") do
      ["new_tip", submission_key] ->
        with {:ok, submission_key} <- canonical_uuid(submission_key) do
          {:ok, {:new_tip, submission_key}}
        end

      ["new_review", tip_id, submission_key] ->
        with {:ok, tip_id} <- canonical_integer(tip_id),
             {:ok, submission_key} <- canonical_uuid(submission_key) do
          {:ok, {:new_review, tip_id, submission_key}}
        end

      ["edit_tip", tip_id] ->
        with {:ok, tip_id} <- canonical_integer(tip_id), do: {:ok, {:edit_tip, tip_id}}

      ["edit_review", review_id] ->
        with {:ok, review_id} <- canonical_integer(review_id),
             do: {:ok, {:edit_review, review_id}}

      _other ->
        :error
    end
  end

  def load(_value), do: :error

  defp encode({:new_tip, submission_key}), do: "new_tip:#{submission_key}"

  defp encode({:new_review, tip_id, submission_key}),
    do: "new_review:#{tip_id}:#{submission_key}"

  defp encode({:edit_tip, tip_id}), do: "edit_tip:#{tip_id}"
  defp encode({:edit_review, review_id}), do: "edit_review:#{review_id}"

  defp normalize_uuid(uuid) when is_binary(uuid) and byte_size(uuid) == 36 do
    case Ecto.UUID.cast(uuid) do
      {:ok, normalized} -> {:ok, String.downcase(normalized)}
      :error -> :error
    end
  end

  defp normalize_uuid(_uuid), do: :error

  defp canonical_uuid(uuid) do
    with {:ok, normalized} <- normalize_uuid(uuid),
         true <- uuid == normalized do
      {:ok, normalized}
    else
      _invalid -> :error
    end
  end

  defp positive_integer(id) when is_integer(id) and id > 0, do: {:ok, id}
  defp positive_integer(_id), do: :error

  defp canonical_integer(encoded) do
    case Integer.parse(encoded) do
      {id, ""} when id > 0 ->
        if Integer.to_string(id) == encoded, do: {:ok, id}, else: :error

      _invalid ->
        :error
    end
  end
end
