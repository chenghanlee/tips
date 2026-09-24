ExUnit.start()

defmodule ForegroundResourceTest do
  use ExUnit.Case, async: true

  test "resource was recompiled despite identical file metadata" do
    assert "bb" = ForegroundResource.answer()
  end
end
