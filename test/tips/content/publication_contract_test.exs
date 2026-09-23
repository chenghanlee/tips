defmodule Tips.Content.PublicationContractTest.Consumer do
  @moduledoc """
  Representative editor callers written only against the declared publication
  types in `Tips.Content`. They compile with this test and call no Content
  operation.
  """

  alias Tips.Content

  @type next_step ::
          {:clear_and_open, String.t()}
          | {:preserve, :offer_edit | :deleted_original | :retry_same_key | :keep_values_fixed}
          | {:preserve, {:fix_attachments, [Content.attachment_ref()]}}
          | {:preserve, {:wait_for_videos, [Content.media_id()]}}
          | {:preserve, {:show_errors, [Content.attachment_ref()]}}
          | {:preserve, :link_own_review | Content.publication_error()}

  @doc "What the editor does after `publish_tip/4` or `publish_review/5`."
  @spec after_publish(
          {:ok, Content.publication_receipt()} | {:error, Content.publication_error()},
          slug :: String.t()
        ) :: next_step()
  def after_publish({:ok, %{outcome: outcome} = receipt}, slug)
      when outcome in [:created, :existing_equivalent],
      do: {:clear_and_open, destination(receipt, slug)}

  def after_publish({:ok, %{outcome: outcome, state: :deleted}}, _slug)
      when outcome in [:existing_different, :existing_unknown],
      do: {:preserve, :deleted_original}

  def after_publish({:ok, %{outcome: outcome, state: state}}, _slug)
      when outcome in [:existing_different, :existing_unknown] and state in [:live, :hidden],
      do: {:preserve, :offer_edit}

  def after_publish({:error, :outcome_unknown}, _slug), do: {:preserve, :keep_values_fixed}
  def after_publish({:error, :already_reviewed}, _slug), do: {:preserve, :link_own_review}

  def after_publish({:error, {:upload_failed, refs}}, _slug),
    do: {:preserve, {:fix_attachments, refs}}

  def after_publish({:error, {:upload_pending, ids}}, _slug),
    do: {:preserve, {:wait_for_videos, ids}}

  def after_publish({:error, %Ecto.Changeset{errors: errors}}, _slug),
    do: {:preserve, {:show_errors, attachment_refs(errors)}}

  def after_publish({:error, reason}, _slug)
      when reason in [:unauthenticated, :unconfirmed, :forbidden, :not_found, :conflict],
      do: {:preserve, reason}

  @doc "What draft recovery does after `get_publication/4`."
  @spec after_lookup(
          {:ok, Content.publication_receipt() | nil} | {:error, Content.lookup_error()},
          slug :: String.t()
        ) :: next_step()
  def after_lookup({:ok, nil}, _slug), do: {:preserve, :retry_same_key}
  def after_lookup({:ok, receipt}, slug), do: after_publish({:ok, receipt}, slug)
  def after_lookup({:error, reason}, slug), do: after_publish({:error, reason}, slug)

  # Invalid or incomplete intent names the offending attachments in metadata.
  defp attachment_refs(errors) do
    for {:uploads, {_message, meta}} <- errors,
        ref = meta[:slot] || meta[:media_id],
        do: ref
  end

  # The tip slug comes from the current authorized projection, never the receipt.
  defp destination(%{kind: :tip, id: id}, slug), do: "/tips/#{id}/#{slug}"
  defp destination(%{kind: :review, id: id}, _slug), do: "/reviews/#{id}"
end

defmodule Tips.Content.PublicationContractTest do
  use Tips.DataCase, async: true

  alias Tips.Accounts.Scope
  alias Tips.Content
  alias Tips.Content.Media.Target
  alias Tips.Content.{Projection, Review, Tip, Visibility}
  alias Tips.Content.PublicationContractTest.Consumer

  import Tips.AccountsFixtures
  import Tips.ContentContractFixtures
  import Tips.ContentFixtures
  import Tips.MediaFixtures
  import Tips.VisibilityFixtures

  @content_fields [:title, :body, :tag_id, :model_id, :model_other, :environment_id, :prompt] ++
                    [:output, :media]

  describe "declarations" do
    test "future operations are reserved in documentation without runtime bodies" do
      Code.ensure_loaded!(Content)
      {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Content)

      for {name, signature} <- [
            publish_tip: "publish_tip(scope, submission_key, attrs, uploads)",
            publish_review: "publish_review(scope, tip_id, submission_key, attrs, uploads)",
            get_publication: "get_publication(scope, kind, submission_key, submitted_intent)",
            get_edit_form: "get_edit_form(scope, kind, id)",
            edit_tip: "edit_tip(scope, id, expected_version, attrs, uploads)",
            edit_review: "edit_review(scope, id, expected_version, attrs, uploads)"
          ] do
        arity = signature |> String.split(",") |> length()

        assert moduledoc =~ signature
        refute function_exported?(Content, name, arity), "#{name}/#{arity} must not be stubbed"
      end
    end

    test "declared vocabularies" do
      assert declared_tags(Content, :publication_outcome) ==
               [:created, :existing_equivalent, :existing_different, :existing_unknown]

      assert declared_tags(Content, :comparison) == [:equivalent, :different, :unknown]
      assert declared_tags(Content, :content_state) == [:live, :hidden, :deleted]

      assert declared_tags(Content, :attachment) ==
               [:retained, :staged_video, :image_file, :missing_image]

      assert declared_keys(Content, :intent) == [:attrs, :uploads]
      assert declared_keys(Content, :image_file) == [:filename, :path]

      assert declared_keys(Content, :publication_receipt) ==
               Enum.sort([:outcome, :kind, :id, :tip_id, :submission_key, :state])
    end

    test "declared editable fields match what the changesets cast" do
      assert declared_keys(Content, :tip_attrs) == Enum.sort(editable_fields(:tip))
      assert declared_keys(Content, :review_attrs) == Enum.sort(editable_fields(:review))

      assert cast_fields(Tip) -- [:submission_key] == Enum.sort(editable_fields(:tip))

      assert cast_fields(Review) -- [:submission_key, :tip_id] ==
               Enum.sort(editable_fields(:review))
    end
  end

  describe "acknowledgement" do
    test "created and equivalent receipts acknowledge only the submitted intent" do
      author = user_fixture()
      tip = tip_fixture(author)
      review = review_fixture(tip)
      slug = Projection.metadata(Scope.for_user(author), tip).slug

      for row <- [tip, review],
          outcome <- declared_tags(Content, :publication_outcome) do
        receipt = publication_receipt(row, outcome)
        assert Map.keys(receipt) |> Enum.sort() == declared_keys(Content, :publication_receipt)
        assert Map.take(receipt, @content_fields) == %{}

        case {Consumer.after_publish({:ok, receipt}, slug), row} do
          {{:clear_and_open, path}, %Tip{}} when outcome in [:created, :existing_equivalent] ->
            assert path == "/tips/#{tip.id}/#{slug}"

          {{:clear_and_open, path}, %Review{}} when outcome in [:created, :existing_equivalent] ->
            assert path == "/reviews/#{review.id}"

          {{:preserve, :offer_edit}, _row}
          when outcome in [:existing_different, :existing_unknown] ->
            :ok
        end
      end
    end

    test "same key with different intent preserves the proposal" do
      author = user_fixture()
      key = Ecto.UUID.generate()
      original = tip_attrs(%{prompt: "  Keep this indentation\n"})
      proposal = %{original | body: original.body <> " Then validate it."}

      assert {:ok, tip} = insert_tip(author, key, original)
      assert {:error, conflict} = insert_tip(author, key, proposal)
      assert %{submission_key: ["has already been taken"]} = errors_on(conflict)
      assert Repo.reload!(tip).body == original.body

      refute changeset_fields(:tip, original) == changeset_fields(:tip, proposal)

      assert Consumer.after_publish({:ok, publication_receipt(tip, :existing_different)}, "x") ==
               {:preserve, :offer_edit}

      assert Consumer.after_lookup({:ok, nil}, "x") == {:preserve, :retry_same_key}

      assert Consumer.after_lookup({:error, :outcome_unknown}, "x") ==
               {:preserve, :keep_values_fixed}
    end

    test "a same-key review resolves the key before reporting another-key review" do
      reviewer = user_fixture()
      tip = tip_fixture()
      key = Ecto.UUID.generate()

      assert {:ok, review} = insert_review(reviewer, tip, key, review_attrs())
      assert {:error, same_key} = insert_review(reviewer, tip, key, review_attrs())

      assert {:error, other_key} =
               insert_review(reviewer, tip, Ecto.UUID.generate(), review_attrs())

      # Either constraint may report the same-key conflict first, so Content
      # looks the key up after rollback before returning :already_reviewed.
      assert Map.take(errors_on(same_key), [:submission_key, :tip_id]) != %{}
      assert %{tip_id: ["has already been taken"]} = errors_on(other_key)

      # A key whose stored parent is another tip is not this publication.
      assert %{tip_id: tip_id} = review
      assert tip_id == tip.id

      assert Consumer.after_publish({:error, :already_reviewed}, "x") ==
               {:preserve, :link_own_review}

      assert Consumer.after_publish({:error, :conflict}, "x") == {:preserve, :conflict}
    end
  end

  describe "unknown equivalence" do
    @tag :tmp_dir
    test "missing file identity or recovered slot remains unknown", %{tmp_dir: tmp_dir} do
      scenarios = Map.new(comparison_scenarios(), &{&1.name, &1})

      for name <- [
            "new image file against a saved image",
            "missing recovered image slot",
            "absent selection is not an empty selection",
            "missing field is not a blank"
          ] do
        assert %{expected: :unknown} = scenarios[name]
      end

      assert %{expected: :equivalent, submitted: %{uploads: []}} =
               scenarios["explicit empty selections"]

      # Neither a matching filename nor the same temporary path proves the
      # saved bytes, so a page-owned file never makes a retry equivalent.
      path = Path.join(tmp_dir, "upload")
      File.write!(path, "png bytes")
      image = image_file("slot-1", path, "before.png", "Before")

      assert {:image_file, "slot-1", %{path: ^path, filename: "before.png"}, "Before"} = image
      assert Map.keys(elem(image, 2)) |> Enum.sort() == declared_keys(Content, :image_file)

      tip = tip_fixture()

      assert Consumer.after_publish({:ok, publication_receipt(tip, :existing_unknown)}, "x") ==
               {:preserve, :offer_edit}

      assert Consumer.after_publish({:error, {:upload_failed, ["slot-1"]}}, "x") ==
               {:preserve, {:fix_attachments, ["slot-1"]}}
    end

    test "identity-only and deleted originals cannot acknowledge values" do
      author = user_fixture()
      scope = Scope.for_user(author)
      tip = put_marker!(tip_fixture(author), :deleted)

      assert %{submitted: nil, expected: :unknown} =
               Enum.find(comparison_scenarios(), &(&1.name == "identity-only lookup"))

      assert Visibility.decision(scope, tip) == :deleted
      assert %{title: "Deleted tip", slug: "deleted-tip"} = Projection.metadata(scope, tip)

      receipt = publication_receipt(tip, :existing_unknown)
      assert %{state: :deleted, outcome: :existing_unknown} = receipt
      assert Map.take(receipt, @content_fields) == %{}
      assert Consumer.after_publish({:ok, receipt}, "x") == {:preserve, :deleted_original}
    end

    test "hidden originals require current author access" do
      author = user_fixture()
      tip = put_marker!(tip_fixture(author), :hidden)
      viewers = viewers(author)

      # Only a scope that may read the hidden row compares values; every other
      # scope gets unknown equivalence and no content.
      assert Visibility.decision(viewers[:author], tip) == :visible
      assert Visibility.decision(viewers[:banned_author], tip) == :visible
      assert Visibility.decision(viewers[:deleted_author], tip) == :removed

      assert %{title: "Removed tip"} = Projection.metadata(viewers[:deleted_author], tip)
      slug = Projection.metadata(viewers[:author], tip).slug

      assert Consumer.after_publish({:ok, publication_receipt(tip, :existing_equivalent)}, slug) ==
               {:clear_and_open, "/tips/#{tip.id}/#{slug}"}

      assert %{state: :hidden} = publication_receipt(tip, :existing_different)
    end
  end

  describe "explicit inputs" do
    @tag :tmp_dir
    test "both kinds take plain ids, files and values", %{tmp_dir: tmp_dir} do
      author = user_fixture()
      tip = tip_fixture(author)
      path = Path.join(tmp_dir, "upload")
      File.write!(path, "png bytes")
      retained = image_fixture(tip, %{description: "Before"})
      video = staged_video_fixture(author)

      assert Enum.map(every_attachment(retained, video, path), &elem(&1, 0)) ==
               declared_tags(Content, :attachment)

      # A new publication selects staged videos and new image files only.
      assert [{:staged_video, _}, {:image_file, "slot-image", %{path: ^path}, _}] =
               every_attachment(retained, video, path) |> Enum.slice(1, 2)

      for {kind, target} <- [
            tip: {:new_tip, Ecto.UUID.generate()},
            review: {:new_review, tip.id, Ecto.UUID.generate()}
          ] do
        attrs = attrs(kind)
        assert Map.keys(attrs) |> Enum.sort() == declared_keys(Content, :"#{kind}_attrs")
        assert {:ok, ^target} = Target.cast(target)
        assert changeset(kind, attrs, target).valid?
      end
    end

    test "an incomplete new write is rejected while its key still reconciles" do
      # Cast ignores an absent optional key, so a changeset alone would save
      # an incomplete tip with a silent blank.
      attrs = Map.delete(tip_attrs(%{prompt: "  indented\n"}), :prompt)
      assert changeset(:tip, attrs, {:new_tip, Ecto.UUID.generate()}).valid?

      for %{operation: :publish, kind: kind, errors: errors} = scenario <-
            incomplete_write_scenarios() do
        rejected = rejected_write(kind, errors)
        assert Map.take(errors_on(rejected), Keyword.keys(errors)) != %{}, scenario.name

        refs = for {:uploads, {_, meta}} <- errors, ref = meta[:slot] || meta[:media_id], do: ref

        assert Consumer.after_publish({:error, rejected}, "x") ==
                 {:preserve, {:show_errors, refs}}
      end

      # Under a committed key, the same incomplete intent reconciles first:
      # identity with unknown equivalence, never a validation error.
      tip = tip_fixture()
      scenarios = Map.new(comparison_scenarios(), &{&1.name, &1})

      for name <- ["missing field is not a blank", "absent selection is not an empty selection"] do
        assert %{expected: :unknown} = scenarios[name]
      end

      assert Consumer.after_publish({:ok, publication_receipt(tip, :existing_unknown)}, "x") ==
               {:preserve, :offer_edit}
    end

    test "gap for #73: unknown vocabulary raises instead of returning a changeset error" do
      attrs = tip_attrs(%{tag_id: "retired-tag"})

      assert_raise Ecto.ConstraintError, ~r/tips_tag_id_fkey/, fn ->
        insert_tip(user_fixture(), Ecto.UUID.generate(), attrs)
      end
    end
  end

  test "publication effects run only for a new insert" do
    effects = effect_matrix()

    assert effects.new_review -- effects.new_tip == [:review_notification]
    assert effects.same_key_retry == []
    assert Enum.all?(Map.values(effects), &(&1 -- declared_tags(Content, :effect) == []))
  end

  defp insert_tip(user, key, attrs) do
    %Tip{user_id: user.id}
    |> Tip.changeset(Map.put(attrs, :submission_key, key))
    |> Repo.insert()
  end

  defp insert_review(user, tip, key, attrs) do
    %Review{user_id: user.id}
    |> Review.changeset(Map.merge(attrs, %{submission_key: key, tip_id: tip.id}))
    |> Repo.insert()
  end

  defp changeset(:tip, attrs, {:new_tip, key}),
    do: Tip.changeset(%Tip{}, Map.put(attrs, :submission_key, key))

  defp changeset(:review, attrs, {:new_review, tip_id, key}),
    do: Review.changeset(%Review{}, Map.merge(attrs, %{submission_key: key, tip_id: tip_id}))

  # The changeset a write returns for incomplete intent, built from the
  # scenario's expected errors; #73 produces it.
  defp rejected_write(kind, errors) do
    Enum.reduce(errors, changeset(kind, attrs(kind), new_target(kind)), fn
      {field, {message, meta}}, changeset ->
        Ecto.Changeset.add_error(changeset, field, message, meta)
    end)
  end

  defp new_target(:tip), do: {:new_tip, Ecto.UUID.generate()}
  defp new_target(:review), do: {:new_review, 1, Ecto.UUID.generate()}

  # Characterizes the existing changeset casting only; #72 owns the comparator.
  defp changeset_fields(kind, attrs) do
    schema = if kind == :tip, do: Tip, else: Review

    schema
    |> struct()
    |> schema.changeset(attrs)
    |> Ecto.Changeset.apply_changes()
    |> Map.take(editable_fields(kind))
  end

  defp cast_fields(schema) do
    values = %{
      submission_key: Ecto.UUID.generate(),
      tip_id: 1,
      title: "abc",
      body: "abc",
      tag_id: "t",
      model_id: "m",
      model_other: "o",
      environment_id: "e",
      prompt: "p",
      output: "o"
    }

    schema
    |> struct()
    |> schema.changeset(values)
    |> Map.fetch!(:changes)
    |> Map.keys()
    |> Enum.sort()
  end
end
