defmodule Tips.Content.PublicationTest do
  use Tips.DataCase, async: true

  alias Tips.Accounts.Scope
  alias Tips.AdmissionLimiter
  alias Tips.Content
  alias Tips.Content.{Notification, Review, Tag, Tip, Vote}
  alias Tips.Content.Search.Embeddings

  import Tips.AccountsFixtures
  import Tips.ContentFixtures
  import Tips.MediaFixtures
  import Tips.SearchFixtures, only: [search_row: 1, stub_provider: 0]
  import Tips.VisibilityFixtures

  @tip_attrs %{
    title: "Name the failing test first",
    body: "State the failing test before asking for a fix.",
    tag_id: "workflow",
    model_id: "claude",
    model_other: nil,
    environment_id: "ide",
    prompt: "  Fix   the test\n",
    output: nil
  }

  @review_attrs %{
    body: "Worked on my flaky suite.",
    model_id: nil,
    model_other: "Local Llama",
    environment_id: nil,
    prompt: nil,
    output: "  All green\n"
  }

  test "new tip commits content self vote and current search text" do
    author = user_fixture()
    other = user_fixture()
    key = Ecto.UUID.generate()

    forged =
      Map.merge(@tip_attrs, %{
        id: 9_999_999,
        user_id: other.id,
        up_count: 50,
        edit_version: 7,
        dead_at: DateTime.utc_now(:second)
      })

    assert {:ok, receipt} = Content.publish_tip(scope(author), key, forged, [])

    assert %{outcome: :created, kind: :tip, id: id, tip_id: id, submission_key: ^key} = receipt
    assert %{state: :live} = receipt
    assert map_size(receipt) == 6

    author_id = author.id

    assert %Tip{
             user_id: ^author_id,
             title: "Name the failing test first",
             prompt: "  Fix   the test\n",
             output: nil,
             edit_version: 1,
             up_count: 1,
             down_count: 0,
             score: 1,
             review_count: 0,
             dead_at: nil,
             deleted_at: nil,
             edited_at: nil
           } = Repo.get!(Tip, id)

    assert [%Vote{user_id: ^author_id, value: 1}] = votes(tip_id: id)

    assert search_text(:tip, id) ==
             Enum.join(
               [
                 "Name the failing test first",
                 "State the failing test before asking for a fix.",
                 "Fix the test",
                 "Workflow",
                 "Claude",
                 "IDE"
               ],
               "\n"
             )

    assert Repo.aggregate(Notification, :count) == 0
  end

  test "new review commits independent setup and eligible notification" do
    parent_author = user_fixture()
    reviewer = user_fixture()

    parent =
      tip_fixture(parent_author, %{
        model_id: "claude",
        environment_id: "ide",
        prompt: "Tip prompt"
      })

    key = Ecto.UUID.generate()

    assert {:ok, receipt} =
             Content.publish_review(scope(reviewer), parent.id, key, @review_attrs, [])

    parent_id = parent.id

    assert %{outcome: :created, kind: :review, id: id, tip_id: ^parent_id} = receipt
    assert %{submission_key: ^key, state: :live} = receipt

    reviewer_id = reviewer.id

    assert %Review{
             user_id: ^reviewer_id,
             tip_id: ^parent_id,
             model_id: nil,
             model_other: "Local Llama",
             environment_id: nil,
             prompt: nil,
             output: "  All green\n",
             edit_version: 1,
             up_count: 1,
             score: 1
           } = Repo.get!(Review, id)

    assert [%Vote{user_id: ^reviewer_id, value: 1}] = votes(review_id: id)
    assert search_text(:review, id) == "Worked on my flaky suite.\nAll green\nLocal Llama"
    assert %Tip{review_count: 1, up_count: 0} = Repo.reload!(parent)

    parent_author_id = parent_author.id

    assert [
             %Notification{
               user_id: ^parent_author_id,
               actor_id: ^reviewer_id,
               type: :tip_reviewed,
               tip_id: nil,
               review_id: ^id,
               count: 1,
               read_at: nil,
               updated_at: %DateTime{}
             }
           ] = Repo.all(Notification)

    assert {:ok, %{outcome: :created, id: own_id}} =
             Content.publish_review(
               scope(parent_author),
               parent.id,
               Ecto.UUID.generate(),
               @review_attrs,
               []
             )

    assert Repo.all_by(Notification, review_id: own_id) == []
    assert %Tip{review_count: 2} = Repo.reload!(parent)
  end

  for kind <- [:tip, :review] do
    test "#{kind}: a search document over 30,000 bytes is refused; one at the limit embeds" do
      kind = unquote(kind)
      scope = scope(user_fixture())

      # 10,000 two-byte characters pass the field limit but fill 20,000 bytes.
      over = limit_attrs(kind, 1)
      assert {:error, {:too_long, 1}} = publish(kind, scope, over)
      assert Repo.aggregate("tip_search", :count) == 0
      assert Repo.aggregate("review_search", :count) == 0
      assert Repo.all(from(c in schema(kind), where: c.body == ^over.body)) == []

      assert {:ok, %{outcome: :created, id: id}} = publish(kind, scope, limit_attrs(kind, 0))
      assert byte_size(search_text(kind, id)) == 30_000

      stub_provider()
      assert %{embedded: 1, failed: failed} = Embeddings.scan()
      assert failed == %{}
      assert %{embedding: "[1," <> _} = search_row({kind, id})
    end
  end

  describe "existing keys reconcile before validation without repeating effects" do
    test "a tip key returns its comparison and current state" do
      author = user_fixture()
      scope = scope(author)
      key = Ecto.UUID.generate()
      assert {:ok, %{outcome: :created, id: id}} = Content.publish_tip(scope, key, @tip_attrs, [])
      text_at = search_text_at(:tip, id)

      retry = &Content.publish_tip(scope, key, &1, &2)
      receipt = %{kind: :tip, id: id, tip_id: id, submission_key: key, state: :live}

      assert {:ok, Map.put(receipt, :outcome, :existing_equivalent)} ==
               retry.(@tip_attrs, [])

      # Blank text compares as the changesets store it.
      assert {:ok, %{outcome: :existing_equivalent}} = retry.(%{@tip_attrs | output: "  "}, [])

      assert {:ok, %{outcome: :existing_different, id: ^id}} =
               retry.(%{@tip_attrs | title: "Another title"}, [])

      # A blank required field is not validated for an existing key.
      assert {:ok, %{outcome: :existing_different}} = retry.(%{@tip_attrs | title: nil}, [])

      for {attrs, uploads} <- [
            {Map.delete(@tip_attrs, :output), []},
            {@tip_attrs, nil},
            {@tip_attrs, [{:missing_image, "slot-1"}]},
            {@tip_attrs,
             [{:image_file, "slot-2", %{path: "/tmp/x.png", filename: "x.png"}, nil}]},
            {%{}, []}
          ] do
        assert {:ok, %{outcome: :existing_unknown, id: ^id}} = retry.(attrs, uploads)
      end

      assert {:ok, %{outcome: :existing_unknown, id: ^id}} =
               Content.get_publication(scope, :tip, key, nil)

      assert {:ok, %{outcome: :existing_equivalent, id: ^id}} =
               Content.get_publication(scope, :tip, key, %{attrs: @tip_attrs, uploads: []})

      assert [_vote] = votes(tip_id: id)
      assert search_text_at(:tip, id) == text_at
      assert Repo.aggregate(Tip, :count) == 1

      # Another account's key is a separate namespace.
      assert {:ok, %{outcome: :created, id: other_id}} =
               Content.publish_tip(scope(user_fixture()), key, @tip_attrs, [])

      refute other_id == id
    end

    test "saved attachments compare by media identity" do
      author = user_fixture()
      scope = scope(author)
      key = Ecto.UUID.generate()
      assert {:ok, %{id: id}} = Content.publish_tip(scope, key, @tip_attrs, [])
      image = image_fixture(Repo.get!(Tip, id), %{description: "Diff", position: 0})
      video = attached_video_fixture(Repo.get!(Tip, id), %{position: 1})

      assert {:ok, %{outcome: :existing_equivalent}} =
               Content.publish_tip(scope, key, @tip_attrs, [
                 {:retained, image.id, "Diff"},
                 {:staged_video, video.id}
               ])

      assert {:ok, %{outcome: :existing_different}} =
               Content.publish_tip(scope, key, @tip_attrs, [])

      assert {:ok, %{outcome: :existing_unknown}} =
               Content.publish_tip(scope, key, @tip_attrs, [
                 {:retained, image.id, "Diff"},
                 {:missing_image, "slot-1"}
               ])
    end

    test "current hidden and deleted state decides what compares" do
      author = user_fixture()
      scope = scope(author)
      key = Ecto.UUID.generate()
      assert {:ok, %{id: id}} = Content.publish_tip(scope, key, @tip_attrs, [])

      put_marker!(Repo.get!(Tip, id), :hidden)

      assert {:ok, %{outcome: :existing_equivalent, state: :hidden}} =
               Content.publish_tip(scope, key, @tip_attrs, [])

      put_marker!(Repo.get!(Tip, id), :deleted)

      assert {:ok, %{outcome: :existing_unknown, state: :deleted, id: ^id}} =
               Content.publish_tip(scope, key, @tip_attrs, [])

      # A ban blocks new writes, not reconciliation of a committed key.
      full_ban!(author)
      banned = scope(Repo.reload!(author))

      assert {:ok, %{outcome: :existing_unknown, id: ^id}} =
               Content.publish_tip(banned, key, @tip_attrs, [])
    end

    test "a review key names its parent and keeps notification state" do
      parent_author = user_fixture()
      reviewer = user_fixture()
      scope = scope(reviewer)
      parent = tip_fixture(parent_author)
      other_parent = tip_fixture(parent_author)
      key = Ecto.UUID.generate()

      assert {:ok, %{outcome: :created, id: id}} =
               Content.publish_review(scope, parent.id, key, @review_attrs, [])

      [notification] = Repo.all(Notification)
      text_at = search_text_at(:review, id)

      assert {:ok, %{outcome: :existing_equivalent, id: ^id, tip_id: tip_id}} =
               Content.publish_review(scope, parent.id, key, @review_attrs, [])

      assert tip_id == parent.id

      assert {:ok, %{outcome: :existing_unknown}} =
               Content.publish_review(scope, parent.id, key, %{body: "Incomplete"}, nil)

      assert {:error, :conflict} =
               Content.publish_review(scope, other_parent.id, key, @review_attrs, [])

      assert {:error, :conflict} =
               Content.get_publication(scope, {:review, other_parent.id}, key, nil)

      assert {:ok, %{outcome: :existing_unknown, id: ^id}} =
               Content.get_publication(scope, {:review, parent.id}, key, nil)

      assert {:ok, nil} = Content.get_publication(scope, :tip, key, nil)
      assert {:ok, nil} = Content.get_publication(scope, {:review, parent.id}, "not-a-key", nil)

      assert [^notification] = Repo.all(Notification)
      assert search_text_at(:review, id) == text_at
      assert [_vote] = votes(review_id: id)
      assert %Tip{review_count: 1} = Repo.reload!(parent)
    end

    test "lookups require an account" do
      key = Ecto.UUID.generate()
      assert {:error, :unauthenticated} = Content.get_publication(nil, :tip, key, nil)
      assert {:error, :unauthenticated} = Content.publish_tip(nil, key, @tip_attrs, [])
    end
  end

  describe "new publication rejects invalid intent and curated choices without writes" do
    test "incomplete or invalid fields and selections return changeset errors" do
      scope = scope(user_fixture())

      assert {:error, changeset} =
               Content.publish_tip(scope, key(), Map.delete(@tip_attrs, :output), [])

      assert {"is missing", [validation: :intent]} = changeset.errors[:output]

      assert {:error, changeset} =
               Content.publish_tip(scope, key(), %{@tip_attrs | title: nil, body: "x"}, nil)

      assert %{title: ["can't be blank"], body: [_too_short], uploads: ["is invalid"]} =
               errors_on(changeset)

      assert {:error, changeset} =
               Content.publish_tip(scope, key(), %{@tip_attrs | model_other: "Other"}, [])

      assert %{model_other: ["cannot be set with a selected model"]} = errors_on(changeset)

      assert {:error, changeset} =
               Content.publish_tip(scope, "not-a-key", @tip_attrs, [])

      assert %{submission_key: ["is invalid"]} = errors_on(changeset)

      assert {:error, %{errors: [submission_key: _]}} =
               Content.publish_tip(scope, :crypto.strong_rand_bytes(16), @tip_attrs, [])

      uploads = [
        {:missing_image, "slot-1"},
        {:retained, 5, nil},
        {:staged_video, 7},
        {:image_file, "slot-2", %{path: "/tmp/x.png", filename: "x.png"}, nil},
        {:staged_video, -1}
      ]

      assert {:error, changeset} = Content.publish_tip(scope, key(), @tip_attrs, uploads)

      assert [
               {"must be selected again", [slot: "slot-1"]},
               {"cannot be kept in a new publication", [media_id: 5]},
               {"is not supported yet", [slot: "slot-2"]},
               {"is invalid", []}
             ] = for({:uploads, error} <- changeset.errors, do: error)

      assert {:error, changeset} =
               Content.publish_review(
                 scope,
                 tip_fixture().id,
                 key(),
                 %{@review_attrs | body: " "},
                 []
               )

      assert %{body: ["can't be blank"]} = errors_on(changeset)
      assert_no_writes()
    end

    test "unknown and inactive curated choices are changeset errors" do
      scope = scope(user_fixture())

      Repo.insert!(%Tag{id: "retired", label: "Retired", sort_order: 99, active: false})

      for {field, value, message} <- [
            {:tag_id, "unknown", "does not exist"},
            {:model_id, "unknown", "does not exist"},
            {:environment_id, "unknown", "does not exist"},
            {:tag_id, "retired", "is not available"}
          ] do
        assert {:error, changeset} =
                 Content.publish_tip(scope, key(), Map.put(@tip_attrs, field, value), [])

        assert %{^field => [^message]} = errors_on(changeset)
      end

      parent = tip_fixture()

      assert {:error, changeset} =
               Content.publish_review(
                 scope,
                 parent.id,
                 key(),
                 %{@review_attrs | model_id: "unknown", model_other: nil},
                 []
               )

      assert %{model_id: ["does not exist"]} = errors_on(changeset)

      assert_no_writes()
    end

    test "null-byte curated ids are field errors, not unknown outcomes" do
      scope = scope(user_fixture())
      parent = tip_fixture()
      review_attrs = %{@review_attrs | model_other: nil}

      for field <- [:tag_id, :model_id, :environment_id] do
        assert {:error, changeset} =
                 Content.publish_tip(scope, key(), Map.put(@tip_attrs, field, "bad\0id"), [])

        assert %{^field => ["cannot contain a null byte"]} = errors_on(changeset)
      end

      for field <- [:model_id, :environment_id] do
        assert {:error, changeset} =
                 Content.publish_review(
                   scope,
                   parent.id,
                   key(),
                   Map.put(review_attrs, field, "bad\0id"),
                   []
                 )

        assert %{^field => ["cannot contain a null byte"]} = errors_on(changeset)
      end

      assert_no_writes()
    end

    test "ineligible authors and parents are rejected" do
      assert {:error, :unauthenticated} = Content.publish_tip(nil, key(), @tip_attrs, [])

      for {account, error} <- [
            {unconfirmed_user_fixture(), :unconfirmed},
            {full_ban!(user_fixture()), :forbidden},
            {delete_account!(user_fixture()), :unauthenticated}
          ] do
        assert {:error, ^error} = Content.publish_tip(scope(account), key(), @tip_attrs, [])
      end

      # A scope admitted before the ban carries stale state; the locked row decides.
      stale = scope(user_fixture())
      full_ban!(stale.user)
      assert {:error, :forbidden} = Content.publish_tip(stale, key(), @tip_attrs, [])

      scope = scope(user_fixture())

      for marker <- [:hidden, :deleted] do
        parent = put_marker!(tip_fixture(), marker)

        assert {:error, :not_found} =
                 Content.publish_review(scope, parent.id, key(), @review_attrs, [])
      end

      for tip_id <- [0, -1, 9_223_372_036_854_775_808, "1", nil, missing_tip_id()] do
        assert {:error, :not_found} =
                 Content.publish_review(scope, tip_id, key(), @review_attrs, [])
      end

      assert_no_writes()
    end
  end

  test "another key cannot create a second undeleted review" do
    reviewer = user_fixture()
    scope = scope(reviewer)
    parent = tip_fixture()
    first_key = key()

    assert {:ok, %{outcome: :created, id: first_id}} =
             Content.publish_review(scope, parent.id, first_key, @review_attrs, [])

    assert {:error, :already_reviewed} =
             Content.publish_review(scope, parent.id, key(), @review_attrs, [])

    put_marker!(Repo.get!(Review, first_id), :hidden)

    assert {:error, :already_reviewed} =
             Content.publish_review(scope, parent.id, key(), @review_attrs, [])

    put_marker!(Repo.get!(Review, first_id), :deleted)

    assert {:ok, %{outcome: :created, id: second_id}} =
             Content.publish_review(scope, parent.id, key(), @review_attrs, [])

    refute second_id == first_id

    assert {:ok, %{outcome: :existing_unknown, id: ^first_id, state: :deleted}} =
             Content.publish_review(scope, parent.id, first_key, @review_attrs, [])

    assert Repo.aggregate(Review, :count) == 2
  end

  test "write admission denies before mutation and survives downstream failure" do
    {limit, _window_ms} = Application.fetch_env!(:tips, AdmissionLimiter)[:write]
    scope = scope(user_fixture())
    key = key()

    assert {:ok, %{outcome: :created, id: id}} = Content.publish_tip(scope, key, @tip_attrs, [])

    for _ <- 3..limit//1, do: assert(:ok = AdmissionLimiter.check_write(scope))

    # The last admitted write fails downstream; its budget is not refunded.
    assert {:error, %Ecto.Changeset{}} =
             Content.publish_tip(scope, key(), %{@tip_attrs | title: nil}, [])

    assert {:error, {:rate_limited, seconds}} =
             Content.publish_tip(scope, key(), @tip_attrs, [])

    assert seconds > 0

    assert {:error, {:rate_limited, _seconds}} =
             Content.publish_review(scope, tip_fixture().id, key(), @review_attrs, [])

    # Recovery of a committed key needs no write budget.
    assert {:ok, %{outcome: :existing_equivalent, id: ^id}} =
             Content.publish_tip(scope, key, @tip_attrs, [])

    assert {:ok, %{outcome: :existing_unknown, id: ^id}} =
             Content.get_publication(scope, :tip, key, nil)

    assert [%Tip{id: ^id}] = Repo.all_by(Tip, user_id: scope.user.id)
  end

  defp scope(user), do: Scope.for_user(user)
  defp key, do: Ecto.UUID.generate()

  defp missing_tip_id do
    tip = tip_fixture()
    Repo.delete!(tip)
    tip.id
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

  defp publish(:tip, scope, attrs), do: Content.publish_tip(scope, key(), attrs, [])

  defp publish(:review, scope, attrs),
    do: Content.publish_review(scope, tip_fixture().id, key(), attrs, [])

  defp schema(:tip), do: Tip
  defp schema(:review), do: Review

  defp votes(target), do: Repo.all(from(v in Vote, where: ^target))

  defp search_text(:tip, id),
    do: Repo.one!(from(s in "tip_search", where: s.tip_id == ^id, select: s.search_text))

  defp search_text(:review, id),
    do: Repo.one!(from(s in "review_search", where: s.review_id == ^id, select: s.search_text))

  defp search_text_at(:tip, id),
    do: Repo.one!(from(s in "tip_search", where: s.tip_id == ^id, select: s.text_at))

  defp search_text_at(:review, id),
    do: Repo.one!(from(s in "review_search", where: s.review_id == ^id, select: s.text_at))

  # Fixture content has no votes, search rows or notifications; publication would add them.
  defp assert_no_writes do
    assert Repo.all(Vote) == []
    assert Repo.all(Notification) == []
    assert Repo.aggregate("tip_search", :count) == 0
    assert Repo.aggregate("review_search", :count) == 0
    assert Repo.all(from(t in Tip, where: t.title == ^@tip_attrs.title)) == []
    assert Repo.all(from(r in Review, where: r.body == ^@review_attrs.body)) == []
  end
end
