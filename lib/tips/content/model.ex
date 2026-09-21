defmodule Tips.Content.Model do
  @moduledoc "A curated model choice with display order and availability."
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "models" do
    field :label, :string
    field :sort_order, :integer
    field :active, :boolean, default: true
  end
end
