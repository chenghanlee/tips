defmodule Tips.Content.Vocabulary do
  @moduledoc """
  Reads the active curated choices and seeds technique tags and explicit
  development/test setup choices.
  """

  import Ecto.Query

  alias Tips.Content.{Environment, Model, Projection, Tag}
  alias Tips.Repo

  @typedoc "Active curated choices of each filter dimension, in display order."
  @type choices :: %{
          tags: [Projection.label()],
          models: [Projection.label()],
          environments: [Projection.label()]
        }

  @doc "Returns the active tags, models and environments in display order."
  @spec active_choices() :: choices()
  def active_choices do
    %{tags: active(Tag), models: active(Model), environments: active(Environment)}
  end

  defp active(schema) do
    Repo.all(
      from c in schema,
        where: c.active,
        order_by: [c.sort_order, c.id],
        select: %{id: c.id, label: c.label}
    )
  end

  @doc "Seeds the nine production technique tags in display order."
  def seed_tags! do
    seed!(Tag, [
      {"phrase", "Phrase"},
      {"persona", "Persona"},
      {"system-prompt", "System prompt"},
      {"examples", "Examples"},
      {"task-structure", "Task structure"},
      {"output-format", "Output format"},
      {"workflow", "Workflow"},
      {"cost-and-speed", "Cost and speed"},
      {"other", "Other technique"}
    ])
  end

  @doc "Seeds synthetic models/environments for dev/test only; replace with owner-reviewed choices before M2."
  def seed_synthetic! do
    seed!(Model, [{"claude", "Claude"}, {"gpt", "GPT"}, {"gemini", "Gemini"}])
    seed!(Environment, [{"chat", "Chat"}, {"ide", "IDE"}, {"cli", "CLI"}])
  end

  defp seed!(schema, choices) do
    rows =
      choices
      |> Enum.with_index(1)
      |> Enum.map(fn {{id, label}, order} ->
        %{id: id, label: label, sort_order: order, active: true}
      end)

    Repo.insert_all(schema, rows,
      on_conflict: {:replace, [:label, :sort_order, :active]},
      conflict_target: :id
    )
  end
end
