defmodule Tips.Content.IntentTest do
  use ExUnit.Case, async: true

  alias Tips.Content
  alias Tips.Content.{Review, Tip}

  doctest Tips.Content, only: [compare_intents: 3]

  @kinds [:tip, :review]
  @media [{:retained, 11, "Before"}, {:retained, 12, nil}]

  # Composed and decomposed "é": the same text to a reader, different bytes.
  @composed "café"
  @decomposed "café"

  test "shared comparison scenarios satisfy the Content contract" do
    for %{kind: kind, saved: saved, submitted: submitted, expected: expected} = scenario <-
          comparison_scenarios() do
      assert Content.compare_intents(kind, saved, submitted) == expected, scenario.name
      assert Content.compare_intents(kind, submitted, saved) == expected, scenario.name
    end
  end

  test "each editable field participates for its content kind" do
    for kind <- @kinds, field <- editable_fields(kind) do
      base = intent(kind)
      changed = put_in(base.attrs[field], "changed-#{field}")
      omitted = update_in(base.attrs, &Map.delete(&1, field))

      assert compare_both(kind, base, changed) == :different, "#{kind} #{field} changed"
      assert compare_both(kind, base, omitted) == :unknown, "#{kind} #{field} omitted"
    end

    # A tip-only field is not review intent.
    review = intent(:review)
    titled = put_in(review.attrs[:title], "Not a review field")
    assert compare_both(:review, review, titled) == :equivalent
  end

  test "explicit blanks follow schema casting and nonblank text remains verbatim" do
    blanks = [nil, "", " ", " \t\r\n", " ", " 　"]

    examples = [
      {nil, "", :equivalent},
      {nil, " ", :equivalent},
      {"Keep this", "Keep this", :equivalent},
      {"Keep this", " Keep this", :different},
      {"Keep this", "Keep this\n", :different},
      {"Keep this", "\tKeep this", :different},
      {"Keep this", " Keep this", :different},
      {nil, "​", :different},
      {@composed, @decomposed, :different}
    ]

    for {left, right, expected} <- examples do
      saved = put_in(intent(:tip).attrs.prompt, left)
      submitted = put_in(intent(:tip).attrs.prompt, right)
      assert compare_both(:tip, saved, submitted) == expected
    end

    # The shared normalizer must continue to agree with real Ecto casting.
    pairs =
      Enum.map(blanks, &{nil, &1}) ++
        [{"Keep this", "Keep this"}, {"Keep this", " Keep this"}]

    for kind <- @kinds, {left, right} <- pairs do
      saved = put_in(intent(kind).attrs.prompt, left)
      submitted = put_in(intent(kind).attrs.prompt, right)
      equal? = cast(kind, saved.attrs) == cast(kind, submitted.attrs)
      assert compare_both(kind, saved, submitted) == :equivalent == equal?
    end
  end

  test "ordered media compares identity membership order and descriptions" do
    assert compare_media(@media, @media) == :equivalent

    # Membership and order.
    assert compare_media(@media, @media ++ [{:retained, 13, nil}]) == :different
    assert compare_media(@media, [{:retained, 11, "Before"}]) == :different
    assert compare_media(@media, [{:retained, 11, "Before"}, {:retained, 13, nil}]) == :different
    assert compare_media(@media, Enum.reverse(@media)) == :different
    assert compare_media(@media, []) == :different
    assert compare_media([], []) == :equivalent

    # A blank description is no description.
    for blank <- ["", "  ", "\n\t", " "] do
      assert compare_media(@media, [{:retained, 11, "Before"}, {:retained, 12, blank}]) ==
               :equivalent
    end

    # A nonblank description is verbatim.
    for changed <- ["After", " Before", "Before\n", "before"] do
      assert compare_media(@media, [{:retained, 11, changed}, {:retained, 12, nil}]) ==
               :different
    end

    assert compare_media([{:retained, 11, @composed}], [{:retained, 11, @composed}]) ==
             :equivalent

    assert compare_media([{:retained, 11, @composed}], [{:retained, 11, @decomposed}]) ==
             :different

    assert compare_media([{:retained, 11, nil}], [{:retained, 11, "Added"}]) == :different

    # A staged video is the same media as its attached id, with no description.
    assert compare_media([{:retained, 12, nil}], [{:staged_video, 12}]) == :equivalent
    assert compare_media([{:retained, 12, " "}], [{:staged_video, 12}]) == :equivalent
    assert compare_media([{:staged_video, 12}], [{:staged_video, 12}]) == :equivalent
    assert compare_media([{:retained, 12, nil}], [{:staged_video, 13}]) == :different
    assert compare_media([{:retained, 12, "Described"}], [{:staged_video, 12}]) == :different

    assert compare_media(@media, [{:staged_video, 12}, {:retained, 11, "Before"}]) ==
             :different
  end

  test "incomplete intent takes precedence over known differences" do
    image = image_file("slot-1", "/tmp/plug-1/upload", "before.png", "Before")

    for kind <- @kinds do
      complete = intent(kind, @media)
      different = put_in(complete.attrs.body, "A known difference")
      [field | _] = editable_fields(kind)

      incomplete = [
        {"nil intent", nil},
        {"empty intent", %{}},
        {"missing attrs", Map.delete(complete, :attrs)},
        {"nil attrs", %{complete | attrs: nil}},
        {"attrs not a map", %{complete | attrs: Map.to_list(complete.attrs)}},
        {"missing field", update_in(complete.attrs, &Map.delete(&1, field))},
        {"string-keyed attrs", %{complete | attrs: stringify(complete.attrs)}},
        {"field not text", put_in(complete.attrs[field], 7)},
        {"missing uploads", Map.delete(complete, :uploads)},
        {"nil uploads", %{complete | uploads: nil}},
        {"uploads not a list", %{complete | uploads: {:retained, 11, "Before"}}},
        {"improper uploads", %{complete | uploads: [{:retained, 11, "Before"} | :more]}},
        {"missing image slot", %{complete | uploads: [missing_image("slot-1")]}},
        {"new image file", %{complete | uploads: [image]}},
        {"missing slot among media", %{complete | uploads: @media ++ [missing_image("slot-3")]}},
        {"image file among media", %{complete | uploads: [image | @media]}},
        {"media id not positive", %{complete | uploads: [{:retained, 0, nil}]}},
        {"media id not an integer", %{complete | uploads: [{:retained, "11", "Before"}]}},
        {"staged id not positive", %{complete | uploads: [{:staged_video, -12}]}},
        {"description not text", %{complete | uploads: [{:retained, 11, :before}]}},
        {"unknown attachment", %{complete | uploads: [{:filename, "before.png"}]}}
      ]

      for {name, partial} <- incomplete do
        assert compare_both(kind, partial, different) == :unknown, "#{kind}: #{name}"
      end

      assert compare_both(kind, nil, nil) == :unknown

      # An explicit empty selection is known: it is a real difference.
      assert compare_both(kind, complete, %{complete | uploads: []}) == :different

      assert compare_both(kind, %{complete | uploads: []}, %{different | uploads: []}) ==
               :different
    end
  end

  test "noneditable metadata does not change comparison" do
    now = ~U[2026-10-01 12:00:00Z]

    metadata = %{
      id: 7,
      user_id: 3,
      tip_id: 5,
      submission_key: Ecto.UUID.generate(),
      edit_version: 4,
      up_count: 12,
      down_count: 3,
      review_count: 2,
      score: 9,
      hot_score: 1.5,
      best_score: 0.75,
      created_at: now,
      edited_at: now,
      deleted_at: now,
      dead_at: now
    }

    for kind <- @kinds do
      plain = intent(kind, @media)
      annotated = plain |> Map.merge(metadata) |> Map.update!(:attrs, &Map.merge(&1, metadata))

      assert compare_both(kind, plain, annotated) == :equivalent

      # Metadata neither hides an editable change nor completes a partial intent.
      changed = put_in(annotated.attrs.body, "An editable change")
      assert compare_both(kind, plain, changed) == :different

      partial = update_in(annotated.attrs, &Map.delete(&1, :prompt))
      assert compare_both(kind, plain, partial) == :unknown
    end

    # A stored row carries every editable field next to its metadata.
    saved = %Tip{id: 7, edit_version: 4, up_count: 12, created_at: now, dead_at: now}
    saved = struct!(saved, tip_attrs())

    assert compare_both(:tip, %{attrs: saved, uploads: []}, intent(:tip)) == :equivalent
  end

  defp intent(kind, uploads \\ []), do: %{attrs: attrs(kind), uploads: uploads}

  defp compare_both(kind, left, right) do
    result = Content.compare_intents(kind, left, right)
    assert Content.compare_intents(kind, right, left) == result
    result
  end

  defp compare_media(saved, submitted),
    do: compare_both(:tip, intent(:tip, saved), intent(:tip, submitted))

  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {Atom.to_string(key), value} end)

  # The existing changeset casting: blank to nil, everything else verbatim.
  defp cast(:tip, attrs), do: cast_fields(Tip, :tip, attrs)
  defp cast(:review, attrs), do: cast_fields(Review, :review, attrs)

  defp cast_fields(schema, kind, attrs) do
    schema
    |> struct()
    |> schema.changeset(attrs)
    |> Ecto.Changeset.apply_changes()
    |> Map.take(editable_fields(kind))
  end

  @tip_fields [:title, :body, :tag_id, :model_id, :model_other, :environment_id, :prompt, :output]
  @review_fields [:body, :model_id, :model_other, :environment_id, :prompt, :output]

  defp editable_fields(:tip), do: @tip_fields
  defp editable_fields(:review), do: @review_fields

  defp tip_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        title: "Name the output format",
        body: "Ask for JSON with a short schema and one example.",
        tag_id: "output-format",
        model_id: nil,
        model_other: nil,
        environment_id: nil,
        prompt: nil,
        output: nil
      },
      Map.new(overrides)
    )
  end

  defp review_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        body: "Worked for a JSON export in a synthetic test.",
        model_id: nil,
        model_other: nil,
        environment_id: nil,
        prompt: nil,
        output: nil
      },
      Map.new(overrides)
    )
  end

  defp attrs(:tip), do: tip_attrs()
  defp attrs(:review), do: review_attrs()

  defp image_file(slot, path, filename, description),
    do: {:image_file, slot, %{path: path, filename: filename}, description}

  defp missing_image(slot), do: {:missing_image, slot}

  defp comparison_scenarios do
    filled = %{
      model_other: "Local model",
      prompt: "  Keep this indentation\n",
      output: "line one\n  line two"
    }

    tip = tip_attrs(filled)
    review = review_attrs(filled)
    saved_media = [{:retained, 11, "Before"}, {:retained, 12, nil}]

    text_scenarios(:tip, tip) ++
      text_scenarios(:review, review) ++
      [
        %{
          name: "same fields and ordered media",
          kind: :tip,
          saved: %{attrs: tip, uploads: saved_media},
          submitted: %{attrs: tip, uploads: saved_media},
          expected: :equivalent
        },
        %{
          name: "blank image description equals no description",
          kind: :tip,
          saved: %{attrs: tip, uploads: saved_media},
          submitted: %{attrs: tip, uploads: [{:retained, 11, "Before"}, {:retained, 12, "  "}]},
          expected: :equivalent
        },
        %{
          name: "staged video id equals the same attached media id",
          kind: :tip,
          saved: %{attrs: tip, uploads: [{:retained, 12, nil}]},
          submitted: %{attrs: tip, uploads: [{:staged_video, 12}]},
          expected: :equivalent
        },
        %{
          name: "explicit empty selections",
          kind: :review,
          saved: %{attrs: review, uploads: []},
          submitted: %{attrs: review, uploads: []},
          expected: :equivalent
        },
        %{
          name: "reordered media",
          kind: :tip,
          saved: %{attrs: tip, uploads: saved_media},
          submitted: %{attrs: tip, uploads: Enum.reverse(saved_media)},
          expected: :different
        },
        %{
          name: "changed description",
          kind: :tip,
          saved: %{attrs: tip, uploads: saved_media},
          submitted: %{attrs: tip, uploads: [{:retained, 11, "After"}, {:retained, 12, nil}]},
          expected: :different
        },
        %{
          name: "removed attachment",
          kind: :tip,
          saved: %{attrs: tip, uploads: saved_media},
          submitted: %{attrs: tip, uploads: [{:retained, 11, "Before"}]},
          expected: :different
        },
        %{
          name: "empty selection against saved media",
          kind: :tip,
          saved: %{attrs: tip, uploads: saved_media},
          submitted: %{attrs: tip, uploads: []},
          expected: :different
        },
        %{
          name: "new image file against a saved image",
          kind: :tip,
          saved: %{attrs: tip, uploads: [{:retained, 11, "Before"}]},
          submitted: %{
            attrs: tip,
            uploads: [image_file("slot-1", "/tmp/plug-1/upload", "before.png", "Before")]
          },
          expected: :unknown
        },
        %{
          name: "missing recovered image slot",
          kind: :tip,
          saved: %{attrs: tip, uploads: [{:retained, 11, "Before"}]},
          submitted: %{attrs: tip, uploads: [missing_image("slot-1")]},
          expected: :unknown
        },
        %{
          name: "absent selection is not an empty selection",
          kind: :review,
          saved: %{attrs: review, uploads: []},
          submitted: %{attrs: review, uploads: nil},
          expected: :unknown
        },
        %{
          name: "missing field is not a blank",
          kind: :tip,
          saved: %{attrs: tip, uploads: []},
          submitted: %{attrs: Map.delete(tip, :prompt), uploads: []},
          expected: :unknown
        },
        %{
          name: "incomplete base",
          kind: :review,
          saved: %{attrs: Map.delete(review, :output), uploads: []},
          submitted: %{attrs: review, uploads: []},
          expected: :unknown
        },
        %{
          name: "identity-only lookup",
          kind: :tip,
          saved: %{attrs: tip, uploads: []},
          submitted: nil,
          expected: :unknown
        }
      ]
  end

  defp text_scenarios(kind, saved) do
    [
      {"identical text", %{}, :equivalent},
      {"whitespace-only prompt is a blank", %{prompt: nil}, %{prompt: "  \n "}, :equivalent},
      {"empty model text is a blank", %{model_other: nil}, %{model_other: ""}, :equivalent},
      {"filled blank field", %{environment_id: "ide"}, :different},
      {"cleared setup field", %{model_other: nil}, :different},
      {"verbatim prompt whitespace", %{prompt: "Keep this indentation"}, :different},
      {"verbatim output whitespace", %{output: "line one\nline two"}, :different},
      {"body trailing newline", %{body: saved.body <> "\n"}, :different},
      {"decomposed Unicode", %{body: saved.body <> " café"}, %{body: saved.body <> " café"},
       :different}
    ]
    |> Enum.map(fn
      {name, change, expected} ->
        {name, %{}, change, expected}

      scenario ->
        scenario
    end)
    |> Enum.map(fn {name, saved_change, submitted_change, expected} ->
      %{
        name: "#{kind}: #{name}",
        kind: kind,
        changeset: true,
        saved: %{attrs: Map.merge(saved, saved_change), uploads: []},
        submitted: %{attrs: Map.merge(saved, submitted_change), uploads: []},
        expected: expected
      }
    end)
  end
end
