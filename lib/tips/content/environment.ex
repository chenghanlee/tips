defmodule Tips.Content.Environment do
  @moduledoc "A curated environment choice with display order and availability."
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "environments" do
    field :label, :string
    field :sort_order, :integer
    field :active, :boolean, default: true
  end
end
