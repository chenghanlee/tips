ExUnit.start()

defmodule ForegroundAcceptanceTest do
  use ExUnit.Case, async: true

  test "target and compile-time caller match saved B" do
    assert :bb = ForegroundTarget.answer()
    assert :bb = ForegroundCaller.answer()
  end
end
