defmodule Tips.Content.MediaClaimTest do
  # Staged-video claims through the public publication and edit operations.
  # Races with discard/expiry are in `MediaClaimConcurrencyTest`.
  use Tips.DataCase, async: true

  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.MediaFixtures

  alias Tips.Accounts.Scope
  alias Tips.Content
  alias Tips.Content.Media.Asset
  alias Tips.Content.{Review, Tip}

  @tip_attrs %{
    title: "Record the failing run",
    body: "Attach the run that shows the failure before the fix.",
    tag_id: "workflow",
    model_id: nil,
    model_other: nil,
    environment_id: nil,
    prompt: nil,
    output: nil
  }

  @review_attrs %{
    body: "The recording made the regression obvious.",
    model_id: nil,
    model_other: nil,
    environment_id: nil,
    prompt: nil,
    output: nil
  }

  describe "publication claims ready staged videos" do
    test "publish_tip attaches the selection in its order and clears expiry and cooldown" do
      author = user_fixture()
      key = Ecto.UUID.generate()
      first = ready_video(author, {:new_tip, key}, reconcile_after: DateTime.utc_now(:second))
      second = ready_video(author, {:new_tip, key})
      selection = [{:staged_video, second.id}, {:staged_video, first.id}]

      assert {:ok, %{outcome: :created, id: id}} =
               Content.publish_tip(scope(author), key, @tip_attrs, selection)

      assert [
               %Asset{id: second_id, tip_id: ^id, position: 0} = claimed_second,
               %Asset{id: first_id, tip_id: ^id, position: 1} = claimed_first
             ] = attached(:tip_id, id)

      assert {second_id, first_id} == {second.id, first.id}

      for claimed <- [claimed_first, claimed_second] do
        assert %Asset{
                 expires_at: nil,
                 reconcile_after: nil,
                 review_id: nil,
                 state: :ready,
                 target: {:new_tip, ^key}
               } = claimed
      end

      # The saved selection is what the editor and same-key retries see.
      assert {:ok,
              %{base: %{uploads: [{:retained, ^second_id, nil}, {:retained, ^first_id, nil}]}}} =
               Content.get_edit_form(scope(author), :tip, id)

      assert {:ok, %{outcome: :existing_equivalent, id: ^id}} =
               Content.publish_tip(scope(author), key, @tip_attrs, selection)
    end

    test "publish_review attaches videos staged for its parent and key" do
      author = user_fixture()
      parent = tip_fixture()
      key = Ecto.UUID.generate()
      video = ready_video(author, {:new_review, parent.id, key})

      assert {:ok, %{outcome: :created, kind: :review, id: id}} =
               Content.publish_review(scope(author), parent.id, key, @review_attrs, [
                 {:staged_video, video.id}
               ])

      assert [%Asset{id: video_id, review_id: ^id, tip_id: nil, position: 0, expires_at: nil}] =
               attached(:review_id, id)

      assert video_id == video.id
    end

    test "every ineligible video rejects the whole publication and keeps the selection reusable" do
      author = user_fixture()
      other = user_fixture()
      key = Ecto.UUID.generate()
      target = {:new_tip, key}
      good = ready_video(author, target)
      other_tip = tip_fixture(author)

      failed = [
        attached_elsewhere: attached_video_fixture(other_tip, position: 0),
        image: image_fixture(other_tip, position: 1),
        other_author: ready_video(other, target),
        review_target: ready_video(author, {:new_review, other_tip.id, key}),
        other_key: ready_video(author, {:new_tip, Ecto.UUID.generate()}),
        edit_target: ready_video(author, {:edit_tip, other_tip.id}),
        expired: ready_video(author, target, created_at: hours_ago(49, 1)),
        cleaned_up: ready_video(author, target, cleanup_at: DateTime.utc_now(:second)),
        failed:
          staged_video_fixture(author, %{target: target, state: :failed, stream_uid: uid()}),
        unreleased_expired:
          staged_video_fixture(author, %{target: target, created_at: hours_ago(1, 1)}),
        missing: %{id: 9_223_372_036_854_775_000}
      ]

      pending = [
        uploading: staged_video_fixture(author, %{target: target, stream_uid: uid()}),
        processing:
          staged_video_fixture(author, %{target: target, state: :processing, stream_uid: uid()})
      ]

      media = media_rows()

      for {expected, cases} <- [upload_failed: failed, upload_pending: pending],
          {name, video} <- cases do
        selection = [{:staged_video, good.id}, {:staged_video, video.id}]

        assert {:error, {^expected, [id]}} =
                 Content.publish_tip(scope(author), key, @tip_attrs, selection),
               "#{name}"

        assert id == video.id
      end

      # A failed video is reported before a pending one.
      assert {:error, {:upload_failed, [failed_id]}} =
               Content.publish_tip(scope(author), key, @tip_attrs, [
                 {:staged_video, pending[:uploading].id},
                 {:staged_video, failed[:expired].id}
               ])

      assert failed_id == failed[:expired].id
      assert Repo.all_by(Tip, submission_key: key) == []
      assert media_rows() == media

      assert {:ok, %{outcome: :created, id: id}} =
               Content.publish_tip(scope(author), key, @tip_attrs, [{:staged_video, good.id}])

      assert [%Asset{position: 0}] = attached(:tip_id, id)
    end

    test "a review rejects videos staged for another parent, kind or author" do
      author = user_fixture()
      parent = tip_fixture()
      key = Ecto.UUID.generate()

      for target <- [
            {:new_review, tip_fixture().id, key},
            {:new_tip, key},
            {:edit_review, review_fixture(tip_fixture(), user_id: author.id).id}
          ] do
        video = ready_video(author, target)

        assert {:error, {:upload_failed, [id]}} =
                 Content.publish_review(scope(author), parent.id, key, @review_attrs, [
                   {:staged_video, video.id}
                 ])

        assert id == video.id
      end

      assert Repo.all_by(Review, submission_key: key) == []
    end

    test "a rollback after the claim leaves the staged video reusable" do
      author = user_fixture()
      key = Ecto.UUID.generate()
      video = ready_video(author, {:new_tip, key})

      # 10,000 two-byte characters pass the field limit; the search document is one byte over.
      over = %{@tip_attrs | title: "Limit", body: String.duplicate("é", 10_000)}
      over = %{over | prompt: String.duplicate("x", 9_985)}

      assert {:error, {:too_long, 1}} =
               Content.publish_tip(scope(author), key, over, [{:staged_video, video.id}])

      assert Repo.reload!(video) == video

      assert {:ok, %{outcome: :created, id: id}} =
               Content.publish_tip(scope(author), key, @tip_attrs, [{:staged_video, video.id}])

      assert [%Asset{tip_id: ^id}] = attached(:tip_id, id)
    end

    test "a duplicate or an eleventh slot is a changeset error before any write" do
      author = user_fixture()
      key = Ecto.UUID.generate()
      videos = for _ <- 1..11, do: ready_video(author, {:new_tip, key})
      [first | _] = videos
      media = media_rows()

      assert {:error, changeset} =
               Content.publish_tip(scope(author), key, @tip_attrs, [
                 {:staged_video, first.id},
                 {:staged_video, first.id}
               ])

      assert [{"is selected more than once", [media_id: id]}] =
               for({:uploads, error} <- changeset.errors, do: error)

      assert id == first.id

      assert {:error, changeset} =
               Content.publish_tip(
                 scope(author),
                 key,
                 @tip_attrs,
                 Enum.map(videos, &{:staged_video, &1.id})
               )

      assert %{uploads: ["should have at most 10 item(s)"]} = errors_on(changeset)
      assert Repo.all_by(Tip, submission_key: key) == []
      assert media_rows() == media
    end
  end

  describe "edits claim staged videos with the expected-version guard" do
    test "edit_tip interleaves claims with the retained set and advances the version once" do
      author = user_fixture()
      tip = tip_fixture(author, @tip_attrs)
      image = image_fixture(tip, position: 0, description: "Diagram")
      kept = attached_video_fixture(tip, position: 1)
      for_edit = ready_video(author, {:edit_tip, tip.id})
      for_original = ready_video(author, {:new_tip, tip.submission_key})

      selection = [
        {:staged_video, for_original.id},
        {:retained, image.id, "Diagram"},
        {:staged_video, for_edit.id},
        {:retained, kept.id, nil}
      ]

      assert {:ok, %{outcome: :updated, edit_version: 2}} =
               Content.edit_tip(scope(author), tip.id, 1, @tip_attrs, selection)

      expected = [for_original.id, image.id, for_edit.id, kept.id]

      assert Enum.map(attached(:tip_id, tip.id), &{&1.id, &1.position}) ==
               Enum.zip(expected, 0..3)

      assert %Asset{description: "Diagram", key: key} = Repo.reload!(image)
      assert key == image.key

      assert %Asset{target: {:new_tip, original_key}, expires_at: nil} =
               Repo.reload!(for_original)

      assert original_key == tip.submission_key

      assert {:ok, %{edit_version: 2, base: %{uploads: uploads}}} =
               Content.get_edit_form(scope(author), :tip, tip.id)

      assert uploads == [
               {:retained, for_original.id, nil},
               {:retained, image.id, "Diagram"},
               {:retained, for_edit.id, nil},
               {:retained, kept.id, nil}
             ]

      # The saved selection now compares equal: no version change.
      assert {:ok, %{outcome: :noop, edit_version: 2}} =
               Content.edit_tip(scope(author), tip.id, 2, @tip_attrs, selection)
    end

    test "edit_review claims only videos whose stored facts resolve to the edited review" do
      author = user_fixture()
      parent = tip_fixture()
      review = review_fixture(parent, Map.put(@review_attrs, :user_id, author.id))
      key = review.submission_key
      sibling = review_fixture(tip_fixture(), user_id: author.id)

      rejected = [
        ready_video(author, {:new_review, tip_fixture().id, key}),
        ready_video(author, {:new_review, parent.id, Ecto.UUID.generate()}),
        ready_video(author, {:new_tip, key}),
        ready_video(author, {:edit_review, sibling.id}),
        ready_video(user_fixture(), {:new_review, parent.id, key}),
        ready_video(author, {:new_review, parent.id, key}, created_at: hours_ago(49, 1))
      ]

      for video <- rejected do
        assert {:error, {:upload_failed, [id]}} =
                 Content.edit_review(scope(author), review.id, 1, @review_attrs, [
                   {:staged_video, video.id}
                 ])

        assert id == video.id
      end

      equivalent = ready_video(author, {:new_review, parent.id, key})

      assert {:ok, %{outcome: :updated, edit_version: 2}} =
               Content.edit_review(scope(author), review.id, 1, @review_attrs, [
                 {:staged_video, equivalent.id}
               ])

      assert [%Asset{id: id, review_id: review_id, position: 0}] =
               attached(:review_id, review.id)

      assert {id, review_id} == {equivalent.id, review.id}
      assert %Review{edit_version: 2} = Repo.reload!(review)
    end

    test "a stale version, deleted original or pending video rejects and keeps the video" do
      author = user_fixture()
      tip = tip_fixture(author, @tip_attrs)
      video = ready_video(author, {:new_tip, tip.submission_key})
      pending = staged_video_fixture(author, %{target: {:edit_tip, tip.id}, stream_uid: uid()})

      assert {:ok, %{edit_version: 2}} =
               Content.edit_tip(scope(author), tip.id, 1, %{@tip_attrs | title: "Newer"}, [])

      assert {:error, :conflict} =
               Content.edit_tip(scope(author), tip.id, 1, @tip_attrs, [{:staged_video, video.id}])

      assert {:error, {:upload_pending, [pending_id]}} =
               Content.edit_tip(scope(author), tip.id, 2, @tip_attrs, [
                 {:staged_video, video.id},
                 {:staged_video, pending.id}
               ])

      assert pending_id == pending.id
      assert Repo.reload!(video) == video
      assert %Tip{edit_version: 2, title: "Newer"} = Repo.reload!(tip)

      deleted = tip_fixture(author, deleted_at: DateTime.utc_now(:second))
      orphan = ready_video(author, {:new_tip, deleted.submission_key})

      assert {:error, :not_found} =
               Content.edit_tip(scope(author), deleted.id, 1, @tip_attrs, [
                 {:staged_video, orphan.id}
               ])

      assert Repo.reload!(orphan) == orphan

      assert {:ok, %{outcome: :updated, edit_version: 3}} =
               Content.edit_tip(scope(author), tip.id, 2, @tip_attrs, [{:staged_video, video.id}])

      assert [%Asset{tip_id: tip_id}] = attached(:tip_id, tip.id)
      assert tip_id == tip.id
    end

    test "attached rows never move between items" do
      author = user_fixture()
      tip = tip_fixture(author, @tip_attrs)
      other = attached_video_fixture(tip_fixture(author), position: 0)
      own = attached_video_fixture(tip, position: 0)

      assert {:error, {:upload_failed, [id]}} =
               Content.edit_tip(scope(author), tip.id, 1, @tip_attrs, [
                 {:retained, own.id, nil},
                 {:staged_video, other.id}
               ])

      assert id == other.id
      assert Repo.reload!(other) == other
      assert Repo.reload!(own) == own
    end
  end

  defp ready_video(user, target, attrs \\ []) do
    staged_video_fixture(
      user,
      Map.merge(
        %{target: target, state: :ready, stream_uid: uid(), duration_s: 12.5},
        Map.new(attrs)
      )
    )
  end

  defp uid, do: "stream-#{Ecto.UUID.generate()}"

  defp hours_ago(hours, extra_seconds),
    do: DateTime.add(DateTime.utc_now(:second), -(hours * 3600 + extra_seconds))

  defp attached(parent, id),
    do: Repo.all(from(a in Asset, where: field(a, ^parent) == ^id, order_by: a.position))

  defp media_rows, do: Repo.all(from(a in Asset, order_by: a.id))

  defp scope(user), do: Scope.for_user(user)
end
