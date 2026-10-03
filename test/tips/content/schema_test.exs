defmodule Tips.Content.SchemaTest do
  use Tips.DataCase, async: true

  alias Tips.Content.{Environment, Model, Review, Tag, Tip, Vocabulary}

  import Tips.ContentFixtures
  import Tips.AccountsFixtures

  describe "submission identity and one undeleted review" do
    for table <- [:tips, :reviews] do
      test "#{table} allows the same submission key for a different author" do
        original = insert_content(unquote(table), %{})
        other = insert_content(unquote(table), %{submission_key: original.submission_key})
        refute other.user_id == original.user_id
      end
    end

    test "reviews_one_per_user includes moderator-hidden reviews" do
      review = review_fixture()

      set_visibility(review, :dead_at)

      assert_raise Ecto.ConstraintError, ~r/reviews_one_per_user/, fn ->
        review_fixture(Repo.get!(Tip, review.tip_id), %{user_id: review.user_id})
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
      for {zone, created_at, up, down} <- [
            {"UTC", ~U[2005-12-08 07:46:43Z], 0, 0},
            {"UTC", ~U[2026-09-21 12:00:00Z], 10, 2},
            {"Asia/Taipei", ~U[2026-09-21 12:00:00Z], 0, 5}
          ] do
        Repo.query!("SET LOCAL TIME ZONE '#{zone}'")

        tip =
          tip_fixture(user_fixture(), %{up_count: up, down_count: down, created_at: created_at})

        assert tip.score == up - down
        assert_in_delta tip.hot_score, hot_reference(up - down, created_at), 1.0e-9
        assert Repo.reload!(tip).created_at == created_at
      end
    end

    test "generated review scores match Wilson reference and refresh after counter updates" do
      for {up, down} <- [{0, 0}, {1, 0}, {10, 2}] do
        review = review_fixture(tip_fixture(), %{up_count: up, down_count: down})
        assert review.score == up - down
        assert_in_delta review.best_score, wilson_reference(up, down), 1.0e-9
        updated = review |> change(up_count: up + 1) |> Repo.update!()
        assert updated.score == up + 1 - down
        assert_in_delta updated.best_score, wilson_reference(up + 1, down), 1.0e-9
      end
    end
  end

  describe "visibility and indexes" do
    for table <- [:tips, :reviews] do
      test "live_#{table} excludes author-deleted and moderator-hidden rows" do
        live = insert_content(unquote(table), %{})
        insert_content(unquote(table), %{deleted_at: DateTime.utc_now(:second)})
        insert_content(unquote(table), %{dead_at: DateTime.utc_now(:second)})

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
      extra_values = if schema == Tip and field == :title, do: ["e\u0301x"], else: []

      test "#{inspect(schema)} validates #{field} in code points" do
        schema = unquote(schema)
        field = unquote(field)
        row = schema_fixture(schema)
        # Combining marks make each grapheme two PostgreSQL characters.
        too_long = String.duplicate("e\u0301", div(unquote(max), 2) + 1)
        assert %{^field => [_ | _]} = row |> schema.changeset(%{field => too_long}) |> errors_on()

        values = [String.duplicate("x", unquote(min)), String.duplicate("x", unquote(max))]
        values = unquote(extra_values) ++ values

        for value <- values do
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

        new_key = Ecto.UUID.generate()

        for changeset <- [
              schema.changeset(saved, %{submission_key: new_key}),
              change(saved, submission_key: new_key)
            ] do
          assert_raise ArgumentError, ~r/writable/, fn -> Repo.update(changeset) end
        end

        assert Repo.reload!(saved).submission_key == row.submission_key

        assert {:ok, retried} =
                 saved
                 |> schema.changeset(%{
                   submission_key: saved.submission_key,
                   body: "Updated body"
                 })
                 |> Repo.update()

        assert retried.submission_key == row.submission_key
        assert retried.body == "Updated body"

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

    test "a saved review cannot move to another tip through any update changeset" do
      review = review_fixture()
      other_tip = tip_fixture()

      for changeset <- [
            Review.changeset(review, %{tip_id: other_tip.id}),
            change(review, tip_id: other_tip.id)
          ] do
        assert_raise ArgumentError, ~r/writable/, fn -> Repo.update(changeset) end
      end

      assert Repo.reload!(review).tip_id == review.tip_id

      assert {:ok, retried} =
               review
               |> Review.changeset(%{tip_id: review.tip_id, body: "Updated review"})
               |> Repo.update()

      assert retried.tip_id == review.tip_id
      assert retried.body == "Updated review"
    end

    for {schema, fields} <- [
          {Tip, [:title, :body, :model_other, :prompt, :output]},
          {Review, [:body, :model_other, :prompt, :output]}
        ] do
      test "#{inspect(schema)} returns field errors for null bytes without stripping input" do
        schema = unquote(schema)
        row = schema_fixture(schema)

        for field <- unquote(fields) do
          value = "abc\0def"
          assert {:error, changeset} = row |> schema.changeset(%{field => value}) |> Repo.update()
          assert %{^field => ["cannot contain a null byte"]} = errors_on(changeset)
          assert get_change(changeset, field) == value
          assert Repo.reload!(row) == row
        end
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

    assert %{label: "Other technique", sort_order: 9, active: true} = Repo.get!(Tag, "other")

    Vocabulary.seed_synthetic!()
    Repo.update_all(Model, set: [label: "Changed", sort_order: 99, active: false])
    Repo.update_all(Environment, set: [label: "Changed", sort_order: 99, active: false])
    Vocabulary.seed_synthetic!()

    assert Repo.aggregate(Model, :count) == 3
    assert Repo.aggregate(Environment, :count) == 3
    assert %{label: "Claude", sort_order: 1, active: true} = Repo.get!(Model, "claude")
    assert %{label: "CLI", sort_order: 3, active: true} = Repo.get!(Environment, "cli")
  end

  defp insert_content(:tips, attrs),
    do: tip_fixture(user_fixture(), attrs)

  defp insert_content(:reviews, attrs),
    do: review_fixture(tip_fixture(), attrs)

  defp schema_fixture(Tip), do: tip_fixture()
  defp schema_fixture(Review), do: review_fixture()

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
