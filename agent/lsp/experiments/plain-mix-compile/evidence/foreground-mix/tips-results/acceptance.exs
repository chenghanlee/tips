ExUnit.start()

defmodule ForegroundTipsTest do
  use ExUnit.Case, async: true

  test "compiled Tips module contains the latest saved documentation" do
    assert {:docs_v1, _, _, _, %{"en" => "Foreground Mix acceptance bravo."}, _, _} =
             Code.fetch_docs(Tips.Health)
  end
end
