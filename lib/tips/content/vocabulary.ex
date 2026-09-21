defmodule Tips.Content.Vocabulary do
  @moduledoc "Seeds curated technique tags and explicit development/test setup choices."

  alias Tips.Content.{Environment, Model, Tag}
  alias Tips.Repo

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
