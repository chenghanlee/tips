defmodule Tips.Content.Tag do
  @moduledoc "A curated tag choice with display order and availability."
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "tags" do
    field :label, :string
    field :sort_order, :integer
    field :active, :boolean, default: true
  end
end
