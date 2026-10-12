defmodule TipsWeb.TipId do
  @moduledoc """
  The tip id in public tip URLs, `/tips/{id in base36}/{slug}`, as
  `docs/design/data-model.md` specifies. Review and editor URLs keep decimal ids.
  """

  # Positive bigint ids; anything else cannot name a row.
  @max 9_223_372_036_854_775_807

  @doc "The lowercase base36 form of a tip id."
  @spec encode(pos_integer()) :: String.t()
  def encode(id) when is_integer(id) and id in 1..@max,
    do: id |> Integer.to_string(36) |> String.downcase()

  @doc """
  Reads a tip URL id. Letters may be in either case; any other character,
  zero or a value above the bigint range is `:error`.
  """
  @spec decode(String.t()) :: {:ok, pos_integer()} | :error
  def decode(segment) when is_binary(segment) do
    segment = String.downcase(segment, :ascii)

    with true <- segment =~ ~r/\A[0-9a-z]+\z/,
         id when id in 1..@max <- String.to_integer(segment, 36) do
      {:ok, id}
    else
      _invalid -> :error
    end
  end
end
