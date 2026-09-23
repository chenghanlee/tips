defmodule Tips.ContentContractFixtures do
  @moduledoc """
  Shared scenarios for the publication and edit contract in `Tips.Content`.

  Editor (#71), comparator (#72), publication (#73), edit (#74) and media
  claim (#65) tests reuse these inputs and expected outcomes. They are data,
  not an implementation: expected comparisons state the contract, and the
  comparator that #72 builds must reproduce them.
  """

  alias Tips.Content.Media.Asset
  alias Tips.Content.{Review, Tip}

  @tip_fields [:title, :body, :tag_id, :model_id, :model_other, :environment_id, :prompt, :output]
  @review_fields [:body, :model_id, :model_other, :environment_id, :prompt, :output]

  @doc "The author-editable fields of a kind, in declaration order."
  def editable_fields(:tip), do: @tip_fields
  def editable_fields(:review), do: @review_fields

  @doc "Complete tip attrs: every editable field present, `nil` for explicit blanks."
  def tip_attrs(overrides \\ %{}) do
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

  @doc "Complete review attrs. Reviews have no title or tag."
  def review_attrs(overrides \\ %{}) do
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

  @doc """
  The receipt a publication returns for a stored row. Receipts carry identity
  and current state, never content values.
  """
  def publication_receipt(%module{} = row, outcome) when module in [Tip, Review] do
    row
    |> identity()
    |> Map.merge(%{outcome: outcome, submission_key: row.submission_key})
  end

  @doc "The receipt a confirmed edit returns for the committed row."
  def edit_receipt(%module{} = row, outcome) when module in [Tip, Review] do
    row
    |> identity()
    |> Map.merge(%{outcome: outcome, edit_version: row.edit_version})
  end

  defp identity(%Tip{id: id} = row),
    do: %{kind: :tip, id: id, tip_id: id, state: content_state(row)}

  defp identity(%Review{id: id, tip_id: tip_id} = row),
    do: %{kind: :review, id: id, tip_id: tip_id, state: content_state(row)}

  defp content_state(%{deleted_at: %DateTime{}}), do: :deleted
  defp content_state(%{dead_at: %DateTime{}}), do: :hidden
  defp content_state(_row), do: :live

  @doc "The sorted field names of a map type declared in `module`."
  def declared_keys(module, type) do
    {:type, _line, :map, fields} = declared_type(module, type)
    fields |> Enum.map(fn {:type, _, _field, [{:atom, _, key}, _value]} -> key end) |> Enum.sort()
  end

  @doc "The atoms, or tuple tags, of a union type declared in `module`."
  def declared_tags(module, type) do
    {:type, _line, :union, members} = declared_type(module, type)

    Enum.map(members, fn
      {:atom, _, atom} -> atom
      {:type, _, :tuple, [{:atom, _, tag} | _]} -> tag
    end)
  end

  defp declared_type(module, type) do
    {:ok, types} = Code.Typespec.fetch_types(module)

    Enum.find_value(types, fn
      {:type, {^type, ast, []}} -> ast
      _other -> nil
    end)
  end

  @doc "Attrs of a kind."
  def attrs(:tip), do: tip_attrs()
  def attrs(:review), do: review_attrs()

  @doc "A saved attachment that an edit keeps, with its current description."
  def retained(%Asset{id: id, description: description}), do: {:retained, id, description}

  @doc "A staged Tips video upload selected for this save."
  def staged_video(%Asset{id: id, kind: :video}), do: {:staged_video, id}

  @doc "A new image/GIF held by the page for this attempt only."
  def image_file(slot, path, filename, description \\ nil),
    do: {:image_file, slot, %{path: path, filename: filename}, description}

  @doc "A restored image slot whose file must be reselected."
  def missing_image(slot), do: {:missing_image, slot}

  @doc "One of each attachment variant, in draft order."
  def every_attachment(%Asset{} = retained, %Asset{} = video, path) do
    [
      retained(retained),
      staged_video(video),
      image_file("slot-image", path, "diagram.png", "Request and response"),
      missing_image("slot-restored")
    ]
  end

  @doc """
  The complete immutable base `get_edit_form/3` returns for a saved row and its
  current attached media: every editable field and the whole ordered selection.
  """
  def edit_base(%module{} = row, assets) when module in [Tip, Review] do
    kind = if module == Tip, do: :tip, else: :review

    %{
      attrs: Map.take(row, editable_fields(kind)),
      uploads:
        assets
        |> Enum.reject(& &1.cleanup_at)
        |> Enum.sort_by(& &1.position)
        |> Enum.map(&retained/1)
    }
  end

  @doc """
  Comparison scenarios for the one Content comparator (#72).

  `saved` is the normalized stored intent (or edit base); `submitted` is what
  the page sends, or `nil` for an identity-only lookup. Text rules follow the
  current changesets: a blank or whitespace-only value is an explicit blank
  (`nil`), and every other value is kept verbatim, including surrounding
  whitespace and the Unicode normalization form. Scenarios tagged
  `changeset: true` differ only in text fields and are checked against the
  real changesets.
  """
  def comparison_scenarios do
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

  @doc """
  Transaction participants each operation must commit together. Same-key
  retries and no-op edits commit none of them. See "Transaction participants"
  in `Tips.Content`.
  """
  def effect_matrix do
    %{
      new_tip: [:content, :search_text, :self_vote, :media_claims],
      new_review: [:content, :search_text, :self_vote, :media_claims, :review_notification],
      same_key_retry: [],
      actual_edit: [:content_version, :search_text, :media_changes, :media_cleanup_jobs],
      noop_edit: []
    }
  end
end
