defmodule Tips.Content.ProjectionTest do
  use Tips.DataCase, async: true

  alias Tips.Accounts.{Scope, User}
  alias Tips.Content.{Projection, Review, Tip}

  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.MediaFixtures
  import Tips.ModerationFixtures
  import Tips.VisibilityFixtures

  @sentinel "SENTINEL"
  @ordinary [:anonymous, :reader, :deleted_author, :deleted_moderator]

  setup do
    author = user_fixture(%{handle: "sentinel#{System.unique_integer([:positive])}"})

    tip =
      tip_fixture(author, %{
        title: "#{@sentinel} title",
        body: "#{@sentinel} body",
        prompt: "#{@sentinel} prompt",
        output: "#{@sentinel} output",
        model_other: "#{@sentinel} model",
        environment_id: "cli"
      })

    tip_media = [
      image_fixture(tip, %{description: "#{@sentinel} image", position: 0}),
      attached_video_fixture(tip, %{position: 1})
    ]

    reviewer = user_fixture()
    review = review_fixture(tip, %{user_id: reviewer.id, body: "Visible review body"})
    review_media = [image_fixture(review, %{description: "Review image"})]

    %{
      author: author,
      tip: tip,
      tip_media: tip_media,
      reviewer: reviewer,
      review: review,
      review_media: review_media
    }
  end

  describe "unavailable tips" do
    test "unavailable tips mask original fields in every projection", ctx do
      viewers = viewers(ctx.author)

      cases =
        [deleted: :deleted, deleted_and_hidden: :deleted, hidden: :removed]
        |> Enum.flat_map(fn {marker, state} ->
          names = if state == :deleted, do: Keyword.keys(viewers), else: @ordinary
          tip = put_marker!(ctx.tip, marker)
          Enum.map(names, &{marker, &1, state, tip})
        end)

      for {marker, viewer, state, tip} <- cases do
        scope = viewers[viewer]
        placeholder = placeholder(state, tip.id)
        tip_hydration = tip_hydration(ctx.author, ctx.tip_media)
        review_hydration = review_hydration(tip, ctx.reviewer, ctx.review_media)

        outputs = [
          metadata: Projection.metadata(scope, tip),
          summary: Projection.summary(scope, tip, tip_hydration),
          tip: Projection.tip(scope, tip, tip_hydration),
          media: Projection.media(scope, tip, ctx.tip_media),
          selected: Projection.selected_review(scope, tip, nil, %{tip: tip_hydration}),
          review: Projection.review(scope, ctx.review, review_hydration)
        ]

        label = {marker, viewer}
        assert {label, placeholder} == {label, outputs[:metadata]}
        assert {label, placeholder} == {label, outputs[:summary]}
        assert {label, placeholder} == {label, outputs[:tip]}
        assert {label, []} == {label, outputs[:media]}
        assert {label, %{tip: placeholder, review: :unavailable}} == {label, outputs[:selected]}
        assert %{state: :visible, tip: ^placeholder, by_tip_author: false} = outputs[:review]

        refute_leak(outputs, [ctx.author.handle | private_media_values(ctx.tip_media)], label)
      end
    end
  end

  describe "reviews under unavailable parents" do
    test "visible reviews retain their content and media under masked parent context", ctx do
      author_review =
        review_fixture(ctx.tip, %{user_id: ctx.author.id, body: "Author's own review"})

      [review_image] = ctx.review_media
      viewers = viewers(ctx.author)

      for marker <- [:hidden, :deleted] do
        tip = put_marker!(ctx.tip, marker)

        for viewer <- [:anonymous, :reader, :moderator] do
          scope = viewers[viewer]
          parent = Projection.metadata(scope, tip)

          expected_parent =
            case {marker, viewer} do
              {:hidden, :moderator} -> %{state: :visible, title: tip.title}
              {:hidden, _ordinary} -> placeholder(:removed, tip.id)
              {:deleted, _any} -> placeholder(:deleted, tip.id)
            end

          assert Map.take(parent, Map.keys(expected_parent)) == expected_parent

          assert %{
                   state: :visible,
                   body: "Visible review body",
                   tip: ^parent,
                   by_tip_author: false,
                   media: [%{kind: :image, id: image_id, description: "Review image"}]
                 } =
                   Projection.review(
                     scope,
                     ctx.review,
                     review_hydration(tip, ctx.reviewer, ctx.review_media)
                   )

          assert image_id == review_image.id

          by_tip_author = parent.state == :visible

          assert %{
                   state: :visible,
                   body: "Author's own review",
                   tip: ^parent,
                   by_tip_author: ^by_tip_author,
                   author: %{handle: handle}
                 } =
                   Projection.review(scope, author_review, review_hydration(tip, ctx.author, []))

          assert handle == ctx.author.handle
        end
      end
    end
  end

  describe "selected review destinations" do
    test "unknown and wrong-parent reviews share the generic unavailable result", ctx do
      other_tip = tip_fixture()

      other_reviews =
        for marker <- markers() do
          other_tip
          |> review_fixture(%{user_id: ctx.reviewer.id, body: "#{@sentinel} other review"})
          |> put_marker!(marker)
        end

      for {viewer, scope} <- viewers(ctx.reviewer) do
        hydration = %{
          tip: tip_hydration(ctx.author, ctx.tip_media),
          review: review_hydration(other_tip, ctx.reviewer, [])
        }

        unknown = Projection.selected_review(scope, ctx.tip, nil, hydration)
        assert %{review: :unavailable} = unknown

        for review <- other_reviews do
          assert {viewer, review.id, unknown} ==
                   {viewer, review.id,
                    Projection.selected_review(scope, ctx.tip, review, hydration)}
        end
      end
    end

    test "same-parent selected reviews expose only the authorized content or safe removal notice",
         ctx do
      viewers = viewers(ctx.reviewer)
      tip_hydration = tip_hydration(ctx.author, ctx.tip_media)

      for marker <- markers(), {viewer, scope} <- viewers do
        review = put_marker!(ctx.review, marker)

        hydration = %{
          tip: tip_hydration,
          review: review_hydration(ctx.tip, ctx.reviewer, ctx.review_media)
        }

        result = Projection.selected_review(scope, ctx.tip, review, hydration)
        label = {marker, viewer}

        case {marker, viewer in @ordinary} do
          {:live, _ordinary?} ->
            assert {label, %{state: :visible, id: review.id, body: "Visible review body"}} ==
                     {label, selected_fields(result, [:state, :id, :body])}

          {:hidden, false} ->
            assert {label, %{state: :visible, id: review.id, removed: true}} ==
                     {label, selected_fields(result, [:state, :id, :removed])}

          {:hidden, true} ->
            assert {label, :removed} == {label, result.review}

          {deleted, _ordinary?} when deleted in [:deleted, :deleted_and_hidden] ->
            assert {label, :deleted} == {label, result.review}
        end

        if result.review in [:removed, :deleted] do
          assert result ==
                   Projection.selected_review(scope, ctx.tip, review, %{tip: tip_hydration})

          refute inspect(result) =~ "Visible review body"
        end
      end
    end
  end

  describe "private data" do
    test "projections never return raw schemas or private nested data", ctx do
      moderator = Scope.for_user(moderator!(user_fixture()))
      tip = ctx.tip |> put_marker!(:hidden) |> Repo.preload([:user, :tag, :model, :environment])
      review = Repo.preload(ctx.review, [:user, :model, :environment, tip: :user])
      author = Repo.get!(User, ctx.author.id)
      reviewer = Repo.get!(User, ctx.reviewer.id)
      tip_hydration = %{tip_hydration(author, ctx.tip_media) | own_review: nil}
      review_hydration = review_hydration(tip, reviewer, ctx.review_media)

      summary = Projection.summary(moderator, tip, tip_hydration)
      detail = Projection.tip(moderator, tip, tip_hydration)
      metadata = Projection.metadata(moderator, tip)
      review_view = Projection.review(moderator, review, review_hydration)

      selected =
        Projection.selected_review(moderator, tip, review, %{
          tip: tip_hydration,
          review: review_hydration
        })

      own_review = Projection.own_review(Scope.for_user(reviewer), review)

      assert keys(metadata) == ~w(id slug state title)a

      assert keys(summary) ==
               ~w(author capabilities created_at environment id model removed review_count score slug state tag title viewer_vote)a

      assert keys(detail) ==
               ~w(author body capabilities created_at down_count edited_at environment has_earlier_reviews id latest_review_at media model output prompt removed review_count score slug state tag title up_count viewer_vote)a

      assert keys(review_view) ==
               ~w(author body by_tip_author capabilities created_at down_count edited_at environment id media model output prompt removed score state tip up_count viewer_vote)a

      assert keys(summary.capabilities) == ~w(delete edit report vote)a
      assert keys(detail.capabilities) == ~w(delete edit report review vote)a
      assert keys(review_view.capabilities) == ~w(delete edit report vote)a
      assert keys(own_review) == ~w(capabilities id removed)a
      assert own_review.capabilities == %{vote: true, edit: true, delete: true, report: false}
      assert [image, video] = detail.media
      assert keys(image) == ~w(animated description id kind object_key position)a
      assert keys(video) == ~w(duration_s id kind position thumbnail_path watch_path)a
      assert Map.take(summary, Map.keys(metadata)) == metadata
      assert %{author: %{handle: handle}, tag: %{id: "other", label: "Other technique"}} = detail
      assert handle == author.handle
      assert %{model: %{id: nil, label: "SENTINEL model"}} = detail
      assert %{environment: %{id: "cli", label: "CLI"}} = detail

      outputs = [summary, detail, metadata, review_view, selected, own_review]

      for output <- outputs do
        assert_plain(output)
        text = inspect(output, limit: :infinity, printable_limit: :infinity)

        for private <- [author.email, reviewer.email, "hashed_password", "stream-", "users"] do
          refute text =~ private
        end
      end
    end

    test "authors receive no moderation report details", ctx do
      detail = "#{@sentinel} report explanation"
      reporter = user_fixture()
      flag_fixture(reporter, %{tip_id: ctx.tip.id, reason: :harmful, detail: detail})
      flag_fixture(reporter, %{review_id: ctx.review.id, reason: :spam, detail: detail})

      tip = put_marker!(ctx.tip, :hidden)
      review = put_marker!(ctx.review, :hidden)
      author = Scope.for_user(ctx.author)
      reviewer = Scope.for_user(ctx.reviewer)
      tip_hydration = tip_hydration(ctx.author, ctx.tip_media)
      review_hydration = review_hydration(tip, ctx.reviewer, ctx.review_media)

      outputs = [
        Projection.summary(author, tip, tip_hydration),
        Projection.tip(author, tip, tip_hydration),
        Projection.review(reviewer, review, review_hydration),
        Projection.selected_review(reviewer, tip, review, %{
          tip: tip_hydration,
          review: review_hydration
        }),
        Projection.own_review(reviewer, review)
      ]

      assert [%{removed: true}, %{removed: true}, %{removed: true}, _selected, %{removed: true}] =
               outputs

      text = inspect(outputs, limit: :infinity, printable_limit: :infinity)

      for private <- [detail, reporter.handle, "harmful", "spam", "reason", "flag", "report:"] do
        refute text =~ private
      end
    end
  end

  describe "media" do
    test "media projection checks current parent visibility and attachment membership", ctx do
      [image, video] = ctx.tip_media
      [review_image] = ctx.review_media
      cleanup = cleanup_media_fixture(ctx.tip)
      staged = staged_video_fixture(ctx.author)
      other_parent = image_fixture(tip_fixture(), %{position: 0})
      unready = %{attached_video_fixture(ctx.tip, %{position: 2}) | state: :processing}
      assets = [video, unready, cleanup, staged, other_parent, review_image, image]
      viewers = viewers(ctx.author)

      expected = [
        %{
          kind: :image,
          id: image.id,
          position: 0,
          description: "#{@sentinel} image",
          animated: false,
          object_key: image.key
        },
        %{
          kind: :video,
          id: video.id,
          position: 1,
          duration_s: 12.5,
          watch_path: "/media/#{video.id}/watch",
          thumbnail_path: "/media/#{video.id}/thumbnail"
        }
      ]

      for {viewer, scope} <- viewers do
        assert {viewer, expected} == {viewer, Projection.media(scope, ctx.tip, assets)}

        assert {viewer, [review_image.id]} ==
                 {viewer, Enum.map(Projection.media(scope, ctx.review, assets), & &1.id)}
      end

      hidden = put_marker!(ctx.tip, :hidden)
      deleted = put_marker!(ctx.tip, :deleted)

      for {viewer, scope} <- viewers do
        expected_hidden = if viewer in @ordinary, do: [], else: expected
        assert {viewer, expected_hidden} == {viewer, Projection.media(scope, hidden, assets)}
        assert {viewer, []} == {viewer, Projection.media(scope, deleted, assets)}
      end

      text = inspect(Projection.media(nil, ctx.tip, assets), limit: :infinity)

      for asset <- [video, unready, cleanup] do
        refute text =~ asset.stream_uid
      end

      refute text =~ "token"
    end
  end

  defp placeholder(:deleted, id),
    do: %{state: :deleted, id: id, title: "Deleted tip", slug: "deleted-tip"}

  defp placeholder(:removed, id),
    do: %{state: :removed, id: id, title: "Removed tip", slug: "removed-tip"}

  defp tip_hydration(%User{} = author, media) do
    %{
      author: author,
      labels: labels(),
      viewer_vote: nil,
      media: media,
      own_review: nil,
      latest_review_at: nil,
      has_earlier_reviews: false
    }
  end

  defp review_hydration(%Tip{} = parent, %User{} = author, media) do
    %{parent: parent, author: author, labels: labels(), viewer_vote: nil, media: media}
  end

  defp selected_fields(%{review: {:visible, %Review{}}}, _fields),
    do: flunk("selected review returned a raw schema")

  defp selected_fields(%{review: {:visible, review}}, fields), do: Map.take(review, fields)
  defp selected_fields(%{review: other}, _fields), do: other

  defp keys(map), do: map |> Map.keys() |> Enum.sort()

  defp private_media_values(assets) do
    Enum.flat_map(assets, fn asset ->
      Enum.reject(
        [asset.key, asset.stream_uid, asset.description, "/media/#{asset.id}/"],
        &is_nil/1
      )
    end)
  end

  defp refute_leak(outputs, private_values, label) do
    text = inspect(outputs, limit: :infinity, printable_limit: :infinity)

    for private <- [@sentinel | private_values] do
      refute text =~ private, "#{inspect(label)} leaked #{inspect(private)}"
    end
  end

  # Only plain maps, lists, tuples, atoms, numbers, strings and DateTime values may
  # leave a projection; any other struct is a raw schema or association.
  defp assert_plain(%DateTime{}), do: :ok
  defp assert_plain(%{__struct__: struct}), do: flunk("projection returned #{inspect(struct)}")
  defp assert_plain(map) when is_map(map), do: Enum.each(map, fn {_k, v} -> assert_plain(v) end)
  defp assert_plain(list) when is_list(list), do: Enum.each(list, &assert_plain/1)
  defp assert_plain(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> assert_plain()
  defp assert_plain(_scalar), do: :ok
end
