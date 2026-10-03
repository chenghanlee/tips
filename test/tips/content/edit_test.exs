defmodule Tips.Content.EditTest do
  use Tips.DataCase, async: true

  alias Tips.Accounts.Scope
  alias Tips.AdmissionLimiter
  alias Tips.Content
  alias Tips.Content.{Model, Notification, Review, Tag, Tip, Vote}
  alias Tips.Content.Media.Asset

  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.MediaFixtures
  import Tips.VisibilityFixtures

  @fields %{
    tip: [:title, :body, :tag_id, :model_id, :model_other, :environment_id, :prompt, :output],
    review: [:body, :model_id, :model_other, :environment_id, :prompt, :output]
  }

  @tip_attrs %{
    title: "Name the failing test first",
    body: "State the failing test before asking for a fix.",
    tag_id: "workflow",
    model_id: "claude",
    model_other: nil,
    environment_id: "ide",
    prompt: "Fix the test",
    output: nil
  }

  @review_attrs %{
    body: "Worked on my flaky suite.",
    model_id: nil,
    model_other: "Local Llama",
    environment_id: nil,
    prompt: nil,
    output: "All green"
  }

  describe "edit form" do
    test "edit form returns one complete authorized snapshot" do
      author = user_fixture()
      tip = tip_fixture(author, @tip_attrs)
      image = image_fixture(tip, position: 1, description: "Before")
      video = attached_video_fixture(tip, position: 0)
      review = review_fixture(tip, Map.put(@review_attrs, :user_id, author.id))
      put_marker!(review, :hidden)

      assert {:ok, form} = Content.get_edit_form(scope(author), :tip, tip.id)

      assert form == %{
               kind: :tip,
               id: tip.id,
               tip_id: tip.id,
               edit_version: 1,
               state: :live,
               base: %{
                 attrs: @tip_attrs,
                 uploads: [{:retained, video.id, nil}, {:retained, image.id, "Before"}]
               },
               media: [
                 %{
                   kind: :video,
                   id: video.id,
                   position: 0,
                   duration_s: 12.5,
                   watch_path: "/media/#{video.id}/watch",
                   thumbnail_path: "/media/#{video.id}/thumbnail"
                 },
                 %{
                   kind: :image,
                   id: image.id,
                   position: 1,
                   description: "Before",
                   animated: false,
                   object_key: image.key
                 }
               ],
               capabilities: %{vote: true, edit: true, delete: true, report: true}
             }

      # Hidden content stays editable by its author; the id may be a decimal string.
      assert {:ok, %{kind: :review, id: id, tip_id: tip_id, state: :hidden} = form} =
               Content.get_edit_form(scope(author), :review, Integer.to_string(review.id))

      assert {id, tip_id} == {review.id, tip.id}
      assert form.base == %{attrs: @review_attrs, uploads: []}
      assert form.capabilities == %{vote: false, edit: true, delete: true, report: false}

      # An ineligible author still reads the form, with edit off.
      banned = full_ban!(author)

      assert {:ok, %{capabilities: %{edit: false, delete: true}}} =
               Content.get_edit_form(scope(banned), :tip, tip.id)

      unconfirmed = unconfirmed_user_fixture()
      draft = tip_fixture(unconfirmed)

      assert {:ok, %{capabilities: %{edit: false}}} =
               Content.get_edit_form(scope(unconfirmed), :tip, draft.id)
    end
  end

  describe "guarded edits" do
    for kind <- [:tip, :review] do
      test "current real edit increments once and current noop writes nothing (#{kind})" do
        kind = unquote(kind)
        {author, row} = content(kind)
        changed = %{attrs(kind, row) | body: "  Rewritten body.  ", output: nil}

        assert {:ok, receipt} = edit(scope(author), kind, row.id, 1, changed, [])

        assert receipt == %{
                 outcome: :updated,
                 kind: kind,
                 id: row.id,
                 tip_id: tip_id(row),
                 edit_version: 2,
                 state: :live
               }

        assert %{
                 edit_version: 2,
                 body: "  Rewritten body.  ",
                 output: nil,
                 edited_at: %DateTime{}
               } =
                 current = Repo.reload!(row)

        search = search_state(kind, row.id)

        # A whitespace-only value is the same explicit blank as nil.
        assert {:ok, %{outcome: :noop, edit_version: 2}} =
                 edit(scope(author), kind, row.id, 2, %{changed | output: "  "}, [])

        assert Repo.reload!(row) == current
        assert search_state(kind, row.id) == search
      end

      test "stale noop conflicts (#{kind})" do
        kind = unquote(kind)
        {author, row} = content(kind)
        original = attrs(kind, row)
        changed = %{original | body: "Changed in another tab."}

        assert {:ok, %{edit_version: 2}} = edit(scope(author), kind, row.id, 1, changed, [])
        current = Repo.reload!(row)

        # Equal to the saved values, but based on an older version.
        assert {:error, :conflict} = edit(scope(author), kind, row.id, 1, changed, [])
        assert {:error, :conflict} = edit(scope(author), kind, row.id, 1, original, [])
        assert {:error, :conflict} = edit(scope(author), kind, row.id, 3, changed, [])
        assert Repo.reload!(row) == current

        # Recovery: the latest form's base, then an explicit save at its version.
        assert {:ok, %{edit_version: 2, base: base}} =
                 Content.get_edit_form(scope(author), kind, row.id)

        assert Content.compare_intents(kind, base, %{attrs: changed, uploads: []}) ==
                 :equivalent

        assert {:ok, %{outcome: :noop, edit_version: 2}} =
                 edit(scope(author), kind, row.id, 2, changed, [])
      end
    end

    test "edits preserve publication effects and hidden state" do
      tip_author = user_fixture()
      reviewer = user_fixture()
      voter = user_fixture()

      assert {:ok, %{id: tip_id}} =
               Content.publish_tip(scope(tip_author), key(), @tip_attrs, [])

      assert {:ok, %{id: review_id}} =
               Content.publish_review(scope(reviewer), tip_id, key(), @review_attrs, [])

      tip = Repo.get!(Tip, tip_id)
      review = Repo.get!(Review, review_id)
      vote_fixture(tip, user_id: voter.id, value: -1)
      vote_fixture(review, user_id: voter.id, value: 1)

      read_at = DateTime.add(DateTime.utc_now(:second), -60)
      Repo.update_all(Notification, set: [read_at: read_at])
      put_marker!(tip, :hidden)
      before = snapshot(tip_id, review_id)

      assert {:ok, %{outcome: :updated, state: :hidden}} =
               edit(scope(tip_author), :tip, tip_id, 1, %{@tip_attrs | body: "New tip body"}, [])

      assert {:ok, %{outcome: :updated, state: :live}} =
               edit(scope(reviewer), :review, review_id, 1, %{@review_attrs | body: "New"}, [])

      after_edit = snapshot(tip_id, review_id)
      assert %{edit_version: 2, dead_at: %DateTime{}} = after_edit.tip
      assert %{edit_version: 2, dead_at: nil} = after_edit.review

      assert Map.drop(after_edit.tip, [:body, :edit_version, :edited_at]) ==
               Map.drop(before.tip, [:body, :edit_version, :edited_at])

      assert Map.drop(after_edit.review, [:body, :edit_version, :edited_at]) ==
               Map.drop(before.review, [:body, :edit_version, :edited_at])

      assert after_edit.votes == before.votes
      assert [%Notification{count: 1, read_at: ^read_at}] = after_edit.notifications
      assert after_edit.notifications == before.notifications
    end

    test "review setup stays independent of parent" do
      parent = tip_fixture(user_fixture(), @tip_attrs)
      reviewer = user_fixture()

      assert {:ok, %{id: review_id}} =
               Content.publish_review(scope(reviewer), parent.id, key(), @review_attrs, [])

      review = Repo.get!(Review, review_id)
      own = %{@review_attrs | model_id: "claude", model_other: nil, environment_id: "ide"}

      assert {:ok, %{edit_version: 2}} = edit(scope(reviewer), :review, review.id, 1, own, [])
      assert %Review{model_id: "claude", environment_id: "ide"} = Repo.get!(Review, review.id)

      cleared = %{own | model_id: nil, environment_id: nil}
      assert {:ok, %{edit_version: 3}} = edit(scope(reviewer), :review, review.id, 2, cleared, [])

      assert %Review{model_id: nil, model_other: nil, environment_id: nil} =
               Repo.get!(Review, review.id)

      assert Repo.reload!(parent) == parent
    end
  end

  describe "search freshness" do
    for kind <- [:tip, :review] do
      test "changed search text invalidates embedding atomically (#{kind})" do
        kind = unquote(kind)
        {author, row} = published(kind)
        embedded = embed!(kind, row.id)
        changed = %{attrs(kind, row) | output: "A new searchable result"}

        assert {:ok, %{edit_version: 2}} = edit(scope(author), kind, row.id, 1, changed, [])

        assert %{text: text, vector?: false, embed_after: nil, token: token} =
                 search_state(kind, row.id)

        assert text =~ "A new searchable result"
        assert DateTime.compare(token, embedded.token) == :gt
      end

      test "unchanged search text retains embedding freshness (#{kind})" do
        kind = unquote(kind)
        {author, row} = published(kind)
        embedded = embed!(kind, row.id)

        # Search text collapses whitespace, so this content change leaves it equal.
        changed = %{attrs(kind, row) | body: String.replace(row.body, " ", "  ")}

        assert {:ok, %{edit_version: 2}} = edit(scope(author), kind, row.id, 1, changed, [])
        assert %{body: body} = Repo.reload!(row)
        assert body =~ "  "
        assert search_state(kind, row.id) == embedded
      end
    end
  end

  describe "input validation" do
    test "invalid and incomplete edits fail without writes" do
      author = user_fixture()
      retired = curated!(Model, "Retired model")
      tip = tip_fixture(author, %{@tip_attrs | model_id: retired.id})
      Repo.update_all(from(m in Model, where: m.id == ^retired.id), set: [active: false])
      tip = Repo.reload!(tip)
      current = attrs(:tip, tip)
      inactive = curated!(Tag, "Inactive tag", active: false)
      s = scope(author)

      assert {:error, changeset} = edit(s, :tip, tip.id, 1, Map.delete(current, :output), [])
      assert {"is missing", [validation: :intent]} = changeset.errors[:output]

      assert {:error, changeset} = edit(s, :tip, tip.id, 1, %{current | title: " "}, [])
      assert {"can't be blank", _} = changeset.errors[:title]

      assert {:error, changeset} = edit(s, :tip, tip.id, 1, :not_a_map, [])
      assert Enum.all?(@fields.tip, &match?({"is missing", _}, changeset.errors[&1]))

      assert {:error, changeset} = edit(s, :tip, tip.id, 1, current, nil)
      assert {"is invalid", _} = changeset.errors[:uploads]

      for version <- [0, -1, "1", nil, 1.0] do
        assert {:error, changeset} = edit(s, :tip, tip.id, version, current, [])
        assert {"is invalid", _} = changeset.errors[:edit_version]
      end

      assert {:error, changeset} = edit(s, :tip, tip.id, 1, %{current | tag_id: inactive.id}, [])
      assert [tag_id: {"is not available", []}] = changeset.errors

      assert {:error, changeset} = edit(s, :tip, tip.id, 1, %{current | tag_id: "missing"}, [])
      assert {"does not exist", _} = changeset.errors[:tag_id]

      assert {:error, changeset} =
               edit(s, :tip, tip.id, 1, %{current | model_other: "Also set"}, [])

      assert {"cannot be set with a selected model", _} = changeset.errors[:model_other]

      assert {:error, changeset} = edit(s, :tip, tip.id, 1, %{current | body: "a\0b"}, [])
      assert {"cannot contain a null byte", _} = changeset.errors[:body]

      assert Repo.reload!(tip) == tip

      # An unchanged historical choice stays selectable.
      assert {:ok, %{edit_version: 2}} =
               edit(s, :tip, tip.id, 1, %{current | body: "Still on the retired model."}, [])

      assert %Tip{model_id: model_id} = Repo.reload!(tip)
      assert model_id == retired.id
    end

    test "retained media survives text edits and media mutations are rejected" do
      author = user_fixture()
      tip = tip_fixture(author, @tip_attrs)
      first = image_fixture(tip, position: 0, description: "First")
      second = attached_video_fixture(tip, position: 1)
      staged = staged_video_fixture(author)
      retained = [{:retained, first.id, "First"}, {:retained, second.id, nil}]
      s = scope(author)

      rejected = [
        {[], nil},
        {Enum.reverse(retained), nil},
        {[{:retained, first.id, "Changed"}, {:retained, second.id, nil}], nil},
        {[{:retained, first.id, "First"}], nil},
        {retained ++ [{:staged_video, staged.id}], [media_id: staged.id]},
        {retained ++ [{:image_file, "slot-1", %{path: "/tmp/x", filename: "x.png"}, nil}],
         [slot: "slot-1"]},
        {retained ++ [{:missing_image, "slot-2"}], [slot: "slot-2"]},
        {retained ++ [:malformed], nil}
      ]

      for {uploads, keys} <- rejected do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 edit(s, :tip, tip.id, 1, %{@tip_attrs | body: "Changed body"}, uploads)

        assert {_message, error_keys} = changeset.errors[:uploads]
        if keys, do: assert(Keyword.take(error_keys, Keyword.keys(keys)) == keys)
      end

      assert %Tip{edit_version: 1} = Repo.reload!(tip)
      media = media_rows()

      # Equal descriptions compare blank-to-nil; the text edit keeps every attachment.
      kept = [{:retained, first.id, "First"}, {:retained, second.id, " "}]

      assert {:ok, %{outcome: :updated, edit_version: 2}} =
               edit(s, :tip, tip.id, 1, %{@tip_attrs | body: "Changed body"}, kept)

      assert media_rows() == media

      # An unchanged complete selection is still a no-op.
      assert {:ok, %{outcome: :noop}} =
               edit(s, :tip, tip.id, 2, %{@tip_attrs | body: "Changed body"}, retained)
    end
  end

  describe "rejections" do
    test "deleted foreign and ineligible targets return explicit errors" do
      author = user_fixture()
      tip = tip_fixture(author, @tip_attrs)
      review = review_fixture(tip, Map.put(@review_attrs, :user_id, author.id))
      deleted = tip_fixture(author, @tip_attrs) |> put_marker!(:deleted)
      other = scope(user_fixture())
      moderator = scope(moderator!(user_fixture()))

      for {s, kind, id} <- [
            {other, :tip, tip.id},
            {moderator, :tip, tip.id},
            {scope(author), :tip, deleted.id},
            {scope(author), :tip, review.id + 1_000_000},
            {scope(author), :review, tip.id + 1_000_000},
            {scope(author), :tip, "not-an-id"},
            {scope(author), :tip, -1}
          ] do
        assert {:error, :not_found} = Content.get_edit_form(s, kind, id)
        attrs = attrs(kind, tip_or_review(kind, tip, review))
        assert {:error, :not_found} = edit(s, kind, id, 1, attrs, [])
      end

      for kind <- [:tip, :review] do
        row = tip_or_review(kind, tip, review)
        attrs = attrs(kind, row)

        assert {:error, :unauthenticated} = Content.get_edit_form(nil, kind, row.id)
        assert {:error, :unauthenticated} = edit(nil, kind, row.id, 1, attrs, [])

        assert {:error, :forbidden} =
                 edit(scope(full_ban!(author)), kind, row.id, 1, %{attrs | body: "x y z"}, [])

        unban!(author)

        assert {:error, :unconfirmed} =
                 edit(scope(unconfirm!(author)), kind, row.id, 1, %{attrs | body: "x y z"}, [])

        confirm!(author)
      end

      # Ownership is lost with the account; a stale admitted scope cannot edit.
      stale = scope(author)
      delete_account!(author)

      assert {:error, :unauthenticated} =
               edit(stale, :tip, tip.id, 1, %{@tip_attrs | body: "Too late"}, [])

      assert {:error, :unauthenticated} = Content.get_edit_form(stale, :tip, tip.id)
      assert %Tip{edit_version: 1} = Repo.reload!(tip)
    end

    test "write admission denies without mutation" do
      {limit, _window_ms} = Application.fetch_env!(:tips, AdmissionLimiter)[:write]
      author = user_fixture()
      tip = tip_fixture(author, @tip_attrs)
      s = scope(author)

      for _ <- 1..limit//1, do: assert(:ok = AdmissionLimiter.check_write(s))

      assert {:error, {:rate_limited, seconds}} =
               edit(s, :tip, tip.id, 1, %{@tip_attrs | body: "Over the limit"}, [])

      assert seconds > 0
      assert Repo.reload!(tip) == tip

      # Reading the form consumes no write budget.
      assert {:ok, %{edit_version: 1}} = Content.get_edit_form(s, :tip, tip.id)
    end
  end

  defp scope(user), do: Scope.for_user(user)
  defp key, do: Ecto.UUID.generate()

  defp edit(scope, :tip, id, version, attrs, uploads),
    do: Content.edit_tip(scope, id, version, attrs, uploads)

  defp edit(scope, :review, id, version, attrs, uploads),
    do: Content.edit_review(scope, id, version, attrs, uploads)

  defp attrs(kind, row), do: Map.take(row, @fields[kind])

  defp tip_id(%Tip{id: id}), do: id
  defp tip_id(%Review{tip_id: id}), do: id

  defp tip_or_review(:tip, tip, _review), do: tip
  defp tip_or_review(:review, _tip, review), do: review

  defp content(:tip) do
    author = user_fixture()
    {author, tip_fixture(author, @tip_attrs)}
  end

  defp content(:review) do
    author = user_fixture()
    {author, review_fixture(tip_fixture(), Map.put(@review_attrs, :user_id, author.id))}
  end

  # Published content has its search document.
  defp published(:tip) do
    author = user_fixture()
    {:ok, %{id: id}} = Content.publish_tip(scope(author), key(), @tip_attrs, [])
    {author, Repo.get!(Tip, id)}
  end

  defp published(:review) do
    author = user_fixture()

    {:ok, %{id: id}} =
      Content.publish_review(scope(author), tip_fixture().id, key(), @review_attrs, [])

    {author, Repo.get!(Review, id)}
  end

  defp unban!(user),
    do: Repo.update_all(from(u in Tips.Accounts.User, where: u.id == ^user.id), set: [ban: nil])

  defp unconfirm!(user) do
    Repo.update_all(from(u in Tips.Accounts.User, where: u.id == ^user.id),
      set: [confirmed_at: nil]
    )

    Repo.get!(Tips.Accounts.User, user.id)
  end

  defp confirm!(user) do
    Repo.update_all(from(u in Tips.Accounts.User, where: u.id == ^user.id),
      set: [confirmed_at: DateTime.utc_now(:second)]
    )
  end

  defp curated!(schema, label, attrs \\ []) do
    id = "#{schema.__schema__(:source)}-#{System.unique_integer([:positive])}"

    schema
    |> struct!([id: id, label: label, sort_order: 100] ++ attrs)
    |> Repo.insert!()
  end

  defp media_rows, do: Repo.all(from(a in Asset, order_by: a.id))

  defp snapshot(tip_id, review_id) do
    %{
      tip: Repo.get!(Tip, tip_id) |> Map.from_struct() |> Map.drop([:__meta__]),
      review: Repo.get!(Review, review_id) |> Map.from_struct() |> Map.drop([:__meta__]),
      votes: Repo.all(from(v in Vote, order_by: v.id)),
      notifications: Repo.all(from(n in Notification, order_by: n.id))
    }
  end

  defp search_state(kind, id) do
    case Repo.query!(
           """
           SELECT search_text, text_at, embedding IS NOT NULL, embed_after
           FROM #{kind}_search WHERE #{kind}_id = $1
           """,
           [id]
         ) do
      %{rows: []} ->
        nil

      %{rows: [[text, token, vector?, embed_after]]} ->
        %{text: text, token: token, vector?: vector?, embed_after: embed_after}
    end
  end

  # Seed embedding and cooldown state so invalidation is visible.
  defp embed!(kind, id) do
    Repo.query!(
      """
      UPDATE #{kind}_search
      SET embedding = $2::text::vector(1024), embed_after = clock_timestamp() + interval '1 hour'
      WHERE #{kind}_id = $1
      """,
      [id, "[#{Enum.join([1 | List.duplicate(0, 1023)], ",")}]"]
    )

    assert %{vector?: true, embed_after: %DateTime{}} = state = search_state(kind, id)
    state
  end
end
