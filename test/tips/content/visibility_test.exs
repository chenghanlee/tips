defmodule Tips.Content.VisibilityTest do
  use ExUnit.Case, async: true

  alias Tips.Accounts.{Scope, User}
  alias Tips.Content.{Review, Tip, Visibility}

  @now ~U[2026-10-01 12:00:00Z]

  test "deletion wins for every viewer" do
    author = %Scope{user: %User{id: 1}}
    moderator = %Scope{user: %User{id: 2, role: :moderator}}

    for content <- [%Tip{user_id: 1}, %Review{user_id: 1}],
        scope <- [nil, author, moderator],
        hidden_at <- [nil, @now] do
      assert Visibility.decision(scope, %{content | deleted_at: @now, dead_at: hidden_at}) ==
               :deleted
    end
  end

  test "hidden content is readable only by its author or a moderator" do
    viewers = [
      {nil, :removed},
      {%User{id: 2}, :removed},
      {%User{id: 1}, :visible},
      {%User{id: 2, role: :moderator}, :visible},
      {%User{id: 1, ban: :full, banned_at: @now}, :visible},
      {%User{id: 2, role: :moderator, ban: :full, banned_at: @now}, :visible},
      {%User{id: 1, deleted_at: @now}, :removed},
      {%User{id: 2, role: :moderator, deleted_at: @now}, :removed}
    ]

    for content <- [%Tip{user_id: 1}, %Review{user_id: 1}], {user, expected} <- viewers do
      scope = if user, do: %Scope{user: user}
      assert Visibility.decision(scope, content) == :visible
      assert Visibility.decision(scope, %{content | dead_at: @now}) == expected
    end
  end
end
