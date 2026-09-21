defmodule Tips.ModerationFixtures do
  @moduledoc "Database fixtures for reports and folded notifications."

  alias Tips.Content.{Flag, Notification}
  alias Tips.Repo

  import Tips.AccountsFixtures
  import Tips.ContentFixtures

  def flag_fixture(reporter \\ user_fixture(), attrs \\ %{}) do
    attrs = Map.new(attrs)

    Flag
    |> struct!(
      attrs
      |> Map.put_new(:user_id, reporter.id)
      |> Map.put_new(:reason, :fabricated)
      |> Map.put_new(:created_at, DateTime.utc_now(:second))
      |> put_default_target()
    )
    |> Repo.insert!()
  end

  def notification_fixture(recipient \\ user_fixture(), attrs \\ %{}) do
    attrs = Map.new(attrs)

    Notification
    |> struct!(
      attrs
      |> Map.put_new(:user_id, recipient.id)
      |> Map.put_new(:type, :tip_upvoted)
      |> Map.put_new(:count, 1)
      |> Map.put_new(:updated_at, DateTime.utc_now(:second))
      |> put_default_target()
    )
    |> Repo.insert!()
  end

  defp put_default_target(attrs) do
    if Map.has_key?(attrs, :tip_id) or Map.has_key?(attrs, :review_id) do
      attrs
    else
      Map.put(attrs, :tip_id, tip_fixture().id)
    end
  end
end
