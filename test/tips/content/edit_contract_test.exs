defmodule Tips.Content.EditContractTest.Consumer do
  @moduledoc """
  Representative editor callers written only against the declared edit types in
  `Tips.Content`. They compile with this test and call no Content operation.
  """

  alias Tips.Content

  @doc "What the editor keeps from `get_edit_form/3`: its original version and complete base."
  @spec open(Content.edit_form()) :: %{
          expected_version: pos_integer(),
          base: Content.intent(),
          can_save: boolean()
        }
  def open(%{edit_version: version, base: %{attrs: _, uploads: _} = base, capabilities: caps}),
    do: %{expected_version: version, base: base, can_save: caps.edit}

  @doc "What the editor does after `edit_tip/5` or `edit_review/5`."
  @spec after_edit({:ok, Content.edit_receipt()} | {:error, Content.edit_error()}) ::
          {:saved, pos_integer()} | {:preserve, atom() | tuple()}
  def after_edit({:ok, %{outcome: outcome, edit_version: version}})
      when outcome in [:updated, :noop],
      do: {:saved, version}

  def after_edit({:error, :conflict}), do: {:preserve, :conflict}
  def after_edit({:error, :outcome_unknown}), do: {:preserve, :reload_saved_state}
  def after_edit({:error, {:upload_failed, refs}}), do: {:preserve, {:fix_attachments, refs}}
  def after_edit({:error, {:upload_pending, ids}}), do: {:preserve, {:wait_for_videos, ids}}

  def after_edit({:error, %Ecto.Changeset{errors: errors}}) do
    refs =
      for {:uploads, {_message, meta}} <- errors, ref = meta[:slot] || meta[:media_id], do: ref

    {:preserve, {:show_errors, refs}}
  end

  def after_edit({:error, reason})
      when reason in [:unauthenticated, :unconfirmed, :forbidden, :not_found],
      do: {:preserve, reason}

  @doc "Editor pages live under `/editor`, apart from every reader path."
  @spec editor_path(
          :new_tip
          | {:new_review, pos_integer()}
          | {:edit, Content.kind(), pos_integer()}
        ) ::
          String.t()
  def editor_path(:new_tip), do: "/editor/tips/new"
  def editor_path({:new_review, tip_id}), do: "/editor/tips/#{tip_id}/reviews/new"
  def editor_path({:edit, :tip, id}), do: "/editor/tips/#{id}/edit"
  def editor_path({:edit, :review, id}), do: "/editor/reviews/#{id}/edit"

  @doc """
  Conflict choices after comparing the editor's original base with the latest
  authorized base. Only an equivalent complete base offers Save at current
  version; it still goes through the ordinary version guard.
  """
  @spec conflict_choices(Content.comparison()) :: [atom()]
  def conflict_choices(:equivalent), do: [:save_at_current_version, :load_latest, :discard]
  def conflict_choices(result) when result in [:different, :unknown], do: [:load_latest, :discard]
end

defmodule Tips.Content.EditContractTest do
  use Tips.DataCase, async: true

  import Ecto.Changeset, only: [optimistic_lock: 2]

  alias Tips.Accounts.Scope
  alias Tips.Content
  alias Tips.Content.EditContractTest.Consumer
  alias Tips.Content.Media.{Asset, Target}
  alias Tips.Content.{Projection, Review, Tip}

  import Tips.AccountsFixtures
  import Tips.ContentContractFixtures
  import Tips.ContentFixtures
  import Tips.MediaFixtures
  import Tips.VisibilityFixtures

  test "declared edit shapes" do
    assert declared_tags(Content, :edit_outcome) == [:updated, :noop]

    assert declared_keys(Content, :edit_form) ==
             Enum.sort([:kind, :id, :tip_id, :edit_version, :state, :base, :media, :capabilities])

    assert declared_keys(Content, :edit_receipt) ==
             Enum.sort([:outcome, :kind, :id, :tip_id, :edit_version, :state])
  end

  test "complete base includes blanks descriptions and ordered media" do
    author = user_fixture()
    scope = Scope.for_user(author)
    tip = tip_fixture(author, %{model_other: "Local model", prompt: "  indented\n"})
    removed = cleanup_media_fixture(tip)
    image = image_fixture(tip, %{position: 1, description: "After the change"})
    video = attached_video_fixture(tip, %{position: 0})

    form = edit_form(scope, tip, [image, removed, video])

    assert Map.keys(form) |> Enum.sort() == declared_keys(Content, :edit_form)
    assert %{attrs: attrs, uploads: uploads} = form.base
    assert Map.keys(attrs) |> Enum.sort() == declared_keys(Content, :tip_attrs)

    assert %{model_id: nil, environment_id: nil, output: nil, prompt: "  indented\n"} = attrs
    assert uploads == [{:retained, video.id, nil}, {:retained, image.id, "After the change"}]
    assert [%{kind: :video, id: video_id}, %{kind: :image, id: image_id}] = form.media
    assert {video_id, image_id} == {video.id, image.id}

    assert Consumer.open(form) == %{expected_version: 1, base: form.base, can_save: true}

    review = review_fixture(tip)
    base = edit_base(review, [])
    assert Map.keys(base.attrs) |> Enum.sort() == declared_keys(Content, :review_attrs)
    assert base.uploads == []
  end

  test "current-version no-op preserves version" do
    tip = tip_fixture(user_fixture(), %{prompt: "  indented\n"})
    base = edit_base(tip, [])

    # Equal fields cast to no changes: there is nothing to write, so the
    # version, dates, search, media and notifications stay untouched.
    assert %{changes: changes} = Tip.changeset(tip, base.attrs)
    assert changes == %{}
    assert effect_matrix().noop_edit == []

    noop = edit_receipt(tip, :noop)
    assert Map.keys(noop) |> Enum.sort() == declared_keys(Content, :edit_receipt)
    assert Consumer.after_edit({:ok, noop}) == {:saved, 1}

    # An actual change advances the one version once.
    assert {:ok, edited} = guarded_edit(tip, 1, %{base.attrs | body: tip.body <> " More."})
    assert %{edit_version: 2} = edited
    assert Consumer.after_edit({:ok, edit_receipt(edited, :updated)}) == {:saved, 2}
  end

  test "stale version remains conflict even with equal editable fields" do
    tip = tip_fixture()
    changed = %{edit_base(tip, []).attrs | body: tip.body <> " Newer."}
    assert {:ok, current} = guarded_edit(tip, 1, changed)

    # The editor still holds version 1 and proposes exactly the current values.
    same = edit_base(current, []).attrs

    # Pitfall for #74: Ecto skips an update without changes, so the optimistic
    # lock alone accepts this stale no-op. Check the expected version against
    # the locked row before accepting a no-op.
    assert {:ok, %{edit_version: 1}} = guarded_edit(current, 1, same)
    assert Repo.reload!(current).edit_version == 2

    # Forcing the guarded write reports the stale version even with equal fields.
    assert {:error, stale} = guarded_edit(current, 1, same, force: true)
    assert %{edit_version: ["is stale"]} = errors_on(stale)
    assert Repo.reload!(current).edit_version == 2

    assert Consumer.after_edit({:error, :conflict}) == {:preserve, :conflict}
    assert Consumer.after_edit({:error, :outcome_unknown}) == {:preserve, :reload_saved_state}
  end

  test "an incomplete edit is rejected, never saved as a partial edit" do
    tip = tip_fixture(user_fixture(), %{prompt: "saved prompt"})
    changed = %{edit_base(tip, []).attrs | body: tip.body <> " More."}

    # Cast ignores an absent key: the changeset would keep the saved prompt
    # and still advance the version. Completeness is checked first.
    changeset = Tip.changeset(tip, Map.delete(changed, :prompt))
    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :prompt) == "saved prompt"

    for %{operation: :edit, kind: kind, errors: errors} = scenario <-
          incomplete_write_scenarios() do
      row = if kind == :tip, do: tip, else: review_fixture(tip)
      schema = row.__struct__

      rejected =
        Enum.reduce(errors, schema.changeset(row, %{}), fn {field, {message, meta}}, cs ->
          Ecto.Changeset.add_error(cs, field, message, meta)
        end)

      assert Map.take(errors_on(rejected), Keyword.keys(errors)) != %{}, scenario.name
      refs = for {:uploads, {_, meta}} <- errors, ref = meta[:slot] || meta[:media_id], do: ref
      assert Consumer.after_edit({:error, rejected}) == {:preserve, {:show_errors, refs}}
    end
  end

  test "editor paths never collide with a reader slug" do
    tip = tip_fixture(user_fixture(), %{title: "Edit"})

    assert Tip.changeset(%Tip{submission_key: tip.submission_key}, %{tip_attrs() | title: "Edit"}).valid?

    assert %{slug: "edit"} = Projection.metadata(nil, tip)

    reader_path = "/tips/#{tip.id}/edit"

    editor_paths =
      Enum.map(
        [:new_tip, {:new_review, tip.id}, {:edit, :tip, tip.id}, {:edit, :review, 7}],
        &Consumer.editor_path/1
      )

    refute reader_path in editor_paths
    assert Enum.all?(editor_paths, &String.starts_with?(&1, "/editor/"))
  end

  test "incomplete base disables safe conflict recovery" do
    scenarios = Map.new(comparison_scenarios(), &{&1.name, &1})
    assert %{expected: :unknown, saved: %{attrs: incomplete}} = scenarios["incomplete base"]
    refute Map.keys(incomplete) |> Enum.sort() == declared_keys(Content, :review_attrs)

    assert Consumer.conflict_choices(scenarios["incomplete base"].expected) ==
             [:load_latest, :discard]

    assert :save_at_current_version in Consumer.conflict_choices(:equivalent)
  end

  test "text comparison scenarios agree with the changesets" do
    for %{changeset: true, kind: kind, saved: saved, submitted: submitted} = scenario <-
          comparison_scenarios() do
      equal? = cast(kind, saved.attrs) == cast(kind, submitted.attrs)
      assert equal? == (scenario.expected == :equivalent), scenario.name
    end

    assert Enum.all?(
             comparison_scenarios(),
             &(&1.expected in declared_tags(Content, :comparison))
           )
  end

  test "edits commit their changes without replaying publication effects" do
    effects = effect_matrix()

    assert effects.noop_edit == []
    refute :self_vote in effects.actual_edit
    refute :review_notification in effects.actual_edit
    assert Enum.all?(Map.values(effects), &(&1 -- declared_tags(Content, :effect) == []))
  end

  test "exact-item handoff lets an edit claim the new-publication video" do
    author = user_fixture()
    tip = tip_fixture(author)
    review = review_fixture(tip, %{user_id: author.id})

    for {content, target} <- [
          {tip, {:new_tip, tip.submission_key}},
          {review, {:new_review, review.tip_id, review.submission_key}}
        ] do
      video = staged_video_fixture(author, %{target: target})

      # The stored target is never rewritten. The claim resolves immutable
      # facts: same author, same kind, same key and, for a review, same parent.
      assert %Asset{target: ^target, user_id: user_id} = Repo.reload!(video)
      assert user_id == content.user_id
      assert {:ok, ^target} = Target.cast(target)
    end

    # A same-key video staged under another parent is not this review's item.
    other_tip = tip_fixture(author)

    moved =
      staged_video_fixture(author, %{target: {:new_review, other_tip.id, review.submission_key}})

    assert {:new_review, parent_id, _key} = Repo.reload!(moved).target
    refute parent_id == review.tip_id
  end

  defp edit_form(scope, %Tip{} = tip, assets) do
    detail =
      Projection.tip(scope, tip, %{
        author: scope.user,
        labels: labels(),
        viewer_vote: nil,
        media: assets,
        own_review: nil,
        latest_review_at: nil,
        has_earlier_reviews: false
      })

    %{
      kind: :tip,
      id: tip.id,
      tip_id: tip.id,
      edit_version: tip.edit_version,
      state: :live,
      base: edit_base(tip, assets),
      media: detail.media,
      capabilities: Map.take(detail.capabilities, [:vote, :edit, :delete, :report])
    }
  end

  # The version guard the design prescribes, built on the editor's expected
  # version. #74 owns the operation; this characterizes the mechanism.
  defp guarded_edit(row, expected_version, attrs, opts \\ []) do
    %{row | edit_version: expected_version}
    |> Tip.changeset(attrs)
    |> optimistic_lock(:edit_version)
    |> Repo.update([stale_error_field: :edit_version] ++ opts)
  end

  # Characterizes the existing changeset casting only; #72 owns the comparator.
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
