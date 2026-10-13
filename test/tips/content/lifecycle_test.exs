defmodule Tips.Content.LifecycleTest do
  use Tips.DataCase, async: true
  use Oban.Testing, repo: Tips.Repo

  # Moderation cases read in a repeatable-read transaction; the sandbox's
  # outer transaction must already use that level.
  @moduletag isolation: "REPEATABLE READ"

  import ExUnit.CaptureLog
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.MediaFixtures
  import Tips.ModerationFixtures
  import Tips.VisibilityFixtures

  alias Tips.Accounts
  alias Tips.Accounts.{Scope, SessionRef}
  alias Tips.AdmissionLimiter
  alias Tips.Content
  alias Tips.Content.{Flag, Notification, Review, Tip}
  alias Tips.Content.Media.Asset
  alias Tips.Workers.CleanupMedia

  @review_attrs %{
    body: "Edited review",
    model_id: nil,
    model_other: nil,
    environment_id: nil,
    prompt: nil,
    output: nil
  }

  for kind <- [:tip, :review] do
    test "#{kind}: full-ban author deletes owned content while edit is refused" do
      kind = unquote(kind)
      {author, row} = content(kind)
      row = put_marker!(row, :hidden)
      reporter = user_fixture()
      open = flag_fixture(reporter, target(row))
      resolved = flag_fixture(user_fixture(), Map.put(target(row), :resolved_at, now()))
      full_ban!(author)

      assert {:error, :forbidden} = edit(kind, scope(author), row)

      for id <- [0, "#{row.id}", nil, 9_223_372_036_854_775_808] do
        assert {:error, :not_found} = Content.delete_content(scope(author), kind, id)
      end

      assert {:error, :not_found} = Content.delete_content(scope(author), :other, row.id)
      assert {:error, :unauthenticated} = Content.delete_content(nil, kind, row.id)
      assert {:error, :not_found} = Content.delete_content(scope(user_fixture()), kind, row.id)
      assert reload(row) == row

      id = row.id
      tip_id = tip_id(row)

      assert {:ok,
              %{
                kind: ^kind,
                id: ^id,
                tip_id: ^tip_id,
                state: :deleted,
                edit_version: 2,
                outcome: :changed
              }} = Content.delete_content(scope(author), kind, row.id)

      deleted = reload(row)
      assert %DateTime{} = deleted.deleted_at

      assert Map.take(deleted, [:dead_at, :created_at, :edited_at, :body]) ==
               Map.take(row, [:dead_at, :created_at, :edited_at, :body])

      assert %Flag{resolved_at: %DateTime{}, resolved_by: nil} = reload(open)
      assert reload(resolved) == resolved

      # A repeat confirms the deletion without repeating its effects.
      assert {:ok, %{state: :deleted, edit_version: 2, outcome: :unchanged}} =
               Content.delete_content(scope(author), kind, row.id)

      assert reload(row) == deleted

      delete_account!(author)
      assert {:error, :unauthenticated} = Content.delete_content(scope(author), kind, row.id)
    end
  end

  test "rejected deletion changes no flags notifications media jobs or content" do
    author = user_fixture()
    tip = tip_fixture(author)
    review = review_fixture(tip)
    flag = flag_fixture(user_fixture(), tip_id: tip.id)
    upvoted = notification_fixture(author, tip_id: tip.id, type: :tip_upvoted)
    reviewed = notification_fixture(author, review_id: review.id, type: :tip_reviewed)
    video = attached_video_fixture(tip, position: 0)
    image = image_fixture(tip, position: 1)
    rows = [tip, review, flag, upvoted, reviewed, video, image]
    snapshot = fn -> Enum.map(rows, &Repo.reload/1) end
    before = snapshot.()

    # The last effect fails after the dependent writes; everything rolls back.
    {1, _} = Repo.update_all(where(Tip, id: ^tip.id), set: [edit_version: 2_147_483_647])

    log =
      capture_log(fn ->
        assert {:error, :outcome_unknown} = Content.delete_content(scope(author), :tip, tip.id)
      end)

    assert log =~ "outcome unknown"
    {1, _} = Repo.update_all(where(Tip, id: ^tip.id), set: [edit_version: 1])
    assert snapshot.() == before
    refute_enqueued(worker: CleanupMedia)

    {limit, _window_ms} = Application.fetch_env!(:tips, AdmissionLimiter)[:write]
    for _ <- 2..limit//1, do: assert(:ok = AdmissionLimiter.check_write(scope(author)))

    assert {:error, {:rate_limited, _seconds}} =
             Content.delete_content(scope(author), :tip, tip.id)

    assert snapshot.() == before
  end

  test "tip deletion masks every viewer and preserves independent reviews and their media" do
    author = user_fixture()
    reviewer = user_fixture()
    tip = tip_fixture(author)
    review = review_fixture(tip, user_id: reviewer.id)
    image = image_fixture(review)
    cleanup_media_fixture(tip)
    tip_upvoted = notification_fixture(author, tip_id: tip.id, type: :tip_upvoted)
    tip_reviewed = notification_fixture(author, review_id: review.id, type: :tip_reviewed)

    read_reviewed =
      notification_fixture(author, review_id: review.id, type: :tip_reviewed, read_at: now())

    review_upvoted = notification_fixture(reviewer, review_id: review.id, type: :review_upvoted)
    other = notification_fixture(author, tip_id: tip_fixture(author).id, type: :tip_upvoted)

    assert {:ok, %{state: :deleted, outcome: :changed}} =
             Content.delete_content(scope(author), :tip, tip.id)

    for viewer <- [nil, session(author).ref, session(moderator!(user_fixture())).ref] do
      assert {:ok, %{tip: %{state: :deleted, title: "Deleted tip", slug: "deleted-tip"} = page}} =
               Content.get_tip_page(viewer, tip.id)

      assert map_size(page) == 4

      assert {:ok, %{review: {:visible, %{media: [%{id: image_id}]}}}} =
               Content.get_review_page(viewer, review.id)

      assert image_id == image.id
    end

    assert %Tip{review_count: 1} = reload(tip)
    assert [nil, nil, nil] == Enum.map([tip_upvoted, tip_reviewed, read_reviewed], &Repo.reload/1)
    assert Enum.map([review_upvoted, other], &Repo.reload/1) == [review_upvoted, other]
  end

  test "review deletion removes it and changes the parent count once" do
    tip = tip_fixture()
    author = user_fixture()
    review = review_fixture(tip, user_id: author.id)
    hidden = review_fixture(tip) |> put_marker!(:hidden)
    upvoted = notification_fixture(author, review_id: review.id, type: :review_upvoted)

    read =
      notification_fixture(tip_author(tip),
        review_id: review.id,
        type: :tip_reviewed,
        read_at: now()
      )

    tip_upvoted = notification_fixture(tip_author(tip), tip_id: tip.id, type: :tip_upvoted)
    assert %Tip{review_count: 1} = reload(tip)

    assert {:ok, %{state: :deleted, outcome: :changed}} =
             Content.delete_content(scope(author), :review, review.id)

    assert %Tip{review_count: 0} = reload(tip)
    assert [nil, nil] == Enum.map([upvoted, read], &Repo.reload/1)
    assert reload(tip_upvoted) == tip_upvoted

    assert {:ok, %{outcome: :unchanged}} =
             Content.delete_content(scope(author), :review, review.id)

    # A hidden review was not counted, so deleting it changes nothing.
    hidden_author = Repo.get!(Accounts.User, hidden.user_id)

    assert {:ok, %{outcome: :changed}} =
             Content.delete_content(scope(hidden_author), :review, hidden.id)

    assert %Tip{review_count: 0} = reload(tip)
  end

  test "deletion retires the item's own media and enqueues its cleanup" do
    author = user_fixture()
    tip = tip_fixture(author)
    video = attached_video_fixture(tip, position: 0)
    image = image_fixture(tip, position: 1)
    in_cleanup = cleanup_media_fixture(tip, position: 2)
    staged = staged_video_fixture(author, target: {:edit_tip, tip.id})
    review = review_fixture(tip, user_id: user_fixture().id)
    review_image = image_fixture(review)

    assert {:ok, %{state: :deleted, outcome: :changed}} =
             Content.delete_content(scope(author), :tip, tip.id)

    for row <- [video, image] do
      assert %{cleanup_at: %DateTime{}, position: nil, tip_id: tip_id} = Repo.reload(row)
      assert tip_id == tip.id
      assert_enqueued(worker: CleanupMedia, args: %{media_id: row.id})
    end

    assert [] == Repo.all(from(a in Asset, where: a.tip_id == ^tip.id and is_nil(a.cleanup_at)))
    assert [_video, _image] = all_enqueued(worker: CleanupMedia)

    # Media already in cleanup, a staged edit video and the reviews' media stay as they were.
    assert Enum.map([in_cleanup, staged, review_image], &Repo.reload/1) ==
             [in_cleanup, staged, review_image]
  end

  for kind <- [:tip, :review] do
    test "#{kind}: hide and restore leave attached media and cleanup jobs unchanged" do
      kind = unquote(kind)
      {_author, row} = content(kind)
      video = attached_video_fixture(row, position: 0)
      image = image_fixture(row, position: 1)
      mod = scope(moderator!(user_fixture()))
      before = Enum.map([video, image], &reload/1)

      assert {:ok, %{outcome: :changed}} = Content.hide_content(mod, kind, row.id, 1, [])
      assert Enum.map([video, image], &reload/1) == before
      refute_enqueued(worker: CleanupMedia)

      assert {:ok, %{outcome: :changed}} = Content.restore_content(mod, kind, row.id, 2, [])
      assert Enum.map([video, image], &reload/1) == before
      refute_enqueued(worker: CleanupMedia)
    end
  end

  test "review deletion retires only the review's media" do
    author = user_fixture()
    reviewer = user_fixture()
    tip = tip_fixture(author)
    review = review_fixture(tip, user_id: reviewer.id)
    tip_image = image_fixture(tip, position: 0)
    review_image = image_fixture(review, position: 0)
    review_video = attached_video_fixture(review, position: 1)
    tip_image_before = reload(tip_image)

    assert {:ok, %{state: :deleted, outcome: :changed}} =
             Content.delete_content(scope(reviewer), :review, review.id)

    for row <- [review_image, review_video] do
      assert %{cleanup_at: %DateTime{}, position: nil} = reload(row)
      assert_enqueued(worker: CleanupMedia, args: %{media_id: row.id})
    end

    assert reload(tip_image) == tip_image_before
    assert [_, _] = all_enqueued(worker: CleanupMedia)
  end

  for kind <- [:tip, :review] do
    test "#{kind}: hide/restore guards version and reviewed reports without replaying publication" do
      kind = unquote(kind)
      {author, row} = content(kind)
      moderator = moderator!(user_fixture())
      mod = scope(moderator)
      first = flag_fixture(user_fixture(), Map.put(target(row), :detail, "Made up"))
      second = flag_fixture(user_fixture(), target(row))
      resolved = flag_fixture(user_fixture(), Map.put(target(row), :resolved_at, now()))
      {_other_author, other} = content(kind)
      foreign = flag_fixture(user_fixture(), target(other))
      notification = notification_fixture(author, notification_target(row))
      tip = Repo.get!(Tip, tip_id(row))
      id = row.id

      assert {:ok,
              %{
                kind: ^kind,
                id: ^id,
                state: :live,
                edit_version: 1,
                content: %{state: :visible, removed: false},
                reports: [report, _second]
              }} = Content.get_moderation_case(session(moderator).ref, kind, row.id)

      assert report == Map.take(first, [:id, :reason, :detail, :created_at])

      # Malformed input is a changeset; nothing is decided or written.
      for version <- [0, "1", nil] do
        assert {:error, changeset} = Content.hide_content(mod, kind, row.id, version, [])
        assert %{edit_version: ["is invalid"]} = errors_on(changeset)
      end

      for ids <- [nil, [0], ["1"], [first.id, first.id], [9_223_372_036_854_775_808]] do
        assert {:error, changeset} = Content.hide_content(mod, kind, row.id, 1, ids)
        assert %{reviewed_report_ids: [_message]} = errors_on(changeset)
      end

      # Missing, foreign and resolved captured reports conflict without a write.
      for ids <- [[first.id, resolved.id], [foreign.id], [foreign.id + 1_000_000]] do
        assert {:error, {:conflict, %{edit_version: 1, state: :live, reports: reports}}} =
                 Content.hide_content(mod, kind, row.id, 1, ids)

        assert Enum.map(reports, & &1.id) == [first.id, second.id]
      end

      assert reload(row) == row

      for {user, error} <- [
            {author, :forbidden},
            {unconfirmed_user_fixture() |> moderator!(), :unconfirmed},
            {full_ban!(moderator!(user_fixture())), :forbidden}
          ] do
        assert {:error, ^error} = Content.hide_content(scope(user), kind, row.id, 1, [first.id])
      end

      # A report filed after the case was read stays open and is not a conflict.
      later = flag_fixture(user_fixture(), target(row))

      assert {:ok, %{state: :hidden, edit_version: 2, outcome: :changed}} =
               Content.hide_content(mod, kind, row.id, 1, [first.id])

      hidden = reload(row)
      assert %DateTime{} = hidden.dead_at

      assert Map.take(hidden, [:created_at, :edited_at, :body, :up_count]) ==
               Map.take(row, [:created_at, :edited_at, :body, :up_count])

      assert %Flag{resolved_by: moderator_id, resolved_at: %DateTime{}} = reload(first)
      assert moderator_id == moderator.id
      assert [nil, nil] == Enum.map([second, later], &reload(&1).resolved_at)
      assert reload(tip).review_count == tip.review_count - review_delta(kind)

      # The old version conflicts; the current one is unchanged and resolves nothing.
      assert {:error, {:conflict, %{edit_version: 2, state: :hidden}}} =
               Content.hide_content(mod, kind, row.id, 1, [second.id])

      assert {:ok, %{state: :hidden, edit_version: 2, outcome: :unchanged}} =
               Content.hide_content(mod, kind, row.id, 2, [second.id])

      assert reload(second).resolved_at == nil

      # Restore validates the reports it reviewed but leaves them open.
      assert {:error, {:conflict, _case}} =
               Content.restore_content(mod, kind, row.id, 2, [first.id])

      assert {:ok, %{state: :live, edit_version: 3, outcome: :changed}} =
               Content.restore_content(mod, kind, row.id, 2, [second.id, later.id])

      assert [nil, nil] == Enum.map([second, later], &reload(&1).resolved_at)
      assert reload(tip).review_count == tip.review_count
      assert reload(notification) == notification
      assert Repo.aggregate(Notification, :count) == 1
      assert reload(row).dead_at == nil

      # Visibility ABA still conflicts on the version.
      assert {:ok, %{edit_version: 4}} = Content.hide_content(mod, kind, row.id, 3, [])
      assert {:ok, %{edit_version: 5}} = Content.restore_content(mod, kind, row.id, 4, [])

      assert {:error, {:conflict, %{edit_version: 5}}} =
               Content.hide_content(mod, kind, row.id, 3, [])
    end
  end

  test "moderation case read requires a current moderator session but not eligibility" do
    tip = tip_fixture()
    banned = full_ban!(moderator!(user_fixture()))

    assert {:ok, %{kind: :tip, state: :live}} =
             Content.get_moderation_case(session(banned).ref, :tip, "#{tip.id}")

    assert {:error, :forbidden} =
             Content.get_moderation_case(session(user_fixture()).ref, :tip, tip.id)

    moderator = moderator!(user_fixture())
    ref = session(moderator).ref

    assert {:error, :unauthenticated} =
             Content.get_moderation_case(
               %SessionRef{token_id: 0, user_id: moderator.id},
               :tip,
               tip.id
             )

    assert {:error, :unauthenticated} =
             Content.get_moderation_case(scope(moderator), :tip, tip.id)

    for {kind, id} <- [tip: 0, tip: "x", other: tip.id, tip: tip.id + 1_000_000] do
      assert {:error, :not_found} = Content.get_moderation_case(ref, kind, id)
    end
  end

  for kind <- [:tip, :review] do
    test "#{kind}: deletion wins and cannot be restored" do
      kind = unquote(kind)
      {author, row} = content(kind)
      moderator = moderator!(user_fixture())
      flag_fixture(user_fixture(), target(row))

      assert {:ok, %{state: :hidden, edit_version: 2}} =
               Content.hide_content(scope(moderator), kind, row.id, 1, [])

      assert {:ok, %{state: :deleted, edit_version: 3}} =
               Content.delete_content(scope(author), kind, row.id)

      assert {:ok, %{state: :deleted, edit_version: 3, reports: [], content: content} = case} =
               Content.get_moderation_case(session(moderator).ref, kind, row.id)

      assert content.state == :deleted
      refute Map.has_key?(content, :body)

      for action <- [:hide_content, :restore_content] do
        assert {:error, {:conflict, ^case}} =
                 apply(Content, action, [scope(moderator), kind, row.id, 3, []])
      end

      assert %{dead_at: %DateTime{}, deleted_at: %DateTime{}, edit_version: 3} = reload(row)
    end
  end

  defp content(:tip) do
    author = user_fixture()
    {author, tip_fixture(author)}
  end

  defp content(:review) do
    author = user_fixture()
    {author, review_fixture(tip_fixture(), user_id: author.id)}
  end

  defp edit(:tip, scope, tip) do
    attrs =
      tip
      |> Map.take([:title, :body, :tag_id, :model_id, :model_other, :environment_id])
      |> Map.merge(%{prompt: nil, output: nil, title: "Edited"})

    Content.edit_tip(scope, tip.id, 1, attrs, [])
  end

  defp edit(:review, scope, review),
    do: Content.edit_review(scope, review.id, 1, @review_attrs, [])

  defp target(%Tip{id: id}), do: %{tip_id: id}
  defp target(%Review{id: id}), do: %{review_id: id}

  defp notification_target(%Tip{id: id}), do: %{tip_id: id, type: :tip_upvoted}
  defp notification_target(%Review{id: id}), do: %{review_id: id, type: :tip_reviewed}

  defp review_delta(:tip), do: 0
  defp review_delta(:review), do: 1

  defp tip_id(%Tip{id: id}), do: id
  defp tip_id(%Review{tip_id: id}), do: id

  defp tip_author(%Tip{user_id: id}), do: Repo.get!(Accounts.User, id)

  defp reload(%module{id: id}), do: Repo.get!(module, id)

  defp scope(user), do: Scope.for_user(user)

  defp session(user) do
    token = Accounts.generate_user_session_token(user)
    {:ok, _scope, ref, _inserted_at} = Accounts.get_scope_by_session_token(token)
    %{token: token, ref: ref}
  end

  defp now, do: DateTime.utc_now(:second)
end
