ExUnit.start()

defmodule SequentialAcceptanceTest do
  use ExUnit.Case, async: true

  test "target matches saved B" do
    assert :bb = SequentialTarget.answer()
  end

  test "compile-time caller matches saved B" do
    assert :bb = SequentialCaller.answer()
  end
end
