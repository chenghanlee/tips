defmodule Tips.MediaFixtures do
  @moduledoc "Database fixtures for media lifecycle and constraint integration tests."

  alias Tips.Accounts.User
  alias Tips.Content.Media.Asset
  alias Tips.Content.Review
  alias Tips.Content.Tip
  alias Tips.Repo

  def image_fixture(parent, attrs \\ %{}) do
    created_at = DateTime.utc_now(:second)

    parent
    |> parent_fields()
    |> Map.merge(%{
      kind: :image,
      key: "media/#{Ecto.UUID.generate()}.png",
      is_animated: false,
      position: 0,
      created_at: created_at
    })
    |> Map.merge(Map.new(attrs))
    |> insert_asset!()
  end

  def staged_video_fixture(%User{} = user, attrs \\ %{}) do
    created_at = DateTime.utc_now(:second)

    %{
      user_id: user.id,
      kind: :video,
      state: :uploading,
      target: {:new_tip, Ecto.UUID.generate()},
      expires_at: DateTime.add(created_at, 3600),
      created_at: created_at
    }
    |> Map.merge(Map.new(attrs))
    |> insert_asset!()
  end

  def attached_video_fixture(parent, attrs \\ %{}) do
    created_at = DateTime.utc_now(:second)

    parent
    |> parent_fields()
    |> Map.merge(%{
      kind: :video,
      state: :ready,
      stream_uid: "stream-#{Ecto.UUID.generate()}",
      target: edit_target(parent),
      duration_s: 12.5,
      completed_at: created_at,
      position: 0,
      created_at: created_at
    })
    |> Map.merge(Map.new(attrs))
    |> insert_asset!()
  end

  def cleanup_media_fixture(parent, attrs \\ %{}) do
    attrs = Map.new(attrs)
    cleanup_at = Map.get(attrs, :cleanup_at, DateTime.utc_now(:second))

    parent
    |> attached_video_fixture(Map.delete(attrs, :cleanup_at))
    |> Ecto.Changeset.change(cleanup_at: cleanup_at, position: nil)
    |> Repo.update!()
  end

  defp parent_fields(%Tip{id: id, user_id: user_id}), do: %{tip_id: id, user_id: user_id}

  defp parent_fields(%Review{id: id, user_id: user_id}),
    do: %{review_id: id, user_id: user_id}

  defp edit_target(%Tip{id: id}), do: {:edit_tip, id}
  defp edit_target(%Review{id: id}), do: {:edit_review, id}

  defp insert_asset!(attrs), do: Asset |> struct!(attrs) |> Repo.insert!()
end
