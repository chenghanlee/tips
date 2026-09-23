defmodule Tips.Content.VisibilityTest do
  use Tips.DataCase, async: true

  alias Tips.Content.Visibility

  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.VisibilityFixtures

  # Expected decision for hidden (moderator-hidden, not deleted) content by viewer.
  @hidden %{
    anonymous: :removed,
    reader: :removed,
    author: :visible,
    moderator: :visible,
    banned_author: :visible,
    banned_moderator: :visible,
    deleted_author: :removed,
    deleted_moderator: :removed
  }

  setup do
    author = user_fixture()
    tip = tip_fixture(author)
    review = review_fixture(tip_fixture(), %{user_id: author.id})

    %{viewers: viewers(author), contents: [tip: tip, review: review]}
  end

  test "deletion wins for every viewer", %{viewers: viewers, contents: contents} do
    for {kind, content} <- contents,
        marker <- [:deleted, :deleted_and_hidden],
        content = put_marker!(content, marker),
        {viewer, scope} <- viewers do
      assert {kind, marker, viewer, :deleted} ==
               {kind, marker, viewer, Visibility.decision(scope, content)}
    end
  end

  test "hidden content is readable only by its author or a moderator", %{
    viewers: viewers,
    contents: contents
  } do
    for {kind, content} <- contents,
        live = put_marker!(content, :live),
        hidden = put_marker!(content, :hidden),
        {viewer, scope} <- viewers do
      assert {kind, viewer, :visible} == {kind, viewer, Visibility.decision(scope, live)}

      assert {kind, viewer, Map.fetch!(@hidden, viewer)} ==
               {kind, viewer, Visibility.decision(scope, hidden)}
    end
  end

  test "full bans preserve reading while deleted accounts lose privileged access", %{
    viewers: viewers,
    contents: contents
  } do
    for {_kind, content} <- contents do
      hidden = put_marker!(content, :hidden)
      live = put_marker!(content, :live)

      assert Visibility.decision(viewers[:banned_author], hidden) == :visible
      assert Visibility.decision(viewers[:banned_moderator], hidden) == :visible
      assert Visibility.decision(viewers[:deleted_author], hidden) == :removed
      assert Visibility.decision(viewers[:deleted_moderator], hidden) == :removed

      for viewer <- [:banned_author, :banned_moderator, :deleted_author, :deleted_moderator] do
        assert Visibility.decision(viewers[viewer], live) == :visible
      end
    end
  end
end
