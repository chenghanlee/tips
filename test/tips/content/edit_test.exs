defmodule Tips.Content.EditTest do
  use Tips.DataCase, async: true
  use Oban.Testing, repo: Tips.Repo

  import Ecto.Query
  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.MediaFixtures
  import Tips.ModerationFixtures
  import Tips.VisibilityFixtures

  alias Tips.Accounts.Scope
  alias Tips.AdmissionLimiter
  alias Tips.Content
  alias Tips.Content.Media.Asset
  alias Tips.Content.{Model, Notification, Review, Search, Tip}
  alias Tips.R2Stub
  alias Tips.Workers.CleanupMedia

  @tip_attrs %{
    title: "Pin the dependency first",
    body: "Pin the version before asking for an upgrade plan.",
    tag_id: "workflow",
    model_id: "claude",
    model_other: nil,
    environment_id: "ide",
    prompt: "Plan the upgrade",
    output: nil
  }

  @review_attrs %{
    body: "The pinned plan worked.",
    model_id: nil,
    model_other: "Local Llama",
    environment_id: nil,
    prompt: nil,
    output: "All green"
  }

  @dimensions 1024

  describe "authorized edit form returns a complete snapshot" do
    test "tip: hidden content, ordered retained media and capabilities" do
      author = user_fixture()
      tip = author |> tip_fixture(@tip_attrs) |> put_marker!(:hidden)
      video = attached_video_fixture(tip, position: 0)
      image = image_fixture(tip, position: 1, description: "Diagram")
      cleanup_media_fixture(tip, position: 2)
      tip_id = tip.id

      assert {:ok, form} = Content.get_edit_form(scope(author), :tip, tip.id)

      assert %{
               kind: :tip,
               id: ^tip_id,
               tip_id: ^tip_id,
               edit_version: 1,
               state: :hidden,
               capabilities: %{edit: true}
             } = form

      assert form.base == %{
               attrs: @tip_attrs,
               uploads: [{:retained, video.id, nil}, {:retained, image.id, "Diagram"}]
             }

      assert [
               %{kind: :video, id: video_id},
               %{kind: :image, id: image_id, description: "Diagram"}
             ] =
               form.media

      assert {video_id, image_id} == {video.id, image.id}

      # The reader's id forms are accepted.
      assert {:ok, ^form} = Content.get_edit_form(scope(author), :tip, "#{tip.id}")
    end

    test "review: own setup, no attachments, parent unavailable" do
      parent = tip_fixture() |> put_marker!(:deleted)
      author = user_fixture()
      review = review_fixture(parent, Map.put(@review_attrs, :user_id, author.id))
      review_id = review.id
      parent_id = parent.id

      assert {:ok,
              %{
                kind: :review,
                id: ^review_id,
                tip_id: ^parent_id,
                edit_version: 1,
                state: :live,
                base: %{attrs: @review_attrs, uploads: []},
                media: []
              }} = Content.get_edit_form(scope(author), :review, review.id)
    end

    test "only the current author reads undeleted content; ineligible authors cannot edit" do
      author = user_fixture()
      tip = tip_fixture(author)
      review = review_fixture(tip, %{user_id: author.id})

      for {kind, id} <- [tip: tip.id, review: review.id] do
        assert {:error, :not_found} = Content.get_edit_form(scope(user_fixture()), kind, id)
        assert {:error, :unauthenticated} = Content.get_edit_form(nil, kind, id)

        for bad_id <- [0, -1, 9_223_372_036_854_775_808, "x", nil] do
          assert {:error, :not_found} = Content.get_edit_form(scope(author), kind, bad_id)
        end
      end

      full_ban!(author)

      assert {:ok, %{capabilities: %{edit: false}}} =
               Content.get_edit_form(scope(author), :tip, tip.id)

      unconfirmed = unconfirmed_user_fixture()
      own = tip_fixture(unconfirmed)

      assert {:ok, %{capabilities: %{edit: false}}} =
               Content.get_edit_form(scope(unconfirmed), :tip, own.id)

      put_marker!(review, :deleted_and_hidden)
      assert {:error, :not_found} = Content.get_edit_form(scope(author), :review, review.id)
    end
  end

  for kind <- [:tip, :review] do
    test "#{kind}: real edit increments once and current noop writes nothing" do
      kind = unquote(kind)
      {author, row} = content(kind)
      changed = changed_attrs(kind)

      forged =
        Map.merge(changed, %{
          user_id: user_fixture().id,
          submission_key: Ecto.UUID.generate(),
          edit_version: 9,
          up_count: 50,
          dead_at: DateTime.utc_now(:second)
        })

      assert {:ok, %{outcome: :updated, kind: ^kind, edit_version: 2, state: :live} = receipt} =
               edit(kind, scope(author), row.id, 1, forged, [])

      assert receipt.id == row.id
      assert receipt.tip_id == tip_id(row)

      saved = reload(row)
      assert Map.take(saved, Map.keys(changed)) == changed
      assert %DateTime{} = saved.edited_at

      assert Map.take(saved, [:user_id, :submission_key, :up_count, :dead_at, :created_at]) ==
               Map.take(row, [:user_id, :submission_key, :up_count, :dead_at, :created_at])

      search = search_state(kind, row.id)

      # Blank-equivalent values match the saved intent.
      noop = Map.new(changed, fn {field, value} -> {field, value || "  "} end)

      assert {:ok, %{outcome: :noop, edit_version: 2}} =
               edit(kind, scope(author), row.id, 2, noop, [])

      assert reload(row) == saved
      assert search_state(kind, row.id) == search
    end

    test "#{kind}: stale noop conflicts" do
      kind = unquote(kind)
      {author, row} = content(kind)

      assert {:ok, %{edit_version: 2}} =
               edit(kind, scope(author), row.id, 1, changed_attrs(kind), [])

      saved = reload(row)

      # Equal to the current values, but based on the replaced version.
      assert {:error, :conflict} = edit(kind, scope(author), row.id, 1, changed_attrs(kind), [])
      assert {:error, :conflict} = edit(kind, scope(author), row.id, 1, attrs(kind), [])
      assert {:error, :conflict} = edit(kind, scope(author), row.id, 3, attrs(kind), [])
      assert reload(row) == saved
    end
  end

  test "edit preserves publication effects and hidden state" do
    author = user_fixture()
    tip = tip_fixture(author, @tip_attrs)
    vote_fixture(tip, %{value: 1})
    vote_fixture(tip, %{value: -1})
    upvoted = notification_fixture(author, %{tip_id: tip.id, count: 2})
    put_marker!(tip, :hidden)

    reviewer = user_fixture()
    review = review_fixture(tip, Map.put(@review_attrs, :user_id, reviewer.id))
    vote_fixture(review, %{value: -1})
    reviewed = notification_fixture(author, %{type: :tip_reviewed, review_id: review.id})
    {tip, review} = {reload(tip), reload(review)}

    assert {:ok, %{outcome: :updated, state: :hidden}} =
             Content.edit_tip(scope(author), tip.id, 1, changed_attrs(:tip), [])

    assert {:ok, %{outcome: :updated, state: :live}} =
             Content.edit_review(scope(reviewer), review.id, 1, changed_attrs(:review), [])

    preserved = [
      :created_at,
      :dead_at,
      :submission_key,
      :up_count,
      :down_count,
      :score,
      :deleted_at
    ]

    assert Map.take(reload(tip), [:review_count, :hot_score | preserved]) ==
             Map.take(tip, [:review_count, :hot_score | preserved])

    assert Map.take(reload(review), [:best_score | preserved]) ==
             Map.take(review, [:best_score | preserved])

    assert Repo.all(from n in Notification, order_by: n.id) == [upvoted, reviewed]
  end

  test "review setup stays independent and only newly selected choices must be active" do
    parent = tip_fixture(user_fixture(), @tip_attrs)
    author = user_fixture()
    Repo.insert!(%Model{id: "retired-model", label: "Retired model", sort_order: 99})

    review =
      review_fixture(parent, %{
        user_id: author.id,
        body: "Old body",
        model_id: "retired-model"
      })

    Repo.update_all(from(m in Model, where: m.id == "retired-model"), set: [active: false])
    kept = %{@review_attrs | model_id: "retired-model", model_other: nil, body: "New body"}

    assert {:ok, %{outcome: :updated}} =
             Content.edit_review(scope(author), review.id, 1, kept, [])

    # The parent's model and environment never fill the review's cleared setup.
    assert %Review{model_id: "retired-model", environment_id: nil} = reload(review)

    cleared = %{kept | model_id: nil}

    assert {:ok, %{outcome: :updated, edit_version: 3}} =
             Content.edit_review(scope(author), review.id, 2, cleared, [])

    assert %Review{model_id: nil, model_other: nil, environment_id: nil} = reload(review)

    assert {:error, changeset} =
             Content.edit_review(scope(author), review.id, 3, kept, [])

    assert %{model_id: ["is not available"]} = errors_on(changeset)

    assert {:error, changeset} =
             Content.edit_review(scope(author), review.id, 3, %{kept | model_id: "unknown"}, [])

    assert %{model_id: ["does not exist"]} = errors_on(changeset)
    assert %Review{edit_version: 3, model_id: nil} = reload(review)
  end

  test "retained media survives; reorder and description changes fail" do
    author = user_fixture()
    tip = tip_fixture(author, @tip_attrs)
    video = attached_video_fixture(tip, position: 0)
    image = image_fixture(tip, position: 1, description: "Diagram")
    staged = staged_video_fixture(author)
    other = image_fixture(tip_fixture(), position: 0)
    media = Repo.all(from a in Asset, order_by: a.id)
    retained = [{:retained, video.id, "  "}, {:retained, image.id, "Diagram"}]

    assert {:ok, %{outcome: :updated, edit_version: 2}} =
             Content.edit_tip(scope(author), tip.id, 1, changed_attrs(:tip), retained)

    rejected = [
      {[{:retained, image.id, "Diagram"}, {:retained, video.id, nil}], []},
      {[{:retained, video.id, nil}, {:retained, image.id, "Changed"}], [media_id: image.id]},
      {retained ++ [{:retained, other.id, nil}], [media_id: other.id]},
      {retained ++ [{:staged_video, video.id}], [media_id: video.id]},
      {retained ++ [{:missing_image, "s2"}], [slot: "s2"]},
      {retained ++ [:bogus], []},
      {nil, []}
    ]

    for {uploads, expected} <- rejected do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Content.edit_tip(scope(author), tip.id, 2, @tip_attrs, uploads)

      metadata = for {:uploads, {_message, keys}} <- changeset.errors, do: keys
      assert metadata != [], inspect(uploads)

      for {key, value} <- expected do
        assert Enum.any?(metadata, &(&1[key] == value)), inspect({uploads, metadata})
      end
    end

    assert {:error, {:upload_failed, [staged_id]}} =
             Content.edit_tip(
               scope(author),
               tip.id,
               2,
               @tip_attrs,
               retained ++ [{:staged_video, staged.id}]
             )

    assert staged_id == staged.id
    assert Repo.all(from a in Asset, order_by: a.id) == media
    assert %Tip{edit_version: 2, title: "Edited title"} = reload(tip)

    # A selection change on a stale version is a conflict first.
    assert {:error, :conflict} = Content.edit_tip(scope(author), tip.id, 1, @tip_attrs, [])
  end

  describe "image edits" do
    @describetag :tmp_dir

    test "an image replaces a removed one; a stale edit deletes its stored object",
         %{tmp_dir: dir} do
      R2Stub.record()
      author = user_fixture()
      tip = tip_fixture(author, @tip_attrs)
      replaced = image_fixture(tip, position: 0)
      video = attached_video_fixture(tip, position: 1)
      selection = [{:image_file, "s1", R2Stub.image_file(dir), nil}, {:retained, video.id, nil}]

      assert {:ok, %{outcome: :updated, edit_version: 2}} =
               Content.edit_tip(scope(author), tip.id, 1, @tip_attrs, selection)

      assert [{"PUT", stored}] = R2Stub.requests()
      assert %Asset{cleanup_at: %DateTime{}, position: nil} = Repo.reload!(replaced)
      assert [%{args: %{"media_id" => replaced_id}}] = all_enqueued(worker: CleanupMedia)
      assert replaced_id == replaced.id
      video_id = video.id

      assert [%Asset{kind: :image, key: ^stored, position: 0}, %Asset{id: ^video_id, position: 1}] =
               attached(tip)

      media = Repo.all(from a in Asset, order_by: a.id)
      stale = [{:image_file, "s1", R2Stub.image_file(dir), nil}, {:retained, video.id, nil}]

      assert {:error, :conflict} = Content.edit_tip(scope(author), tip.id, 1, @tip_attrs, stale)
      assert [{"PUT", lost}, {"DELETE", deleted}] = R2Stub.requests()
      assert deleted == lost

      assert Repo.all(from a in Asset, order_by: a.id) == media
      assert [_replaced_job] = all_enqueued(worker: CleanupMedia)
      assert %Tip{edit_version: 2} = reload(tip)
    end

    test "a left-out attachment is removed; a new image goes after the kept ones",
         %{tmp_dir: dir} do
      R2Stub.record()
      author = user_fixture()
      tip = tip_fixture(author, @tip_attrs)
      removed = image_fixture(tip, position: 0)
      video = attached_video_fixture(tip, position: 1)
      video_id = video.id

      assert {:ok, %{outcome: :updated, edit_version: 2}} =
               Content.edit_tip(scope(author), tip.id, 1, @tip_attrs, [
                 {:retained, video.id, nil}
               ])

      assert %Asset{cleanup_at: %DateTime{}, position: nil} = Repo.reload!(removed)
      assert [%{args: %{"media_id" => removed_id}}] = all_enqueued(worker: CleanupMedia)
      assert removed_id == removed.id
      assert [%Asset{id: ^video_id, position: 0}] = attached(tip)

      selection = [
        {:retained, video.id, nil},
        {:image_file, "s1", R2Stub.image_file(dir), "Chart"}
      ]

      assert {:ok, %{outcome: :updated, edit_version: 3}} =
               Content.edit_tip(scope(author), tip.id, 2, @tip_attrs, selection)

      assert [{"PUT", stored}] = R2Stub.requests()

      assert [
               %Asset{id: ^video_id, position: 0},
               %Asset{kind: :image, key: ^stored, position: 1, description: "Chart"}
             ] = attached(tip)
    end

    test "a rejected edit with an image writes nothing and deletes what it stored",
         %{tmp_dir: dir} do
      R2Stub.record()
      author = user_fixture()
      tip = tip_fixture(author, @tip_attrs)
      first = image_fixture(tip, position: 0)
      second = attached_video_fixture(tip, position: 1)
      media = Repo.all(from a in Asset, order_by: a.id)
      new_image = {:image_file, "s1", R2Stub.image_file(dir), nil}

      stored = %{
        slot: "s9",
        key: "media/#{Ecto.UUID.generate()}.png",
        content_type: "image/png",
        is_animated: false,
        description: nil
      }

      # Rejected before storing.
      for {uploads, error} <- [
            {[new_image, {:missing_image, "s2"}], {"must be selected again", [slot: "s2"]}},
            {[new_image, {:new_image, stored}], {"is invalid", []}}
          ] do
        assert {:error, changeset} =
                 Content.edit_tip(scope(author), tip.id, 1, @tip_attrs, uploads)

        assert [uploads: ^error] = changeset.errors
      end

      assert R2Stub.requests() == []

      # Rejected under the lock, after storing.
      reordered = [{:retained, second.id, nil}, {:retained, first.id, nil}, new_image]

      assert {:error, changeset} =
               Content.edit_tip(scope(author), tip.id, 1, @tip_attrs, reordered)

      assert [uploads: {"cannot be reordered yet", []}] = changeset.errors
      assert [{"PUT", lost}, {"DELETE", deleted}] = R2Stub.requests()
      assert deleted == lost
      assert Repo.all(from a in Asset, order_by: a.id) == media
      assert all_enqueued(worker: CleanupMedia) == []
      assert %Tip{edit_version: 1} = reload(tip)
    end
  end

  for kind <- [:tip, :review] do
    test "#{kind}: invalid incomplete or ineligible edits do not write" do
      kind = unquote(kind)
      {author, row} = content(kind)
      valid = changed_attrs(kind)
      [first | _] = Map.keys(valid)

      assert {:error, changeset} =
               edit(kind, scope(author), row.id, 1, Map.delete(valid, :body), [])

      assert %{body: ["is missing"]} = errors_on(changeset)

      assert {:error, changeset} = edit(kind, scope(author), row.id, 1, %{valid | body: nil}, [])
      assert %{body: ["can't be blank"]} = errors_on(changeset)

      for version <- [0, "1", nil, 1.0] do
        assert {:error, changeset} = edit(kind, scope(author), row.id, version, valid, [])
        assert %{edit_version: ["is invalid"]} = errors_on(changeset)
      end

      for id <- [0, "#{row.id}", nil, 9_223_372_036_854_775_808] do
        assert {:error, :not_found} = edit(kind, scope(author), id, 1, valid, [])
      end

      assert {:error, :unauthenticated} = edit(kind, nil, row.id, 1, valid, [])
      assert {:error, :not_found} = edit(kind, scope(user_fixture()), row.id, 1, valid, [])

      # The owner predicate holds even if the stored owner changes.
      new_owner = user_fixture()
      {1, _} = Repo.update_all(where(schema(kind), id: ^row.id), set: [user_id: new_owner.id])
      assert {:error, :not_found} = edit(kind, scope(author), row.id, 1, valid, [])
      {1, _} = Repo.update_all(where(schema(kind), id: ^row.id), set: [user_id: author.id])

      unconfirmed = unconfirmed_user_fixture()
      {1, _} = Repo.update_all(where(schema(kind), id: ^row.id), set: [user_id: unconfirmed.id])
      assert {:error, :unconfirmed} = edit(kind, scope(unconfirmed), row.id, 1, valid, [])
      {1, _} = Repo.update_all(where(schema(kind), id: ^row.id), set: [user_id: author.id])

      full_ban!(author)
      assert {:error, :forbidden} = edit(kind, scope(author), row.id, 1, valid, [])
      delete_account!(author)
      assert {:error, :unauthenticated} = edit(kind, scope(author), row.id, 1, valid, [])

      assert Map.take(reload(row), [first, :edit_version, :edited_at]) ==
               Map.take(row, [first, :edit_version, :edited_at])

      {deleter, deleted} = content(kind)
      put_marker!(deleted, :deleted)
      assert {:error, :not_found} = edit(kind, scope(deleter), deleted.id, 1, valid, [])
    end
  end

  test "write admission denies without mutation" do
    {limit, _window_ms} = Application.fetch_env!(:tips, AdmissionLimiter)[:write]
    author = user_fixture()
    tip = tip_fixture(author)
    scope = scope(author)

    for _ <- 3..limit//1, do: assert(:ok = AdmissionLimiter.check_write(scope))

    # The last admitted attempts fail; their budget is not refunded.
    assert {:error, :not_found} = Content.edit_tip(scope, 0, 1, @tip_attrs, [])

    assert {:error, %Ecto.Changeset{}} =
             Content.edit_tip(scope, tip.id, 1, %{@tip_attrs | title: nil}, [])

    assert {:error, {:rate_limited, seconds}} =
             Content.edit_tip(scope, tip.id, 1, @tip_attrs, [])

    assert seconds > 0
    assert {:error, {:rate_limited, _seconds}} = Content.edit_tip(scope, 0, 1, %{}, [])
    assert reload(tip) == tip
  end

  for kind <- [:tip, :review] do
    test "#{kind}: changed search text invalidates atomically and unchanged text preserves freshness" do
      kind = unquote(kind)
      {author, row} = content(kind)
      index!(kind, row.id)
      embedded = search_state(kind, row.id)
      assert %{vector?: true} = embedded

      # Whitespace inside text is saved, but the search document normalizes it away.
      spaced = %{attrs(kind) | body: String.replace(attrs(kind).body, " ", "  ")}

      assert {:ok, %{outcome: :updated, edit_version: 2}} =
               edit(kind, scope(author), row.id, 1, spaced, [])

      assert search_state(kind, row.id) == embedded

      assert {:ok, %{outcome: :updated, edit_version: 3}} =
               edit(kind, scope(author), row.id, 2, changed_attrs(kind), [])

      assert %{vector?: false, embed_after: nil, text: text} =
               edited = search_state(kind, row.id)

      assert text =~ "Edited body"
      assert DateTime.compare(edited.text_at, embedded.text_at) == :gt
    end

    test "#{kind}: an edit over 30,000 search bytes is refused; one at the limit saves" do
      kind = unquote(kind)
      {author, row} = content(kind)
      index!(kind, row.id)
      indexed = search_state(kind, row.id)

      # 10,000 two-byte characters pass the field limit but fill 20,000 bytes.
      assert {:error, {:too_long, 1}} =
               edit(kind, scope(author), row.id, 1, limit_attrs(kind, 1), [])

      assert reload(row) == row
      assert search_state(kind, row.id) == indexed

      assert {:ok, %{outcome: :updated, edit_version: 2}} =
               edit(kind, scope(author), row.id, 1, limit_attrs(kind, 0), [])

      assert %{text: text, vector?: false} = search_state(kind, row.id)
      assert byte_size(text) == 30_000
    end
  end

  # Documents of exactly 30,000 + `over` bytes: the tip's is "Limit", the
  # body, the prompt and the tag label "Workflow"; the review's is the body
  # and the prompt.
  defp limit_attrs(:tip, over) do
    %{
      @tip_attrs
      | title: "Limit",
        body: String.duplicate("é", 10_000),
        prompt: String.duplicate("x", 9_984 + over),
        model_id: nil,
        environment_id: nil
    }
  end

  defp limit_attrs(:review, over) do
    %{
      @review_attrs
      | body: String.duplicate("é", 10_000),
        prompt: String.duplicate("x", 9_999 + over),
        model_other: nil,
        output: nil
    }
  end

  defp content(:tip) do
    author = user_fixture()
    {author, tip_fixture(author, @tip_attrs)}
  end

  defp content(:review) do
    author = user_fixture()
    {author, review_fixture(tip_fixture(), Map.put(@review_attrs, :user_id, author.id))}
  end

  defp attrs(:tip), do: @tip_attrs
  defp attrs(:review), do: @review_attrs

  defp changed_attrs(:tip),
    do: %{@tip_attrs | title: "Edited title", body: "Edited body", model_id: nil, prompt: nil}

  defp changed_attrs(:review),
    do: %{@review_attrs | body: "Edited body", model_other: nil, environment_id: "cli"}

  defp edit(:tip, scope, id, version, attrs, uploads),
    do: Content.edit_tip(scope, id, version, attrs, uploads)

  defp edit(:review, scope, id, version, attrs, uploads),
    do: Content.edit_review(scope, id, version, attrs, uploads)

  defp schema(:tip), do: Tip
  defp schema(:review), do: Review

  defp tip_id(%Tip{id: id}), do: id
  defp tip_id(%Review{tip_id: id}), do: id

  defp reload(%module{id: id}), do: Repo.get!(module, id)

  defp attached(%Tip{id: id}),
    do:
      Repo.all(
        from a in Asset,
          where: a.tip_id == ^id and is_nil(a.cleanup_at),
          order_by: a.position
      )

  defp scope(user), do: Scope.for_user(user)

  defp index!(kind, id) do
    {:ok, :ok} =
      Repo.transact(fn ->
        {:ok, if(kind == :tip, do: Search.write_tip_text(id), else: Search.write_review_text(id))}
      end)

    vector = "[" <> Enum.join([1 | List.duplicate(0, @dimensions - 1)], ",") <> "]"
    {table, column} = search_table(kind)

    Repo.query!(
      "UPDATE #{table} SET embedding = $2::text::vector(1024) WHERE #{column} = $1",
      [id, vector]
    )
  end

  defp search_state(kind, id) do
    {table, column} = search_table(kind)

    case Repo.query!(
           "SELECT search_text, text_at, embedding IS NOT NULL, embed_after FROM #{table} " <>
             "WHERE #{column} = $1",
           [id]
         ) do
      %{rows: []} ->
        nil

      %{rows: [[text, text_at, vector?, embed_after]]} ->
        %{text: text, text_at: text_at, vector?: vector?, embed_after: embed_after}
    end
  end

  defp search_table(:tip), do: {"tip_search", "tip_id"}
  defp search_table(:review), do: {"review_search", "review_id"}
end
