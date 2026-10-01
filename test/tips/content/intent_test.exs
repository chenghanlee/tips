defmodule Tips.Content.IntentTest do
  use ExUnit.Case, async: true

  import Tips.ContentContractFixtures

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

    # The zero-width space is not whitespace, so it is text.
    texts = [
      "Keep this",
      " Keep this",
      "Keep this\n",
      "  Keep this",
      "\tKeep this",
      " Keep this",
      "​",
      @composed,
      @decomposed
    ]

    for kind <- @kinds,
        field <- editable_fields(kind),
        left <- blanks ++ texts,
        right <- blanks ++ texts do
      saved = put_in(intent(kind).attrs[field], left)
      submitted = put_in(intent(kind).attrs[field], right)
      expected = if blank?(left) and blank?(right), do: :equivalent, else: verbatim(left, right)

      assert Content.compare_intents(kind, saved, submitted) == expected,
             "#{kind} #{field}: #{inspect(left)} against #{inspect(right)}"
    end

    # The same answers come from the real changesets for their text fields.
    for kind <- @kinds,
        field <- [:body, :model_other, :prompt, :output],
        left <- blanks ++ texts,
        right <- blanks ++ texts do
      saved = put_in(intent(kind).attrs[field], left)
      submitted = put_in(intent(kind).attrs[field], right)
      equal? = cast(kind, saved.attrs) == cast(kind, submitted.attrs)

      assert Content.compare_intents(kind, saved, submitted) == :equivalent == equal?,
             "#{kind} #{field}: #{inspect(left)} against #{inspect(right)}"
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

      for {name, partial} <- incomplete, other <- [complete, different, partial] do
        assert compare_both(kind, partial, other) == :unknown, "#{kind}: #{name}"
      end

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

  test "incomplete original base cannot enable conflict shortcut" do
    for kind <- @kinds, field <- editable_fields(kind) do
      latest = intent(kind, @media)
      original = update_in(latest.attrs, &Map.delete(&1, field))

      # Every supplied value agrees with the latest base; the gap still decides.
      assert Map.take(latest.attrs, Map.keys(original.attrs)) == original.attrs
      assert Content.compare_intents(kind, original, latest) == :unknown, "#{kind} #{field}"
    end

    for kind <- @kinds do
      latest = intent(kind, @media)

      for original <- [nil, Map.delete(latest, :uploads), %{latest | uploads: nil}] do
        assert Content.compare_intents(kind, original, latest) == :unknown
      end

      assert Content.compare_intents(kind, latest, latest) == :equivalent
    end
  end

  defp intent(kind, uploads \\ []), do: %{attrs: attrs(kind), uploads: uploads}

  defp compare_both(kind, left, right) do
    result = Content.compare_intents(kind, left, right)
    assert Content.compare_intents(kind, right, left) == result
    result
  end

  defp compare_media(saved, submitted),
    do: compare_both(:tip, intent(:tip, saved), intent(:tip, submitted))

  defp blank?(value), do: value == nil or String.trim(value) == ""

  defp verbatim(same, same), do: :equivalent
  defp verbatim(_left, _right), do: :different

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
end
