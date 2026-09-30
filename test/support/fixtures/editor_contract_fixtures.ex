defmodule TipsWeb.EditorContractFixtures do
  @moduledoc """
  Representative editor records for the browser contract in
  `TipsWeb.EditorContract`, built on `Tips.ContentContractFixtures`.

  Examples are data, not an implementation. `wire/1` writes the documented
  JSON wire form of `assets/js/editor_contract.js` so tests can compare both
  sides; no runtime encoder exists. Ids are synthetic unless a test passes
  saved rows.
  """

  import Tips.ContentContractFixtures, only: [attrs: 1]

  @doc "Where a record is stored: the account and its form slot."
  def storage(account_id, slot), do: %{account_id: account_id, slot: slot}

  @doc "The current account and logical form target of a mounted editor."
  def identity(account_id, target), do: %{account_id: account_id, target: target}

  @doc "A browser draft guard: record identity and its revision."
  def draft(draft_id, revision), do: %{draft_id: draft_id, revision: revision}

  @doc "A browser image descriptor whose file must be reselected after reopening."
  def image(slot, filename, description \\ nil),
    do:
      {:missing_image, slot,
       %{filename: filename, type: "image/png", size: 48_213, description: description}}

  @doc """
  A new-publication record. Its draft id is its submission key, and it lives in
  the one new-tip slot of the account or the new-review slot of the parent.
  """
  def new_record(account_id, target, opts \\ []) do
    kind = if target == :new_tip, do: :tip, else: :review
    key = Keyword.get_lazy(opts, :submission_key, &Ecto.UUID.generate/0)

    %{
      storage: storage(account_id, target),
      draft: draft(key, Keyword.get(opts, :revision, 1)),
      mode: :new,
      target: target,
      submission_key: key,
      intent: %{attrs: Keyword.get(opts, :attrs, attrs(kind)), uploads: opts[:uploads] || []},
      base: nil,
      expected_version: nil
    }
  end

  @doc """
  An ordinary edit record of a published item: a local draft id, the complete
  immutable base and the expected server version from `get_edit_form/3`.
  """
  def edit_record(account_id, {:edit, _kind, _id} = target, base, expected_version, opts \\ []) do
    %{
      storage: storage(account_id, target),
      draft: draft(Ecto.UUID.generate(), Keyword.get(opts, :revision, 1)),
      mode: :edit,
      target: target,
      submission_key: nil,
      intent: Keyword.get(opts, :intent, base),
      base: base,
      expected_version: expected_version
    }
  end

  @doc "The draft that was submitted: storage, exact draft pair and logical target."
  def submitted(%{storage: storage, draft: draft, target: target}),
    do: %{storage: storage, draft: draft, target: target}

  @doc "The JSON wire form of a contract value, with string keys and tagged objects."
  def wire(%{storage: storage, draft: draft, mode: mode, target: target} = record) do
    %{
      "storage" => wire(storage),
      "draft" => wire(draft),
      "mode" => Atom.to_string(mode),
      "target" => wire_target(target),
      "submission_key" => record.submission_key,
      "intent" => wire_intent(record.intent),
      "base" => wire_intent(record.base),
      "expected_version" => record.expected_version
    }
  end

  def wire(%{account_id: account_id, slot: slot}),
    do: %{"account_id" => account_id, "slot" => wire_target(slot)}

  def wire(%{account_id: account_id, target: target}),
    do: %{"account_id" => account_id, "target" => wire_target(target)}

  def wire(%{draft_id: draft_id, revision: revision}),
    do: %{"draft_id" => draft_id, "revision" => revision}

  def wire(%{identity: identity, record: record}),
    do: %{"identity" => wire(identity), "record" => wire(record)}

  def wire(%{status: status, storage: storage, draft: draft}),
    do: %{"status" => Atom.to_string(status), "storage" => wire(storage), "draft" => wire(draft)}

  def wire(%{storage: storage, expected: expected, record: record}),
    do: %{"storage" => wire(storage), "expected" => wire(expected), "record" => wire(record)}

  def wire(%{submitted: submitted, receipt: receipt}) do
    %{"submitted" => wire(submitted), "receipt" => Map.new(receipt, &wire_receipt_field/1)}
  end

  def wire(%{storage: storage, draft: draft, target: target}),
    do: %{"storage" => wire(storage), "draft" => wire(draft), "target" => wire_target(target)}

  defp wire_target(:new_tip), do: %{"tag" => "new_tip"}
  defp wire_target({:new_review, tip_id}), do: %{"tag" => "new_review", "tip_id" => tip_id}

  defp wire_target({:edit, kind, id}),
    do: %{"tag" => "edit", "kind" => Atom.to_string(kind), "id" => id}

  defp wire_intent(nil), do: nil

  defp wire_intent(%{attrs: attrs, uploads: uploads}) do
    %{
      "attrs" => Map.new(attrs, fn {field, value} -> {Atom.to_string(field), value} end),
      "uploads" => uploads && Enum.map(uploads, &wire_media/1)
    }
  end

  defp wire_media({:retained, media_id, description}),
    do: %{"tag" => "retained", "media_id" => media_id, "description" => description}

  defp wire_media({:staged_video, media_id}),
    do: %{"tag" => "staged_video", "media_id" => media_id}

  defp wire_media({:missing_image, slot, image}) do
    image
    |> Map.new(fn {field, value} -> {Atom.to_string(field), value} end)
    |> Map.merge(%{"tag" => "missing_image", "slot" => slot})
  end

  defp wire_receipt_field({field, value}) when is_atom(value) and not is_nil(value),
    do: {Atom.to_string(field), Atom.to_string(value)}

  defp wire_receipt_field({field, value}), do: {Atom.to_string(field), value}
end
