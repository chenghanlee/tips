defmodule Tips.Content.Search.Vector do
  @moduledoc """
  The one rule for vectors sent to pgvector, for queries and documents alike.

  pgvector stores float32 values and sums float32 products, so cosine needs a
  direction that survives both. A vector that rounds to zero has none. Any
  other is scaled by its largest magnitude before squaring, so no square
  overflows or underflows, then stored as a unit vector.
  """

  @dimensions 1024
  @float32_max 3.402_823_466_385_288_6e38

  @typedoc "A pgvector text literal of a 1024-dimension unit vector."
  @type t :: String.t()

  @doc """
  Returns the unit-vector literal of `values`: 1024 numbers within float32
  range, not all zero once rounded to float32. Anything else is `:error`.
  """
  @spec literal(term()) :: {:ok, t()} | :error
  def literal(values) when is_list(values) and length(values) == @dimensions do
    with true <- Enum.all?(values, &finite?/1),
         floats = Enum.map(values, &float32/1),
         largest when largest > 0 <- floats |> Enum.map(&abs/1) |> Enum.max() do
      scaled = Enum.map(floats, &(&1 / largest))
      norm = :math.sqrt(Enum.reduce(scaled, 0.0, &(&1 * &1 + &2)))
      {:ok, "[" <> Enum.map_join(scaled, ",", &Float.to_string(float32(&1 / norm))) <> "]"}
    else
      _zero_or_out_of_range -> :error
    end
  end

  def literal(_values), do: :error

  defp finite?(value), do: is_number(value) and abs(value) <= @float32_max

  defp float32(value) do
    <<float::float-32>> = <<value::float-32>>
    float
  end
end
