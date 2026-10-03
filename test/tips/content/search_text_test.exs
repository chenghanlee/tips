defmodule Tips.Content.SearchTextTest do
  use Tips.DataCase, async: true

  alias Tips.Content.{Environment, Model, Review, Search, Tag, Tip}

  import Tips.AccountsFixtures
  import Tips.ContentFixtures

  describe "tip writer builds all searchable fields from persisted content" do
    test "uses curated labels and normalizes every part" do
      tag = curated!(Tag, "Output\u00A0format")
      model = curated!(Model, "Claude  Opus")
      environment = curated!(Environment, "IDE\tplugin")

      tip =
        tip_fixture(user_fixture(), %{
          title: "  Fix   flaky\ttests ",
          body: "First line.\n\n  Second\u3000line, with café and cafe\u0301.",
          prompt: "Rewrite\r\nthe test",
          output: " Stable  OUTPUT! ",
          tag_id: tag.id,
          model_id: model.id,
          environment_id: environment.id
        })

      write!(:tip, tip.id)

      assert %{text: text} = search_state(:tip, tip.id)

      assert text ==
               Enum.join(
                 [
                   "Fix flaky tests",
                   "First line. Second line, with café and cafe\u0301.",
                   "Rewrite the test",
                   "Stable OUTPUT!",
                   "Output format",
                   "Claude Opus",
                   "IDE plugin"
                 ],
                 "\n"
               )

      assert %Tip{title: "  Fix   flaky\ttests ", output: " Stable  OUTPUT! "} =
               Repo.get!(Tip, tip.id)
    end

    test "skips blank optional parts and uses the free-text model" do
      tag = curated!(Tag, "Persona")

      tip =
        tip_fixture(user_fixture(), %{
          title: "Title",
          body: "Body",
          tag_id: tag.id,
          model_other: " Local   Llama 3 "
        })

      write!(:tip, tip.id)

      assert %{text: "Title\nBody\nPersona\nLocal Llama 3"} = search_state(:tip, tip.id)
    end
  end

  describe "review writer indexes only the reviewer's own setup" do
    test "parent tag and setup never enter review text and the parent is unchanged" do
      tip =
        tip_fixture(user_fixture(), %{
          tag_id: curated!(Tag, "Parent tag").id,
          model_id: curated!(Model, "Parent model").id,
          environment_id: curated!(Environment, "Parent environment").id
        })

      write!(:tip, tip.id)

      bare = review_fixture(tip, %{body: "  Worked\nfor me ", prompt: nil, output: nil})

      own =
        review_fixture(tip, %{
          body: "Different setup",
          prompt: "My prompt",
          output: "My output",
          model_id: curated!(Model, "Reviewer model").id,
          environment_id: curated!(Environment, "Reviewer environment").id
        })

      free_text = review_fixture(tip, %{body: "Free text", model_other: "Mistral\u00A0Large"})
      parent_row = Repo.get!(Tip, tip.id)
      parent_search = search_state(:tip, tip.id)

      for review <- [bare, own, free_text], do: write!(:review, review.id)

      assert %{text: "Worked for me"} = search_state(:review, bare.id)

      assert %{
               text: "Different setup\nMy prompt\nMy output\nReviewer model\nReviewer environment"
             } =
               search_state(:review, own.id)

      assert %{text: "Free text\nMistral Large"} = search_state(:review, free_text.id)
      assert Repo.get!(Tip, tip.id) == parent_row
      assert search_state(:tip, tip.id) == parent_search
    end
  end

  describe "output-only changes and retags replace text and invalidate embedding state" do
    test "tip output edit and retag" do
      tip = tip_fixture(user_fixture(), %{output: "Old output"})
      write!(:tip, tip.id)
      embedded = embed!(:tip, tip.id)

      assert {:ok, :edited} =
               Repo.transact(fn ->
                 update!(tip, output: "New output")
                 assert :ok = Search.write_tip_text(tip.id)
                 {:ok, :edited}
               end)

      assert %{text: text, vector?: false, embed_after: nil} =
               edited = search_state(:tip, tip.id)

      assert text =~ "New output"
      refute text =~ "Old output"
      assert_later(edited, embedded)

      embedded = embed!(:tip, tip.id)
      tag = curated!(Tag, "Retagged technique")

      assert {:ok, :retagged} =
               Repo.transact(fn ->
                 update!(Repo.get!(Tip, tip.id), tag_id: tag.id)
                 assert :ok = Search.write_tip_text(tip.id)
                 {:ok, :retagged}
               end)

      assert %{text: text, vector?: false, embed_after: nil} =
               retagged = search_state(:tip, tip.id)

      assert text |> String.split("\n") |> Enum.member?("Retagged technique")
      assert_later(retagged, embedded)
    end

    test "review output edit" do
      review = review_fixture(tip_fixture(), %{output: "Old output"})
      write!(:review, review.id)
      embedded = embed!(:review, review.id)

      assert {:ok, :edited} =
               Repo.transact(fn ->
                 update!(review, output: "New output")
                 assert :ok = Search.write_review_text(review.id)
                 {:ok, :edited}
               end)

      assert %{text: text, vector?: false, embed_after: nil} =
               edited = search_state(:review, review.id)

      assert text =~ "New output"
      refute text =~ "Old output"
      assert_later(edited, embedded)
    end
  end

  describe "two canonical writes in one transaction have distinct freshness" do
    for kind <- [:tip, :review] do
      test "#{kind} tokens strictly increase without sleeping" do
        kind = unquote(kind)
        content = content(kind)

        assert %{rows: [[future]]} =
                 Repo.query!(
                   """
                   INSERT INTO #{table(kind)} (#{id_column(kind)}, search_text, text_at)
                   VALUES ($1, 'future text', clock_timestamp() + interval '1 day')
                   RETURNING text_at
                   """,
                   [content.id]
                 )

        assert {:ok, {first, second}} =
                 Repo.transact(fn ->
                   assert :ok = write(kind, content.id)
                   first = search_state(kind, content.id)
                   update!(content, output: "Changed in the same transaction")
                   assert :ok = write(kind, content.id)
                   {:ok, {first, search_state(kind, content.id)}}
                 end)

        assert DateTime.diff(first.token, future, :microsecond) >= 1
        assert second.text =~ "Changed in the same transaction"
        assert_later(second, first)
      end
    end
  end

  describe "caller rollback restores content and complete search state" do
    for kind <- [:tip, :review] do
      test "#{kind} insert and update roll back with the caller" do
        kind = unquote(kind)
        content = content(kind)

        assert {:error, :caller_failed} =
                 Repo.transact(fn ->
                   update!(content, output: "Rolled-back output")
                   :ok = write(kind, content.id)
                   {:error, :caller_failed}
                 end)

        assert reload(content) == content
        assert search_state(kind, content.id) == nil

        write!(kind, content.id)
        committed = embed!(kind, content.id)
        committed_content = reload(content)

        assert {:error, :caller_failed} =
                 Repo.transact(fn ->
                   update!(committed_content, output: "Rolled-back output")
                   :ok = write(kind, content.id)
                   {:error, :caller_failed}
                 end)

        assert reload(content) == committed_content
        assert search_state(kind, content.id) == committed
      end
    end
  end

  describe "canonical writers require a caller transaction" do
    test "outside a transaction" do
      tip = tip_fixture()
      review = review_fixture(tip)

      assert_raise ArgumentError, ~r/caller transaction/, fn -> Search.write_tip_text(tip.id) end

      assert_raise ArgumentError, ~r/caller transaction/, fn ->
        Search.write_review_text(review.id)
      end

      assert search_state(:tip, tip.id) == nil
      assert search_state(:review, review.id) == nil
    end
  end

  defp content(:tip), do: tip_fixture(user_fixture(), %{output: "Original output"})
  defp content(:review), do: review_fixture(tip_fixture(), %{output: "Original output"})

  defp reload(%Tip{id: id}), do: Repo.get!(Tip, id)
  defp reload(%Review{id: id}), do: Repo.get!(Review, id)

  defp update!(content, changes), do: content |> Ecto.Changeset.change(changes) |> Repo.update!()

  defp write(:tip, id), do: Search.write_tip_text(id)
  defp write(:review, id), do: Search.write_review_text(id)

  defp write!(kind, id) do
    assert {:ok, :written} =
             Repo.transact(fn ->
               :ok = write(kind, id)
               {:ok, :written}
             end)
  end

  defp curated!(schema, label, attrs \\ []) do
    id = "#{schema.__schema__(:source)}-#{System.unique_integer([:positive])}"

    schema
    |> struct!([id: id, label: label, sort_order: 100] ++ attrs)
    |> Repo.insert!()
  end

  defp search_state(kind, id) do
    case Repo.query!(
           """
           SELECT search_text, text_at, embedding IS NOT NULL, embed_after
           FROM #{table(kind)}
           WHERE #{id_column(kind)} = $1
           """,
           [id]
         ) do
      %{rows: []} ->
        nil

      %{rows: [[text, token, vector?, embed_after]]} ->
        %{text: text, token: token, vector?: vector?, embed_after: embed_after}
    end
  end

  # Seed embedding and cooldown state so writer invalidation is visible.
  defp embed!(kind, id) do
    Repo.query!(
      """
      UPDATE #{table(kind)}
      SET embedding = $2::text::vector(1024), embed_after = clock_timestamp() + interval '1 hour'
      WHERE #{id_column(kind)} = $1
      """,
      [id, unit_vector()]
    )

    assert %{vector?: true, embed_after: %DateTime{}} = state = search_state(kind, id)
    state
  end

  defp assert_later(%{token: later}, %{token: earlier}) do
    assert DateTime.compare(later, earlier) == :gt
  end

  defp table(:tip), do: "tip_search"
  defp table(:review), do: "review_search"

  defp id_column(:tip), do: "tip_id"
  defp id_column(:review), do: "review_id"

  defp unit_vector, do: "[#{Enum.join([1 | List.duplicate(0, 1023)], ",")}]"
end
