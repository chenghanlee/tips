defmodule Tips.Content.SchemaTest do
  use Tips.DataCase, async: true

  alias Tips.Content.{Environment, Model, Review, Tag, Tip, Vocabulary}

  import Tips.ContentFixtures
  import Tips.AccountsFixtures

  test "database rejects a tip title shorter than three code points" do
    user = user_fixture()
    Repo.query!("INSERT INTO tags (id, label, sort_order) VALUES ('other', 'Other technique', 9)")

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          INSERT INTO tips (user_id, submission_key, title, body, tag_id, created_at)
          VALUES ($1, $2, 'ab', 'A useful technique', 'other', $3)
          """,
          [user.id, Ecto.UUID.bingenerate(), DateTime.utc_now(:second)]
        )
      end

    assert error.postgres.constraint == "tips_title_chk"
  end

  describe "database checks" do
    for {table, fields} <- [
          {:tips,
           [
             title: {3, 140},
             body: {3, 20_000},
             model_other: {1, 80},
             prompt: {1, 20_000},
             output: {1, 20_000}
           ]},
          {:reviews,
           [body: {1, 20_000}, model_other: {1, 80}, prompt: {1, 20_000}, output: {1, 20_000}]}
        ],
        {field, {min, max}} <- fields,
        {case_name, value} <- [
          {:short, String.duplicate("x", min - 1)},
          {:long, String.duplicate("x", max + 1)},
          {:blank, " \t\n "}
        ] do
      test "#{table}_#{field}_chk rejects #{case_name}" do
        attrs = %{unquote(field) => unquote(value)}

        assert_raise Ecto.ConstraintError, ~r/#{unquote(table)}_#{unquote(field)}_chk/, fn ->
          insert_content(unquote(table), attrs)
        end
      end
    end

    for table <- [:tips, :reviews] do
      test "#{table}_model_one_chk rejects selected and custom model together" do
        assert_raise Ecto.ConstraintError, ~r/#{unquote(table)}_model_one_chk/, fn ->
          insert_content(unquote(table), %{model_id: "claude", model_other: "Custom model"})
        end
      end

      for field <- [:up_count, :down_count] ++ if(table == :tips, do: [:review_count], else: []) do
        test "#{table}_counts_chk rejects negative #{field}" do
          assert_raise Ecto.ConstraintError, ~r/#{unquote(table)}_counts_chk/, fn ->
            insert_content(unquote(table), %{unquote(field) => -1})
          end
        end
      end

      test "#{table} accepts positive boundaries and optional setup" do
        for attrs <- [
              %{body: if(unquote(table) == :tips, do: "abc", else: "x")},
              %{
                body: String.duplicate("x", 20_000),
                model_other: String.duplicate("x", 80),
                prompt: String.duplicate("x", 20_000),
                output: String.duplicate("x", 20_000)
              },
              %{model_id: "claude", environment_id: "cli"}
            ] do
          row = insert_content(unquote(table), attrs)
          assert row.id
          assert Repo.reload!(row).body == (attrs[:body] || row.body)
        end
      end
    end

    test "tips accept title boundaries, including code points in combining sequences" do
      for title <- ["abc", String.duplicate("x", 140), "e\u0301x"] do
        assert %{title: ^title} = tip_fixture(user_fixture(), %{title: title})
      end
    end
  end

  describe "submission identity and one undeleted review" do
    for table <- [:tips, :reviews], marker <- [nil, :deleted_at, :dead_at] do
      test "#{table}_submission_unique retains identity with #{inspect(marker)}" do
        original = insert_content(unquote(table), %{})
        set_visibility(original, unquote(marker))

        assert_raise Ecto.ConstraintError, ~r/#{unquote(table)}_submission_unique/, fn ->
          insert_content(unquote(table), %{
            user_id: original.user_id,
            submission_key: original.submission_key
          })
        end
      end
    end

    for table <- [:tips, :reviews] do
      test "#{table} allows the same submission key for a different author" do
        original = insert_content(unquote(table), %{})
        other = insert_content(unquote(table), %{submission_key: original.submission_key})
        refute other.user_id == original.user_id
      end
    end

    for marker <- [nil, :dead_at] do
      test "reviews_one_per_user includes #{inspect(marker)} reviews" do
        review = review_fixture()

        set_visibility(review, unquote(marker))

        assert_raise Ecto.ConstraintError, ~r/reviews_one_per_user/, fn ->
          review_fixture(Repo.get!(Tip, review.tip_id), %{user_id: review.user_id})
        end
      end
    end

    test "author deletion permits an intentional new review" do
      original = review_fixture()
      original |> change(deleted_at: DateTime.utc_now(:second)) |> Repo.update!()
      replacement = review_fixture(Repo.get!(Tip, original.tip_id), %{user_id: original.user_id})
      refute replacement.id == original.id
      refute replacement.submission_key == original.submission_key
    end
  end

  describe "foreign keys" do
    for {table, fields} <- [
          {:tips,
           [user_id: -1, tag_id: "unknown", model_id: "unknown", environment_id: "unknown"]},
          {:reviews, [user_id: -1, tip_id: -1, model_id: "unknown", environment_id: "unknown"]}
        ],
        {field, value} <- fields do
      test "#{table}_#{field}_fkey rejects unknown references" do
        assert_raise Ecto.ConstraintError, ~r/#{unquote(table)}_#{unquote(field)}_fkey/, fn ->
          insert_content(unquote(table), %{unquote(field) => unquote(value)})
        end
      end
    end

    test "deleting an author cannot cascade into tips" do
      user = user_fixture()
      tip_fixture(user)
      assert_raise Ecto.ConstraintError, ~r/tips_user_id_fkey/, fn -> Repo.delete!(user) end
    end

    test "deleting an author cannot cascade into reviews" do
      user = user_fixture()
      review_fixture(tip_fixture(), %{user_id: user.id})
      assert_raise Ecto.ConstraintError, ~r/reviews_user_id_fkey/, fn -> Repo.delete!(user) end
    end

    test "deleting a tip cannot cascade into reviews" do
      tip = tip_fixture()
      review_fixture(tip)
      assert_raise Ecto.ConstraintError, ~r/reviews_tip_id_fkey/, fn -> Repo.delete!(tip) end
    end
  end

  describe "ranking and timestamps" do
    test "generated tip scores match Hot reference across signs, dates and database time zones" do
      for zone <- ["UTC", "Asia/Taipei"],
          created_at <- [~U[2005-12-08 07:46:43Z], ~U[2026-09-21 12:00:00Z]],
          {up, down} <- [{0, 0}, {1, 0}, {10, 2}, {0, 5}] do
        Repo.query!("SET LOCAL TIME ZONE '#{zone}'")

        tip =
          tip_fixture(user_fixture(), %{up_count: up, down_count: down, created_at: created_at})

        assert tip.score == up - down
        assert_in_delta tip.hot_score, hot_reference(up - down, created_at), 1.0e-9
        assert Repo.reload!(tip).created_at == created_at
      end
    end

    test "generated review scores match Wilson reference and refresh after counter updates" do
      for {up, down} <- [{0, 0}, {1, 0}, {10, 2}, {0, 5}] do
        review = review_fixture(tip_fixture(), %{up_count: up, down_count: down})
        assert review.score == up - down
        assert_in_delta review.best_score, wilson_reference(up, down), 1.0e-9
        updated = review |> change(up_count: up + 1) |> Repo.update!()
        assert updated.score == up + 1 - down
        assert_in_delta updated.best_score, wilson_reference(up + 1, down), 1.0e-9
      end
    end

    test "Ecto supplies second-precision created_at and database defaults remain usable" do
      user = user_fixture()
      tip_fixture(user)

      tip =
        Repo.insert!(%Tip{
          user_id: user.id,
          submission_key: Ecto.UUID.generate(),
          title: "Title",
          body: "Body",
          tag_id: "other"
        })

      assert {_, 0} = tip.created_at.microsecond
      assert %{edit_version: 1, up_count: 0, down_count: 0, review_count: 0, score: 0} = tip

      review =
        Repo.insert!(%Review{
          user_id: user.id,
          tip_id: tip.id,
          submission_key: Ecto.UUID.generate(),
          body: "x"
        })

      assert {_, 0} = review.created_at.microsecond
      assert %{edit_version: 1, up_count: 0, down_count: 0, score: 0, best_score: +0.0} = review
    end
  end

  describe "visibility and indexes" do
    for table <- [:tips, :reviews] do
      test "live_#{table} excludes author-deleted and moderator-hidden rows" do
        live = insert_content(unquote(table), %{})
        insert_content(unquote(table), %{deleted_at: DateTime.utc_now(:second)})
        insert_content(unquote(table), %{dead_at: DateTime.utc_now(:second)})

        insert_content(unquote(table), %{
          deleted_at: DateTime.utc_now(:second),
          dead_at: DateTime.utc_now(:second)
        })

        assert %{rows: [[id]]} = Repo.query!("SELECT id FROM live_#{unquote(table)}")
        assert id == live.id
      end
    end

    test "a hidden parent does not hide its live reviews" do
      tip = tip_fixture(user_fixture(), %{dead_at: DateTime.utc_now(:second)})
      review = review_fixture(tip)
      assert %{rows: [[id]]} = Repo.query!("SELECT id FROM live_reviews")
      assert id == review.id
    end

    for {name, columns, live?} <- [
          {"tips_hot", "(hot_score DESC, id DESC)", true},
          {"tips_new", "(created_at DESC, id DESC)", true},
          {"tips_hot_by_tag", "(tag_id, hot_score DESC, id DESC)", true},
          {"tips_new_by_tag", "(tag_id, created_at DESC, id DESC)", true},
          {"tips_by_user", "(user_id, created_at DESC, id DESC)", false},
          {"reviews_best", "(tip_id, best_score DESC, id DESC)", true},
          {"reviews_new", "(tip_id, created_at DESC, id DESC)", true},
          {"reviews_by_user", "(user_id, created_at DESC, id DESC)", false}
        ] do
      test "#{name} has the designed order and visibility predicate" do
        assert %{rows: [[definition]]} =
                 Repo.query!(
                   "SELECT indexdef FROM pg_indexes WHERE schemaname = 'public' AND indexname = $1",
                   [unquote(name)]
                 )

        assert definition =~ unquote(columns)

        if unquote(live?) do
          assert definition =~ "WHERE ((deleted_at IS NULL) AND (dead_at IS NULL))"
        else
          refute definition =~ "WHERE"
        end
      end
    end
  end

  describe "author changesets" do
    for {schema, fields} <- [
          {Tip,
           [
             title: {3, 140},
             body: {3, 20_000},
             model_other: {1, 80},
             prompt: {1, 20_000},
             output: {1, 20_000}
           ]},
          {Review,
           [body: {1, 20_000}, model_other: {1, 80}, prompt: {1, 20_000}, output: {1, 20_000}]}
        ],
        {field, {min, max}} <- fields do
      test "#{inspect(schema)} validates #{field} in code points" do
        schema = unquote(schema)
        field = unquote(field)
        row = schema_fixture(schema)
        # Combining marks make each grapheme two PostgreSQL characters.
        too_long = String.duplicate("e\u0301", div(unquote(max), 2) + 1)
        assert %{^field => [_ | _]} = row |> schema.changeset(%{field => too_long}) |> errors_on()

        for value <- [String.duplicate("x", unquote(min)), String.duplicate("x", unquote(max))] do
          assert {:ok, saved} = row |> schema.changeset(%{field => value}) |> Repo.update()
          assert Map.fetch!(saved, field) == value
        end
      end
    end

    for schema <- [Tip, Review] do
      test "#{inspect(schema)} casts only author input and preserves verbatim examples" do
        schema = unquote(schema)
        row = schema_fixture(schema)

        assert {:ok, saved} =
                 row
                 |> schema.changeset(%{
                   up_count: 99,
                   down_count: 88,
                   review_count: 77,
                   score: 11,
                   edit_version: 5,
                   user_id: -1,
                   deleted_at: DateTime.utc_now(:second),
                   dead_at: DateTime.utc_now(:second),
                   prompt: "  exact\n",
                   output: "\noutput  "
                 })
                 |> Repo.update()

        assert saved.user_id == row.user_id

        assert %{
                 up_count: 0,
                 down_count: 0,
                 score: 0,
                 edit_version: 1,
                 deleted_at: nil,
                 dead_at: nil,
                 prompt: "  exact\n",
                 output: "\noutput  "
               } = saved
      end

      test "#{inspect(schema)} rejects model conflict and clears optional fields to null" do
        schema = unquote(schema)
        row = schema_fixture(schema)

        assert %{model_other: [_ | _]} =
                 row
                 |> schema.changeset(%{model_id: "claude", model_other: "Custom"})
                 |> errors_on()

        assert {:ok, selected} =
                 row
                 |> schema.changeset(%{
                   model_id: "claude",
                   environment_id: "chat",
                   prompt: "Example"
                 })
                 |> Repo.update()

        assert {:ok, cleared} =
                 selected
                 |> schema.changeset(%{model_id: "", environment_id: "", prompt: "   "})
                 |> Repo.update()

        assert %{model_id: nil, environment_id: nil, prompt: nil} = cleared
      end

      test "#{inspect(schema)} maps submission uniqueness to changeset errors" do
        schema = unquote(schema)
        original = schema_fixture(schema)
        attrs = duplicate_submission_attrs(original)

        assert {:error, changeset} =
                 schema
                 |> struct!(user_id: original.user_id)
                 |> schema.changeset(attrs)
                 |> Repo.insert()

        assert %{submission_key: ["has already been taken"]} = errors_on(changeset)
      end
    end

    test "review changeset maps one-per-user uniqueness" do
      original = review_fixture()

      attrs = %{
        tip_id: original.tip_id,
        body: "Another review",
        submission_key: Ecto.UUID.generate()
      }

      assert {:error, changeset} =
               %Review{user_id: original.user_id} |> Review.changeset(attrs) |> Repo.insert()

      assert %{tip_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "required fields reject missing and whitespace-only content" do
      for {schema, fields} <- [
            {Tip, [:title, :body, :tag_id, :submission_key]},
            {Review, [:body, :tip_id, :submission_key]}
          ] do
        errors = schema |> struct!() |> schema.changeset(%{}) |> errors_on()
        for field <- fields, do: assert(Map.has_key?(errors, field))
        row = schema_fixture(schema)
        assert %{body: [_ | _]} = row |> schema.changeset(%{body: " \t\n"}) |> errors_on()
      end
    end
  end

  test "vocabulary seeds are idempotent and restore labels, sort order and active flags" do
    Vocabulary.seed_tags!()
    Repo.update_all(Tag, set: [label: "Changed", sort_order: 99, active: false])
    Vocabulary.seed_tags!()
    assert Repo.aggregate(Tag, :count) == 9

    assert Repo.all(
             from t in Tag,
               order_by: t.sort_order,
               select: {t.id, t.label, t.sort_order, t.active}
           ) ==
             Enum.with_index(
               [
                 {"phrase", "Phrase"},
                 {"persona", "Persona"},
                 {"system-prompt", "System prompt"},
                 {"examples", "Examples"},
                 {"task-structure", "Task structure"},
                 {"output-format", "Output format"},
                 {"workflow", "Workflow"},
                 {"cost-and-speed", "Cost and speed"},
                 {"other", "Other technique"}
               ],
               1
             )
             |> Enum.map(fn {{id, label}, order} -> {id, label, order, true} end)

    refute Repo.exists?(Model)
    refute Repo.exists?(Environment)
    Vocabulary.seed_synthetic!()
    Repo.update_all(Model, set: [label: "Changed", sort_order: 99, active: false])
    Repo.update_all(Environment, set: [label: "Changed", sort_order: 99, active: false])
    Vocabulary.seed_synthetic!()

    assert Repo.all(
             from m in Model,
               order_by: m.sort_order,
               select: {m.id, m.label, m.sort_order, m.active}
           ) ==
             [
               {"claude", "Claude", 1, true},
               {"gpt", "GPT", 2, true},
               {"gemini", "Gemini", 3, true}
             ]

    assert Repo.all(
             from e in Environment,
               order_by: e.sort_order,
               select: {e.id, e.label, e.sort_order, e.active}
           ) ==
             [{"chat", "Chat", 1, true}, {"ide", "IDE", 2, true}, {"cli", "CLI", 3, true}]
  end

  defp insert_content(:tips, attrs),
    do: tip_fixture(user_fixture(), attrs)

  defp insert_content(:reviews, attrs),
    do: review_fixture(tip_fixture(), attrs)

  defp schema_fixture(Tip), do: tip_fixture()
  defp schema_fixture(Review), do: review_fixture()

  defp set_visibility(row, nil), do: row

  defp set_visibility(row, marker) do
    row |> change(%{marker => DateTime.utc_now(:second)}) |> Repo.update!()
  end

  defp duplicate_submission_attrs(%Tip{} = tip) do
    Map.take(tip, [:submission_key, :title, :body, :tag_id])
  end

  defp duplicate_submission_attrs(%Review{} = review) do
    # A separate parent isolates submission identity from one-per-tip uniqueness.
    review |> Map.take([:submission_key, :body]) |> Map.put(:tip_id, tip_fixture().id)
  end

  defp hot_reference(score, created_at) do
    sign =
      cond do
        score > 0 -> 1
        score < 0 -> -1
        true -> 0
      end

    sign * :math.log10(max(abs(score), 1)) +
      (DateTime.to_unix(created_at) - 1_134_028_003) / 345_600
  end

  defp wilson_reference(0, 0), do: 0.0

  defp wilson_reference(up, down) do
    n = up + down
    p = up / n
    z = 1.281551565545
    (p + z * z / (2 * n) - z * :math.sqrt((p * (1 - p) + z * z / (4 * n)) / n)) / (1 + z * z / n)
  end
end
