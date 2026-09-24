ExUnit.start()

defmodule MixRaceAcceptanceTest do
  use ExUnit.Case, async: true

  test "target matches the saved source" do
    assert MixRaceTarget.answer() == :bb
  end

  test "compile-time caller matches the saved source" do
    assert MixRaceCaller.answer() == :bb
  end
end
