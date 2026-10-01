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

        assert {:ok, {first, second}} =
                 Repo.transact(fn ->
                   assert :ok = write(kind, content.id)
                   first = search_state(kind, content.id)
                   update!(content, output: "Changed in the same transaction")
                   assert :ok = write(kind, content.id)
                   {:ok, {first, search_state(kind, content.id)}}
                 end)

        assert second.text =~ "Changed in the same transaction"
        assert_later(second, first)
      end

      test "#{kind} token advances past a future token" do
        kind = unquote(kind)
        content = content(kind)

        %{rows: [[future]]} =
          Repo.query!(
            """
            INSERT INTO #{table(kind)} (#{id_column(kind)}, search_text, text_at)
            VALUES ($1, 'future text', clock_timestamp() + interval '1 day')
            RETURNING text_at
            """,
            [content.id]
          )

        write!(kind, content.id)

        assert %{token: token} = search_state(kind, content.id)
        assert DateTime.diff(token, future, :microsecond) >= 1
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

  describe "stale worker success and failure cannot overwrite a newer canonical document" do
    for kind <- [:tip, :review] do
      test "#{kind} guarded worker writes need the current token" do
        kind = unquote(kind)
        content = content(kind)
        write!(kind, content.id)
        %{token: stale_token} = search_state(kind, content.id)

        assert {:ok, :edited} =
                 Repo.transact(fn ->
                   update!(content, output: "Newer output")
                   :ok = write(kind, content.id)
                   {:ok, :edited}
                 end)

        newer = search_state(kind, content.id)

        assert %{num_rows: 0} = worker_success(kind, content.id, stale_token)
        assert %{num_rows: 0} = worker_failure(kind, content.id, stale_token)
        assert search_state(kind, content.id) == newer

        assert %{num_rows: 1} = worker_failure(kind, content.id, newer.token)
        assert %{vector?: false, embed_after: %DateTime{}} = search_state(kind, content.id)
        assert %{num_rows: 1} = worker_success(kind, content.id, newer.token)

        assert %{text: text, token: token, vector?: true} = search_state(kind, content.id)
        assert {text, token} == {newer.text, newer.token}
      end
    end
  end

  describe "vote and counter changes leave search text and freshness unchanged" do
    test "real votes and direct counter updates" do
      tip = tip_fixture()
      review = review_fixture(tip)
      write!(:tip, tip.id)
      write!(:review, review.id)
      tip_search = search_state(:tip, tip.id)
      review_search = search_state(:review, review.id)

      vote_fixture(tip)
      vote_fixture(review, %{value: -1})
      Repo.query!("UPDATE tips SET review_count = review_count + 1 WHERE id = $1", [tip.id])

      assert %Tip{up_count: 1} = Repo.get!(Tip, tip.id)
      assert %Review{down_count: 1} = Repo.get!(Review, review.id)
      assert search_state(:tip, tip.id) == tip_search
      assert search_state(:review, review.id) == review_search
    end
  end

  describe "label rebuild uses current labels through the canonical writer" do
    setup do
      tag = curated!(Tag, "Old tag")
      model = curated!(Model, "Old model")
      environment = curated!(Environment, "Old environment")

      tagged = tip_fixture(user_fixture(), %{tag_id: tag.id})

      set_up_tip =
        tip_fixture(user_fixture(), %{model_id: model.id, environment_id: environment.id})

      review =
        review_fixture(tip_fixture(), %{model_id: model.id, environment_id: environment.id})

      unaffected_tip = tip_fixture(user_fixture(), %{model_other: "Old model"})
      unaffected_review = review_fixture(tagged)

      for tip <- [tagged, set_up_tip, unaffected_tip], do: write!(:tip, tip.id)
      for review <- [review, unaffected_review], do: write!(:review, review.id)

      before =
        Map.new(
          [
            {:tip, tagged.id},
            {:tip, set_up_tip.id},
            {:tip, unaffected_tip.id},
            {:review, review.id},
            {:review, unaffected_review.id}
          ],
          fn {kind, id} = key -> {key, embed!(kind, id)} end
        )

      %{
        tag: tag,
        model: model,
        environment: environment,
        affected: [{:tip, tagged.id}, {:tip, set_up_tip.id}, {:review, review.id}],
        unaffected: [{:tip, unaffected_tip.id}, {:review, unaffected_review.id}],
        before: before
      }
    end

    test "rebuilds affected tips and reviews, including retired labels", context do
      assert {:ok, :rebuilt} =
               Repo.transact(fn ->
                 relabel!(context, active: false)
                 rebuild!(context)
                 {:ok, :rebuilt}
               end)

      [{:tip, tagged_id}, {:tip, set_up_tip_id}, {:review, review_id}] = context.affected

      assert %{text: "A useful technique\n" <> _ = tagged_text} = search_state(:tip, tagged_id)
      assert tagged_text |> String.split("\n") |> List.last() == "New tag"

      assert %{text: set_up_text} = search_state(:tip, set_up_tip_id)
      assert ["New model", "New environment"] = set_up_text |> String.split("\n") |> Enum.take(-2)

      assert %{text: review_text} = search_state(:review, review_id)

      assert [_body, "New model", "New environment"] = String.split(review_text, "\n")

      for key <- context.affected do
        state = search_state(elem(key, 0), elem(key, 1))
        assert %{vector?: false, embed_after: nil} = state
        assert_later(state, context.before[key])
      end

      for {kind, id} = key <- context.unaffected do
        assert search_state(kind, id) == context.before[key]
      end
    end

    test "label change and rebuild roll back together", context do
      assert {:error, :caller_failed} =
               Repo.transact(fn ->
                 relabel!(context)
                 rebuild!(context)
                 {:error, :caller_failed}
               end)

      assert %Tag{label: "Old tag"} = Repo.get!(Tag, context.tag.id)
      assert %Model{label: "Old model"} = Repo.get!(Model, context.model.id)

      for {kind, id} = key <- context.affected ++ context.unaffected do
        assert search_state(kind, id) == context.before[key]
      end
    end
  end

  describe "canonical writers require a caller transaction and fail for missing content" do
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

    test "missing content" do
      assert {:ok, :checked} =
               Repo.transact(fn ->
                 assert_raise Ecto.NoResultsError, fn -> Search.write_tip_text(-1) end
                 {:ok, :checked}
               end)

      assert {:ok, :checked} =
               Repo.transact(fn ->
                 assert_raise Ecto.NoResultsError, fn -> Search.write_review_text(-1) end
                 {:ok, :checked}
               end)
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

  # A maintenance caller changing curated labels, then rebuilding the affected
  # documents with the predicates documented in Tips.Content.Search.
  defp relabel!(context, attrs \\ []) do
    for {schema, row, label} <- [
          {Tag, context.tag, "New tag"},
          {Model, context.model, "New model"},
          {Environment, context.environment, "New environment"}
        ] do
      schema
      |> Repo.get!(row.id)
      |> Ecto.Changeset.change([label: label] ++ attrs)
      |> Repo.update!()
    end
  end

  defp rebuild!(%{tag: tag, model: model, environment: environment}) do
    %{rows: tip_rows} =
      Repo.query!(
        """
        SELECT id FROM tips
        WHERE tag_id = $1 OR model_id = $2 OR environment_id = $3
        ORDER BY id
        FOR NO KEY UPDATE
        """,
        [tag.id, model.id, environment.id]
      )

    %{rows: review_rows} =
      Repo.query!(
        """
        SELECT id FROM reviews
        WHERE model_id = $1 OR environment_id = $2
        ORDER BY id
        FOR NO KEY UPDATE
        """,
        [model.id, environment.id]
      )

    for [id] <- tip_rows, do: :ok = Search.write_tip_text(id)
    for [id] <- review_rows, do: :ok = Search.write_review_text(id)
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

  # Simulates a completed worker round plus a later cooldown, so invalidation
  # is visible on both columns.
  defp embed!(kind, id) do
    %{token: token} = search_state(kind, id)
    assert %{num_rows: 1} = worker_success(kind, id, token)

    Repo.query!(
      "UPDATE #{table(kind)} SET embed_after = clock_timestamp() + interval '1 hour' WHERE #{id_column(kind)} = $1",
      [id]
    )

    assert %{vector?: true, embed_after: %DateTime{}} = state = search_state(kind, id)
    state
  end

  defp worker_success(kind, id, token) do
    Repo.query!(
      """
      UPDATE #{table(kind)} SET embedding = $2::text::vector(1024)
      WHERE #{id_column(kind)} = $1 AND embedding IS NULL AND text_at = $3
      """,
      [id, unit_vector(), token]
    )
  end

  defp worker_failure(kind, id, token) do
    Repo.query!(
      """
      UPDATE #{table(kind)} SET embed_after = clock_timestamp() + interval '10 minutes'
      WHERE #{id_column(kind)} = $1 AND embedding IS NULL AND text_at = $2
      """,
      [id, token]
    )
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
