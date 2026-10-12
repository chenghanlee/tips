defmodule TipsWeb.TipIdTest do
  use ExUnit.Case, async: true

  alias TipsWeb.TipId

  @max 9_223_372_036_854_775_807

  test "encodes positive bigint ids as lowercase base36" do
    assert TipId.encode(1) == "1"
    assert TipId.encode(12) == "c"
    assert TipId.encode(35) == "z"
    assert TipId.encode(36) == "10"
    assert TipId.encode(@max) == "1y2p0ij32e8e7"
  end

  test "decodes base36 in either letter case" do
    for {segment, id} <- [
          {"1", 1},
          {"c", 12},
          {"C", 12},
          {"10", 36},
          {"0c", 12},
          {"1y2p0ij32e8e7", @max},
          {"1Y2P0IJ32E8E7", @max}
        ] do
      assert TipId.decode(segment) == {:ok, id}, segment
    end
  end

  test "rejects invalid and trailing characters, zero and overflow" do
    for segment <- [
          "",
          "0",
          "00",
          "-1",
          "+c",
          "c.5",
          "c-",
          " c",
          "c\n",
          "c%20",
          "c/d",
          # Kelvin sign; Unicode lowercasing maps it to "k"
          "K",
          "1y2p0ij32e8e8",
          "zzzzzzzzzzzzz"
        ] do
      assert TipId.decode(segment) == :error, inspect(segment)
    end
  end
end
