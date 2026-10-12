defmodule TipsWeb.TipPageFeatureTest do
  use Tips.FeatureCase, async: true

  import Tips.AccountsFixtures, only: [user_fixture: 0]
  import Tips.ContentFixtures, only: [tip_fixture: 2, review_fixture: 2]

  @moduletag :browser

  setup do
    tip = tip_fixture(user_fixture(), %{title: "Plan first"})

    for n <- 1..31 do
      review_fixture(tip, %{
        up_count: n,
        body: "Review #{n} body",
        prompt: "Prompt #{n}",
        output: "Result #{n}",
        model_id: if(rem(n, 2) == 0, do: "claude")
      })
    end

    %{path: "/tips/#{TipsWeb.TipId.encode(tip.id)}/plan-first"}
  end

  feature "a thirty-review page keeps focus on changed selects; Back restores the filtered list",
          %{session: session, path: path} do
    session
    |> visit(path <> "?page=2")
    |> assert_has(css(".phx-connected"))
    |> assert_has(css("#review-list > article", count: 1))
    |> choose_focused("sort", "new")
    |> assert_has(css("#review-list > article", count: 30))
    |> assert_focus("sort")
    |> assert_url(~r{\?sort=new$})
    |> choose_focused("model", "claude")
    |> assert_has(css("#review-list > article", count: 15))
    |> assert_focus("model")
    |> assert_url(~r{\?sort=new&model=claude$})
    |> click(css("#review-list > article:first-child h2 a"))
    |> assert_has(css("#tip-context"))
    |> assert_url(~r{/reviews/\d+\?sort=new$})
    |> refute_has(css("#review-filters"))
    |> click(link("Show all reviews"))
    |> assert_has(css("#review-list > article", count: 30))
    |> assert_url(~r{/plan-first\?sort=new$})
    |> back()
    |> assert_has(css("#tip-context"))
    |> back()
    |> assert_has(css("#review-list > article", count: 15))
    |> assert_url(~r{\?sort=new&model=claude$})
  end

  defp back(session), do: execute_script(session, "history.back()")
end
