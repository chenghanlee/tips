defmodule TipsWeb.EditorContractTest.Consumer do
  @moduledoc """
  Representative page and hook callers written only against the declared types
  in `TipsWeb.EditorContract` and `Tips.Content`. They compile with this test
  and call no Content operation; #75 and #78 implement storage and the page.
  """

  alias Tips.Content
  alias TipsWeb.EditorContract

  @doc "The Content intent a submission sends. Browser image metadata never proves bytes."
  @spec submission_intent(EditorContract.intent()) :: Content.intent()
  def submission_intent(%{attrs: attrs, uploads: nil}), do: %{attrs: attrs, uploads: nil}

  def submission_intent(%{attrs: attrs, uploads: uploads}),
    do: %{attrs: attrs, uploads: Enum.map(uploads, &attachment/1)}

  @spec attachment(EditorContract.media()) :: Content.attachment()
  defp attachment({:retained, _media_id, _description} = retained), do: retained
  defp attachment({:staged_video, _media_id} = video), do: video
  defp attachment({:missing_image, slot, _image}), do: {:missing_image, slot}

  @doc """
  The reply to `editor:restore` for the freshly mounted identity. The recovered
  identity is a guard, never authorization; `:restored` settles recovery only.
  """
  @spec restore(EditorContract.identity(), EditorContract.restore_request(), boolean()) ::
          EditorContract.restore_reply()
  def restore(current, %{identity: recovered, record: record}, pristine?),
    do: %{
      status: status(current, recovered, record, pristine?),
      storage: record.storage,
      draft: record.draft
    }

  @spec status(
          EditorContract.identity(),
          EditorContract.identity(),
          EditorContract.draft_record(),
          boolean()
        ) :: EditorContract.restore_status()
  defp status(current, recovered, record, pristine?) do
    cond do
      recovered != current or not readable?(current, record) -> :rejected
      pristine? -> :restored
      true -> :preserved
    end
  end

  # A form reads its own slot, or a handoff record whose target is this form.
  @spec readable?(EditorContract.identity(), EditorContract.draft_record()) :: boolean()
  defp readable?(%{account_id: account_id, target: target}, %{storage: storage} = record),
    do: storage.account_id == account_id and target in [storage.slot, record.target]

  @doc "Continue as edit: K keeps its slot and guard and becomes an edit of the exact item."
  @spec handoff(EditorContract.draft_record(), Content.edit_form()) :: EditorContract.handoff()
  def handoff(%{mode: :new, target: :new_tip} = k, %{kind: :tip} = form), do: hand_off(k, form)

  def handoff(
        %{mode: :new, target: {:new_review, tip_id}} = k,
        %{kind: :review, tip_id: tip_id} = form
      ),
      do: hand_off(k, form)

  @spec hand_off(EditorContract.draft_record(), Content.edit_form()) :: EditorContract.handoff()
  defp hand_off(k, %{kind: kind, id: id, base: base, edit_version: version}) do
    %{
      storage: k.storage,
      expected: k.draft,
      record: %{k | mode: :edit, target: {:edit, kind, id}, base: base, expected_version: version}
    }
  end

  @doc """
  The clear request after a submission. Only an acknowledgement of this exact
  submission asks the hook to clear it; everything else preserves the proposal.
  """
  @spec clear_request(
          EditorContract.draft_record(),
          {:ok, Content.publication_receipt() | Content.edit_receipt() | nil}
          | {:error, Content.lookup_error() | Content.publication_error() | Content.edit_error()}
        ) :: {:clear, EditorContract.clear_request()} | :preserve
  def clear_request(
        %{mode: :new, submission_key: key} = record,
        {:ok, %{outcome: outcome, submission_key: key} = receipt}
      )
      when outcome in [:created, :existing_equivalent] do
    if publishes?(record.target, receipt), do: clear(record, receipt), else: :preserve
  end

  def clear_request(
        %{mode: :edit, target: {:edit, kind, id}} = record,
        {:ok, %{outcome: outcome, kind: kind, id: id, edit_version: _version} = receipt}
      )
      when outcome in [:updated, :noop],
      do: clear(record, receipt)

  def clear_request(_record, _result), do: :preserve

  @spec publishes?(EditorContract.target(), Content.publication_receipt()) :: boolean()
  defp publishes?(:new_tip, %{kind: :tip}), do: true
  defp publishes?({:new_review, tip_id}, %{kind: :review, tip_id: tip_id}), do: true
  defp publishes?(_target, _receipt), do: false

  @spec clear(
          EditorContract.draft_record(),
          Content.publication_receipt() | Content.edit_receipt()
        ) ::
          {:clear, EditorContract.clear_request()}
  defp clear(record, receipt), do: {:clear, %{submitted: submitted(record), receipt: receipt}}

  @spec submitted(EditorContract.draft_record()) :: EditorContract.submitted_draft()
  defp submitted(%{storage: storage, draft: draft, target: target}),
    do: %{storage: storage, draft: draft, target: target}

  @doc """
  Whether the hook's revision-guarded clear removes the stored record. A clear
  request is an instruction: a newer revision, another draft or no record stays.
  """
  @spec clears?(EditorContract.draft_record() | nil, EditorContract.clear_request()) :: boolean()
  def clears?(nil, _request), do: false
  def clears?(stored, %{submitted: submitted}), do: guard(stored) == guard(submitted)

  # The browser CAS key: storage slot, draft UUID and revision together.
  @spec guard(EditorContract.draft_record() | EditorContract.submitted_draft()) ::
          {EditorContract.storage_identity(), EditorContract.draft_pair()}
  defp guard(%{storage: storage, draft: draft}), do: {storage, draft}

  @doc "The DOM id of the form and hook element, shared by every target of one kind."
  @spec dom_id(EditorContract.identity()) :: String.t()
  def dom_id(%{account_id: account_id, target: target}),
    do: "editor-#{account_id}-#{kind(target)}"

  @spec kind(EditorContract.target()) :: Content.kind()
  defp kind(:new_tip), do: :tip
  defp kind({:new_review, _tip_id}), do: :review
  defp kind({:edit, kind, _id}), do: kind

  @doc "The named Reselect slots a restored record renders, in selection order."
  @spec missing_images(EditorContract.draft_record()) ::
          [{Content.slot(), EditorContract.image_descriptor()}]
  def missing_images(%{intent: %{uploads: uploads}}),
    do: for({:missing_image, slot, image} <- uploads || [], do: {slot, image})
end

defmodule TipsWeb.EditorContractTest do
  use Tips.DataCase, async: true

  alias Tips.Content
  alias Tips.Content.{Review, Tip}
  alias TipsWeb.EditorContract
  alias TipsWeb.EditorContractTest.Consumer

  import Tips.AccountsFixtures
  import Tips.ContentContractFixtures
  import Tips.ContentFixtures
  import Tips.MediaFixtures
  import TipsWeb.EditorContractFixtures

  @js Path.expand("../../assets/js/editor_contract.js", __DIR__)

  # Elixir declaration and its JSON wire typedef in `assets/js/editor_contract.js`.
  @wire_types [
    identity: "EditorIdentity",
    storage_identity: "EditorStorageIdentity",
    draft_pair: "EditorDraftPair",
    intent: "EditorIntent",
    draft_record: "EditorRecord",
    restore_request: "EditorRestoreRequest",
    restore_reply: "EditorRestoreReply",
    handoff: "EditorHandoff",
    submitted_draft: "EditorSubmittedDraft",
    clear_request: "EditorClearRequest"
  ]

  # Every public declaration; unions are checked by their tags below.
  @public_types Keyword.keys(@wire_types) ++
                  [:target, :mode, :image_descriptor, :media, :restore_status]

  test "tip and review new edit recovered and handoff envelopes preserve all identities" do
    {:ok, types} = Code.Typespec.fetch_types(EditorContract)
    assert Enum.sort(for {:type, {name, _ast, []}} <- types, do: name) == Enum.sort(@public_types)

    for {type, typedef} <- @wire_types do
      assert js_keys(typedef) == Enum.map(declared_keys(EditorContract, type), &to_string/1),
             typedef
    end

    assert declared_tags(EditorContract, :target) == [:new_tip, :new_review, :edit]
    assert declared_tags(EditorContract, :mode) == [:new, :edit]

    author = user_fixture()
    tip = tip_fixture(author)
    review = review_fixture(tip, %{user_id: author.id})

    for {new_target, row} <- [{:new_tip, tip}, {{:new_review, tip.id}, review}] do
      key = row.submission_key
      edit_target = {:edit, kind(row), row.id}
      new = new_record(author.id, new_target, submission_key: key, revision: 2)
      edit = edit_record(author.id, edit_target, edit_base(row, []), row.edit_version)
      recovered = %{identity: identity(author.id, new_target), record: new}
      %{record: handed} = Consumer.handoff(new, form(row))

      for record <- [new, edit, handed] do
        assert Map.keys(record) |> Enum.sort() == declared_keys(EditorContract, :draft_record)
        assert wire_keys(record) == js_keys("EditorRecord")
      end

      # New: the draft id is the submission key, stored in the new-form slot.
      assert %{mode: :new, draft: %{draft_id: ^key}, submission_key: ^key} = new
      assert new.storage == %{account_id: author.id, slot: new_target}

      # Edit: a local draft id, no publication key, stored per published item.
      assert %{mode: :edit, submission_key: nil, storage: %{slot: ^edit_target}} = edit
      refute edit.draft.draft_id == key

      # Recovered is an entry condition around a stored record, not a mode.
      assert Map.keys(recovered) |> Enum.sort() == declared_keys(EditorContract, :restore_request)
      assert Consumer.restore(recovered.identity, recovered, true).status == :restored

      # Handoff: K keeps its slot, draft and key while its target becomes the item.
      assert %{mode: :edit, target: ^edit_target, submission_key: ^key} = handed
      assert handed.storage == new.storage
      assert handed.draft == new.draft
      refute handed.storage.slot == handed.target

      # The same revision under another draft id is another draft.
      other = %{new | draft: draft(Ecto.UUID.generate(), new.draft.revision)}

      assert {:clear, request} =
               Consumer.clear_request(new, {:ok, publication_receipt(row, :created)})

      assert Consumer.clears?(new, request)
      refute Consumer.clears?(other, request)
    end
  end

  test "explicit blanks and verbatim text survive browser payload examples" do
    for {kind, attrs, blanks, verbatim} <- [
          {:tip,
           tip_attrs(%{model_other: "", prompt: "  Keep this indentation\n", output: " \n "}),
           [:model_other, :output], [:prompt]},
          {:review,
           review_attrs(%{model_other: "   ", prompt: nil, output: "line one\n  line two"}),
           [:model_other, :prompt], [:output]}
        ] do
      target = if kind == :tip, do: :new_tip, else: {:new_review, 7}
      record = new_record(9, target, attrs: attrs)
      payload = record |> wire() |> JSON.encode!() |> JSON.decode!()

      assert payload == wire(record)
      assert Map.keys(record.intent) |> Enum.sort() == declared_keys(EditorContract, :intent)
      assert Map.keys(payload["intent"]) |> Enum.sort() == js_keys("EditorIntent")
      assert %{"intent" => %{"attrs" => wire_attrs, "uploads" => []}} = payload

      assert Enum.all?(all_keys(payload), &is_binary/1)
      fields = declared_keys(Content, :"#{kind}_attrs")
      assert Map.keys(wire_attrs) |> Enum.sort() == Enum.map(fields, &to_string/1)

      # Every field travels exactly as typed, including null, empty and whitespace.
      for field <- fields do
        assert Map.fetch!(wire_attrs, to_string(field)) === Map.fetch!(attrs, field), "#{field}"
      end

      # Content owns normalization: the changeset blanks these, and keeps the rest verbatim.
      saved = cast(kind, attrs)
      assert Map.take(saved, blanks) == Map.new(blanks, &{&1, nil})
      assert Map.take(saved, verbatim) == Map.take(attrs, verbatim)
    end
  end

  test "edit envelope retains complete original base and expected version" do
    author = user_fixture()
    tip = tip_fixture(author, %{model_other: "Local model", prompt: "  indented\n"})
    image = image_fixture(tip, %{position: 1, description: "After the change"})
    video = attached_video_fixture(tip, %{position: 0})
    base = edit_base(tip, [image, video])
    proposal = %{base | attrs: %{base.attrs | body: tip.body <> " More."}}

    record =
      edit_record(author.id, {:edit, :tip, tip.id}, base, tip.edit_version,
        revision: 4,
        intent: proposal
      )

    assert Map.keys(record) |> Enum.sort() == declared_keys(EditorContract, :draft_record)
    assert wire_keys(record) == js_keys("EditorRecord")
    assert Map.keys(record.base.attrs) |> Enum.sort() == declared_keys(Content, :tip_attrs)

    assert %{model_id: nil, model_other: "Local model", prompt: "  indented\n"} =
             record.base.attrs

    assert record.base.uploads == [
             {:retained, video.id, nil},
             {:retained, image.id, "After the change"}
           ]

    # The server version and the browser revision are separate counters.
    assert %{expected_version: 1, draft: %{revision: 4}, submission_key: nil} = record
    refute record.draft.draft_id == tip.submission_key

    video_id = video.id
    image_id = image.id

    assert %{
             "expected_version" => 1,
             "draft" => %{"revision" => 4},
             "base" => %{
               "attrs" => %{"prompt" => "  indented\n", "model_id" => nil},
               "uploads" => [
                 %{"tag" => "retained", "media_id" => ^video_id, "description" => nil},
                 %{
                   "tag" => "retained",
                   "media_id" => ^image_id,
                   "description" => "After the change"
                 }
               ]
             }
           } = wire(record)

    # A submission sends the proposal; the base stays for conflict recovery.
    assert Consumer.submission_intent(record.intent) == proposal
    assert Consumer.submission_intent(record.base) == base
  end

  test "handoff keeps original draft slot and leaves an ordinary edit draft unchanged" do
    author = user_fixture()
    tip = tip_fixture(author)
    edit_target = {:edit, :tip, tip.id}
    proposal = tip_attrs(%{body: "A proposal that differs from the published tip."})

    k =
      new_record(author.id, :new_tip,
        submission_key: tip.submission_key,
        revision: 6,
        attrs: proposal
      )

    e = edit_record(author.id, edit_target, edit_base(tip, []), tip.edit_version, revision: 2)
    form = form(tip)

    handoff = Consumer.handoff(k, form)
    assert Map.keys(handoff) |> Enum.sort() == declared_keys(EditorContract, :handoff)
    assert wire_keys(handoff) == js_keys("EditorHandoff")

    # The update is guarded by K's current pair and changes only mode, target, base and version.
    assert %{storage: storage, expected: expected, record: handed} = handoff
    assert {storage, expected} == {k.storage, k.draft}

    assert handed ==
             %{
               k
               | mode: :edit,
                 target: edit_target,
                 base: form.base,
                 expected_version: form.edit_version
             }

    # K keeps its slot, draft id, pre-write revision and key. The hook's guarded
    # write of this record advances the revision (#75); nothing here performs it.
    assert %{storage: %{slot: :new_tip}, draft: %{revision: 6}} = handed
    assert handed.draft.draft_id == tip.submission_key
    assert handed.intent == k.intent
    refute handed.storage == e.storage

    # K's confirmed edit clears only K; E keeps its own slot, draft and base.
    e_before = e

    assert {:clear, request} =
             Consumer.clear_request(handed, {:ok, edit_receipt(tip, :updated)})

    assert Consumer.clears?(handed, request)
    refute Consumer.clears?(e, request)
    assert e == e_before

    # Restore at either route surfaces K without advancing its base or version.
    for target <- [:new_tip, edit_target] do
      current = identity(author.id, target)

      assert Consumer.restore(current, %{identity: current, record: handed}, true) ==
               %{status: :restored, storage: k.storage, draft: k.draft}
    end

    # A handoff never crosses kinds or parents.
    review = review_fixture(tip, %{user_id: author.id})

    other_parent =
      new_record(author.id, {:new_review, tip.id + 1_000}, submission_key: review.submission_key)

    assert_raise FunctionClauseError, fn -> Consumer.handoff(k, form(review)) end
    assert_raise FunctionClauseError, fn -> Consumer.handoff(other_parent, form(review)) end
  end

  test "unknown image descriptors retain order and never acknowledge saved bytes" do
    uploads = [
      {:retained, 11, "Before"},
      image("slot-2", "diagram.png", "Request and response"),
      {:staged_video, 12},
      image("slot-4", "diagram.png")
    ]

    intent = %{attrs: tip_attrs(), uploads: uploads}

    record =
      edit_record(9, {:edit, :tip, 5}, %{intent | uploads: [{:retained, 11, "Before"}]}, 3,
        intent: intent
      )

    assert declared_tags(EditorContract, :media) == [:retained, :staged_video, :missing_image]

    assert declared_keys(EditorContract, :image_descriptor) == [
             :description,
             :filename,
             :size,
             :type
           ]

    assert %{"intent" => %{"uploads" => wire_uploads}} = wire(record)

    assert [
             %{"tag" => "retained", "media_id" => 11, "description" => "Before"} = retained,
             %{"tag" => "missing_image", "slot" => "slot-2"} = first,
             %{"tag" => "staged_video", "media_id" => 12} = video,
             %{"tag" => "missing_image", "slot" => "slot-4", "description" => nil} = second
           ] = wire_uploads

    assert Enum.sort(Map.keys(retained)) == js_keys("EditorRetainedMedia")
    assert Enum.sort(Map.keys(video)) == js_keys("EditorStagedVideo")
    assert Enum.sort(Map.keys(first)) == js_keys("EditorMissingImage")
    assert Enum.sort(Map.keys(second)) == js_keys("EditorMissingImage")

    assert first == %{
             "tag" => "missing_image",
             "slot" => "slot-2",
             "filename" => "diagram.png",
             "type" => "image/png",
             "size" => 48_213,
             "description" => "Request and response"
           }

    assert [{"slot-2", %{filename: "diagram.png"}}, {"slot-4", %{description: nil}}] =
             Consumer.missing_images(record)

    assert wire_uploads |> JSON.encode!() |> JSON.decode!() == wire_uploads

    # Browser metadata maps to Content slots; the same filename proves nothing.
    assert %{uploads: submitted} = Consumer.submission_intent(intent)

    assert submitted == [
             {:retained, 11, "Before"},
             {:missing_image, "slot-2"},
             {:staged_video, 12},
             {:missing_image, "slot-4"}
           ]

    assert Enum.all?(submitted, &(elem(&1, 0) in declared_tags(Content, :attachment)))

    scenarios = Map.new(comparison_scenarios(), &{&1.name, &1})
    assert %{expected: :unknown} = scenarios["missing recovered image slot"]
    assert %{expected: :unknown} = scenarios["absent selection is not an empty selection"]

    assert %{intent: %{uploads: [_retained, {:missing_image, "slot-2"}]}, errors: [uploads: _]} =
             Enum.find(incomplete_write_scenarios(), &(&1.name == "unresolved image slot"))

    # An unknown whole selection stays null, never an empty selection.
    unknown = new_record(9, :new_tip, uploads: nil)
    assert %{"intent" => %{"uploads" => nil}} = wire(unknown)
    assert Consumer.submission_intent(unknown.intent).uploads == nil

    # No bytes, server paths, provider URLs or tokens reach the browser record.
    keys = record |> wire() |> all_keys()
    assert Enum.filter(keys, &(&1 in ~w(path bytes data url uri token key object_key))) == []

    refute Enum.any?(
             all_strings(wire(record)),
             &(String.starts_with?(&1, "/") or &1 =~ "://")
           )
  end

  test "created and equivalent receipts permit only the submitted draft pair to be cleared" do
    author = user_fixture()
    tip = tip_fixture(author)
    review = review_fixture(tip, %{user_id: author.id})

    for {target, row} <- [{:new_tip, tip}, {{:new_review, tip.id}, review}],
        outcome <- [:created, :existing_equivalent] do
      record = new_record(author.id, target, submission_key: row.submission_key, revision: 3)
      receipt = publication_receipt(row, outcome)

      assert {:clear, request} = Consumer.clear_request(record, {:ok, receipt})
      assert Map.keys(request) |> Enum.sort() == declared_keys(EditorContract, :clear_request)
      assert request.submitted == submitted(record)

      assert Map.keys(request.submitted) |> Enum.sort() ==
               declared_keys(EditorContract, :submitted_draft)

      assert wire_keys(request) == js_keys("EditorClearRequest")

      outcome_name = Atom.to_string(outcome)
      key = row.submission_key

      assert %{
               "receipt" => %{"outcome" => ^outcome_name, "submission_key" => ^key} = wire_receipt
             } =
               wire(request)

      assert Enum.sort(Map.keys(wire_receipt)) == js_keys("EditorPublicationReceipt")

      # Receipt guard: identity, key and outcome must all name this submission.
      other_kind = if receipt.kind == :tip, do: :review, else: :tip

      for changed <- [
            %{receipt | submission_key: Ecto.UUID.generate()},
            %{receipt | outcome: :existing_different},
            %{receipt | kind: other_kind}
          ] do
        assert Consumer.clear_request(record, {:ok, changed}) == :preserve
      end

      # Storage guard: only the same slot, draft UUID and revision clears.
      assert Consumer.clears?(record, request)
      refute Consumer.clears?(%{record | draft: draft(Ecto.UUID.generate(), 3)}, request)
      refute Consumer.clears?(%{record | draft: %{record.draft | revision: 4}}, request)
      refute Consumer.clears?(%{record | storage: storage(author.id + 1, target)}, request)
      refute Consumer.clears?(%{record | storage: storage(author.id, {:new_review, 1})}, request)
      refute Consumer.clears?(nil, request)
    end

    # The same key under another parent names another publication.
    moved =
      new_record(author.id, {:new_review, tip.id + 1_000}, submission_key: review.submission_key)

    assert Consumer.clear_request(moved, {:ok, publication_receipt(review, :created)}) ==
             :preserve

    parent_moved = %{publication_receipt(review, :created) | tip_id: tip.id + 1_000}

    review_record =
      new_record(author.id, {:new_review, tip.id}, submission_key: review.submission_key)

    assert Consumer.clear_request(review_record, {:ok, parent_moved}) == :preserve

    # A confirmed edit clears only its own target.
    edit = edit_record(author.id, {:edit, :tip, tip.id}, edit_base(tip, []), tip.edit_version)

    for outcome <- [:updated, :noop] do
      assert {:clear, request} = Consumer.clear_request(edit, {:ok, edit_receipt(tip, outcome)})
      assert %{"receipt" => wire_receipt} = wire(request)
      assert Enum.sort(Map.keys(wire_receipt)) == js_keys("EditorEditReceipt")
    end

    assert Consumer.clear_request(edit, {:ok, edit_receipt(review, :updated)}) == :preserve

    # The request is an instruction; it carries no clearing result.
    assert declared_keys(EditorContract, :clear_request) == [:receipt, :submitted]
  end

  test "different unknown and unresolved receipts preserve the proposal" do
    # What a clear request names: the stored record and the exact submitted pair.
    assert declared_keys(EditorContract, :submitted_draft) == [:draft, :storage, :target]
    assert js_keys("EditorSubmittedDraft") == ["draft", "storage", "target"]

    author = user_fixture()
    tip = tip_fixture(author)
    review = review_fixture(tip, %{user_id: author.id})

    for {target, row} <- [{:new_tip, tip}, {{:new_review, tip.id}, review}] do
      record = new_record(author.id, target, submission_key: row.submission_key)

      for outcome <- [:existing_different, :existing_unknown] do
        assert Consumer.clear_request(record, {:ok, publication_receipt(row, outcome)}) ==
                 :preserve
      end

      # Absent is not proof that an earlier request stopped; errors stay unresolved.
      for result <-
            [{:ok, nil}] ++ Enum.map(declared_tags(Content, :lookup_error), &{:error, &1}) do
        assert Consumer.clear_request(record, result) == :preserve
      end
    end

    # After handoff, K's uncertain edit never reuses the publication acknowledgement.
    k = new_record(author.id, :new_tip, submission_key: tip.submission_key)
    %{record: handed} = Consumer.handoff(k, form(tip))

    for result <- [
          {:ok, publication_receipt(tip, :existing_equivalent)},
          {:ok, publication_receipt(tip, :created)},
          {:error, :outcome_unknown},
          {:error, :conflict}
        ] do
      assert Consumer.clear_request(handed, result) == :preserve
    end
  end

  test "recovery event examples distinguish current account form from recovered identity" do
    js = File.read!(@js)
    {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(EditorContract)

    for name <-
          ~w(EditorDraft editor:restore editor:recover editor:handoff editor:clear) ++
            ~w(data-editor-identity data-editor-record editor[identity] editor[record]) do
      assert js =~ ~s("#{name}"), name
      assert moduledoc =~ "`#{name}`", name
    end

    for row <- [
          "| `editor:restore` | hook to LiveView |",
          "| `editor:recover` | form to LiveView |",
          "| `editor:handoff` | LiveView to hook |",
          "| `editor:clear` | LiveView to hook |"
        ] do
      assert moduledoc =~ row
    end

    assert moduledoc =~ ~s(phx-auto-recover="editor:recover")
    assert moduledoc =~ "`editor-<account_id>-<tip|review>`"
    assert declared_tags(EditorContract, :restore_status) == [:restored, :preserved, :rejected]

    current = identity(9, :new_tip)
    record = new_record(9, :new_tip, revision: 2)
    request = %{identity: current, record: record}
    reply = Consumer.restore(current, request, true)

    assert reply == %{status: :restored, storage: record.storage, draft: record.draft}
    assert Map.keys(reply) |> Enum.sort() == declared_keys(EditorContract, :restore_reply)
    assert wire_keys(reply) == js_keys("EditorRestoreReply")
    assert wire_keys(request) == js_keys("EditorRestoreRequest")

    # Typing before the read settles keeps the typed input.
    assert Consumer.restore(current, request, false).status == :preserved

    # Stale DOM from another account or form is rejected, whatever it recovered.
    assert Consumer.restore(identity(10, :new_tip), request, true).status == :rejected

    assert Consumer.restore(
             current,
             %{request | record: %{record | storage: storage(10, :new_tip)}},
             true
           ).status ==
             :rejected

    review_form = identity(9, {:new_review, 3})

    assert Consumer.restore(review_form, %{identity: review_form, record: record}, true).status ==
             :rejected

    # The DOM id is per account and kind, so another parent or item shares it.
    # Both identities travel, and the recovered one stays distinct.
    base = %{attrs: tip_attrs(), uploads: []}

    for {mounted, stale, stale_record} <- [
          {{:new_review, 3}, {:new_review, 4}, new_record(9, {:new_review, 4})},
          {{:edit, :tip, 5}, {:edit, :tip, 6}, edit_record(9, {:edit, :tip, 6}, base, 1)}
        ] do
      current = identity(9, mounted)
      recovered = %{identity: identity(9, stale), record: stale_record}

      assert Consumer.dom_id(current) == Consumer.dom_id(recovered.identity)
      assert wire(recovered)["identity"] != wire(current)
      assert Consumer.restore(current, recovered, true).status == :rejected

      # A stale record behind a current-looking identity is still not this form's.
      assert Consumer.restore(current, %{recovered | identity: current}, true).status == :rejected
    end

    assert Consumer.dom_id(identity(9, {:edit, :review, 2})) == "editor-9-review"

    # Restored settles recovery only: the pending key still needs its lookup.
    assert Consumer.clear_request(record, {:ok, nil}) == :preserve

    # DOM recovery sends the hidden payloads with the form fields, without storage.
    params = %{
      "editor" => %{
        "identity" => JSON.encode!(wire(current)),
        "record" => JSON.encode!(wire(record))
      },
      "tip" => wire(record)["intent"]["attrs"]
    }

    assert JSON.decode!(params["editor"]["identity"]) == wire(current)
    refute JSON.decode!(params["editor"]["identity"]) == wire(identity(10, :new_tip))
    assert JSON.decode!(params["editor"]["record"]) == wire(record)
  end

  defp kind(%Tip{}), do: :tip
  defp kind(%Review{}), do: :review

  # The authorized `get_edit_form/3` snapshot a handoff loads.
  defp form(row) do
    form = %{
      kind: kind(row),
      id: row.id,
      tip_id: Map.get(row, :tip_id, row.id),
      edit_version: row.edit_version,
      state: :live,
      base: edit_base(row, []),
      media: [],
      capabilities: %{vote: false, edit: true, delete: true, report: false}
    }

    assert Map.keys(form) |> Enum.sort() == declared_keys(Content, :edit_form)
    form
  end

  # Characterizes the existing changeset casting only; #72 owns the comparator.
  defp cast(kind, attrs) do
    schema = if kind == :tip, do: Tip, else: Review

    schema
    |> struct()
    |> schema.changeset(attrs)
    |> Ecto.Changeset.apply_changes()
    |> Map.take(editable_fields(kind))
  end

  defp wire_keys(value), do: value |> wire() |> Map.keys() |> Enum.sort()

  defp all_keys(map) when is_map(map),
    do: Enum.flat_map(map, fn {key, value} -> [key | all_keys(value)] end)

  defp all_keys(list) when is_list(list), do: Enum.flat_map(list, &all_keys/1)
  defp all_keys(_value), do: []

  defp all_strings(map) when is_map(map), do: Enum.flat_map(Map.values(map), &all_strings/1)
  defp all_strings(list) when is_list(list), do: Enum.flat_map(list, &all_strings/1)
  defp all_strings(value) when is_binary(value), do: [value]
  defp all_strings(_value), do: []

  # The sorted `@property` names of one `@typedef` in the JavaScript contract.
  defp js_keys(typedef) do
    source = File.read!(@js)

    Enum.find_value(Regex.scan(~r{/\*\*(.*?)\*/}s, source), fn [_, block] ->
      if block =~ ~r/@typedef\s+\{[^}]*\}\s+#{typedef}\b/ do
        ~r/@property\s+\{[^}]*\}\s+(\w+)/
        |> Regex.scan(block, capture: :all_but_first)
        |> List.flatten()
        |> Enum.sort()
      end
    end) || flunk("#{typedef} is not declared in #{@js}")
  end
end
