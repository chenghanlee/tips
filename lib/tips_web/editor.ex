defmodule TipsWeb.Editor do
  @moduledoc """
  The page side of the tip and review editors: the form identity, the draft
  record the page renders, and the `EditorDraft` hook's restore and recovery
  events. Types and rules are in `TipsWeb.EditorContract`; the hook is
  `assets/js/editor_draft.js`.

  The page assigns `:identity`, `:record`, `:attrs`, `:form`, `:check`,
  `:pending`, `:receipt`, `:saved`, `:refusal`, `:outcome`, `:images`,
  `:attached`, `:video_states`, `:video_refs` and `:video_cycle`, and allows
  the `:images` and `:videos` uploads:

    * `:record` is the draft the page was mounted, restored or recovered with.
      It holds the submission key, the edit base and expected version, and
      after a submit the submitted values. Its selection is the page's
      current one: a selected file is a `missing_image` descriptor, and
      Remove drops an entry. The hook owns the browser revision after its
      first save and never writes it back to the page.
    * `:images` maps each image slot to its selected upload entry. A file
      selected while a slot awaits reselection binds to that slot; a
      replacement keeps its slot. `:attached` is each saved attachment's kind.
    * `:attrs` are the current field values, exactly as typed. `phx-change`
      keeps them in step with the browser. It validates only after a submit
      failed validation; `:check` holds that submit's values and errors.
    * `:pending` is set while a submission's outcome is unresolved: `:absent`
      (no publication now; Retry sends the same key), `:unchecked` (the
      lookup failed; Check again) or `:signed_out`. Its values stay fixed.
    * `:receipt` is a confirmed publication or save, with its destination
      `:to`, whose draft the hook is clearing. `:saved` is the current saved edit after an unknown outcome.
    * `:refusal` explains a refused or unconfirmed save and `:outcome` a save
      whose browser draft was kept.
    * `:video_states` holds the last committed state of each staged video
      (`t:Tips.Content.Media.video_status/0`) with `expired`, from the
      page's clock, and `:video_refs` the upload
      entry of each video this page is transferring. The browser sends the
      bytes to Stream by tus (`assets/js/video_uploader.js`); the page never
      consumes a video entry.
    * `:video_cycle` is the status cycle: its generation, current delay and
      whether a read is in flight. One `Tips.Content.get_video_uploads/2`
      read runs at a time for the pending videos, the next one a delay after
      it completes: the configured `status_delay_ms`, doubling up to
      `status_max_delay_ms` after an uncertain or rate-limited read.
      Preflight, restore, recover and Remove start a new generation; a
      message from an older one is ignored. A read in flight then is not
      killed, which would drop its database connection mid-query: its result
      is dropped and the new generation reads at once. The cycle stops when
      nothing is pending or the account can no longer read. One timer for
      the next deadline among the selected videos marks a video expired
      when it passes, ready ones included, without a read.

  A submit validates the whole form with `Tips.Content.change_content/2`,
  readmits the session, then publishes or saves with each slot's uploaded
  file. Entries are consumed only with a `:created`, `:existing_equivalent`,
  `:updated` or `:noop` receipt, which then pushes `editor:clear`;
  once the hook has cleared the submitted draft, the page leaves for the
  published item; the hook leaves by itself if that reply is lost. If other
  browser work kept the draft, the page stays. Any other result keeps the
  draft and the selected files, for a retry with the same key. An unknown outcome runs one lookup:
  `Tips.Content.get_publication/4` for a publication, `get_edit_form/3` for an
  edit, which shows the saved version beside the proposal and keeps the
  expected version. A restored new draft is looked up before it is applied.

  The page renders `form_attrs/1` on its form and `hidden_inputs/1` inside it.
  A browser record or recovered form is untrusted input: `editor:restore` and
  `editor:recover` accept it only for the freshly mounted account and target,
  and only in the shape the hook and store use.
  """
  use Phoenix.Component
  use TipsWeb, :verified_routes

  require Logger

  alias Phoenix.LiveView
  require Phoenix.LiveView
  alias Tips.Content
  alias TipsWeb.{AuthMailAdmission, CoreComponents, EditorContract, Reader, UserAuth}

  @kinds %{"tip" => :tip, "review" => :review}

  @status_delay_ms Application.compile_env!(:tips, [__MODULE__, :status_delay_ms])
  @status_max_delay_ms Application.compile_env!(:tips, [__MODULE__, :status_max_delay_ms])
  # `Tips.Content.get_video_uploads/2` reads at most ten ids.
  @max_status_ids 10

  @fields %{
    tip: ~w(title body tag_id model_id model_other environment_id prompt output)a,
    review: ~w(body model_id model_other environment_id prompt output)a
  }

  defp fields(kind), do: Map.fetch!(@fields, kind)

  @doc """
  Assigns a fresh new-content draft: a new submission key, which is also its
  draft id, at revision 0. `attrs` are the initial values, such as a review's
  setup from its tip.
  """
  @spec assign_new(Phoenix.LiveView.Socket.t(), EditorContract.target(), map()) ::
          Phoenix.LiveView.Socket.t()
  def assign_new(socket, target, attrs \\ %{}) do
    key = Ecto.UUID.generate()
    kind = kind(target)
    attrs = Map.new(fields(kind), &{&1, Map.get(attrs, &1)})

    socket
    |> assign_identity(target)
    |> assign(:attached, %{})
    |> allow_images()
    |> allow_videos()
    |> assign_record(%{
      storage: %{account_id: account_id(socket), slot: target},
      draft: %{draft_id: key, revision: 0},
      mode: :new,
      target: target,
      submission_key: key,
      intent: %{attrs: attrs, uploads: []},
      base: nil,
      expected_version: nil
    })
  end

  @doc """
  Assigns a fresh edit draft from `Tips.Content.get_edit_form/3`: a new local
  draft id, the complete base and its version.
  """
  @spec assign_edit(Phoenix.LiveView.Socket.t(), Content.edit_form()) ::
          Phoenix.LiveView.Socket.t()
  def assign_edit(socket, %{kind: kind, id: id, base: base, edit_version: version} = form) do
    target = {:edit, kind, id}

    socket
    |> assign_identity(target)
    |> assign(:attached, Map.new(form.media, &{&1.id, &1.kind}))
    |> allow_images()
    |> allow_videos()
    |> assign_record(%{
      storage: %{account_id: account_id(socket), slot: target},
      draft: %{draft_id: Ecto.UUID.generate(), revision: 0},
      mode: :edit,
      target: target,
      submission_key: nil,
      intent: base,
      base: base,
      expected_version: version
    })
  end

  defp assign_identity(socket, target) do
    assign(socket,
      identity: %{account_id: account_id(socket), target: target},
      check: nil,
      pending: nil,
      receipt: nil,
      saved: nil,
      refusal: nil,
      outcome: nil,
      images: %{},
      video_states: %{},
      video_refs: %{},
      video_cycle: %{generation: 0, delay_ms: @status_delay_ms, reading: false, deadline: nil}
    )
  end

  # One image per submission; the page owns each file until its content is confirmed.
  defp allow_images(socket) do
    LiveView.allow_upload(socket, :images,
      accept: ~w(.png .jpg .jpeg .webp .gif),
      max_entries: 1,
      max_file_size: 10_000_000,
      auto_upload: false,
      progress: &log_failed_write/3
    )
  end

  # LiveView keeps an entry whose temporary file could not be written, with a
  # `{:writer_failure, reason}` error that renders beside its item.
  defp log_failed_write(:images, entry, socket) do
    for {:writer_failure, reason} <- upload_errors(socket.assigns.uploads.images, entry) do
      Logger.warning(
        "Image upload not written: target=#{inspect(socket.assigns.identity.target)} " <>
          "entry=#{entry.ref} reason=#{inspect(reason)}"
      )
    end

    {:noreply, socket}
  end

  # One video per editor. The browser sends it to Stream while the author writes.
  defp allow_videos(socket) do
    LiveView.allow_upload(socket, :videos,
      accept: ~w(.mp4 .mov .webm),
      max_entries: 1,
      max_file_size: 1_000_000_000,
      auto_upload: true,
      external: &preflight_video/2
    )
  end

  defp assign_record(socket, record) do
    socket
    |> assign(:record, record)
    |> bind_images()
    |> assign_attrs(record.intent.attrs)
  end

  defp assign_attrs(socket, attrs) do
    kind = kind(socket.assigns.identity.target)
    errors = errors(socket.assigns.check, kind, attrs)

    assign(socket,
      attrs: attrs,
      form: to_form(form_params(kind, attrs), as: kind, errors: errors)
    )
  end

  # Before a refused submit, none. After one, the submitted errors of fields
  # the author has not changed since, and the current errors of those they have.
  defp errors(nil, _kind, _attrs), do: []

  defp errors(%{attrs: submitted, errors: errors}, kind, attrs) do
    changed? = fn {field, _error} -> Map.get(attrs, field) != Map.get(submitted, field) end
    %{errors: current} = Content.change_content(kind, attrs)
    Enum.reject(errors, changed?) ++ Enum.filter(current, changed?)
  end

  defp account_id(socket), do: socket.assigns.current_scope.user.id

  @doc """
  Handles the editor form's events and the `EditorDraft` hook's:

    * `"change"` keeps the typed values, image descriptions and selected
      files; it validates changed fields only after a submit failed
      validation.
    * `"remove_attachment"` drops an image slot (`"slot"`), cancelling its
      file, a saved attachment (`"media_id"`), or a staged video
      (`"video"`), which it discards and whose transfer it aborts.
    * `"submit"` publishes or saves (see the module documentation).
    * `"editor:restore"` applies the record the hook read, replying
      `restored`, `published` (its publication was already confirmed, so the
      hook clears it) or `rejected`.
    * `"editor:recover"` keeps a reconnected form's record and values.
    * `"editor:reconcile"` looks up an unresolved submission again: Check
      again, or the hook after a reconnect lost a submit's reply.
    * `"editor:cleared"` is the hook's result for the confirmed draft.
  """
  @spec handle_event(String.t(), map(), LiveView.Socket.t()) ::
          {:noreply, LiveView.Socket.t()} | {:reply, map(), LiveView.Socket.t()}
  def handle_event("change", params, socket), do: {:noreply, change(socket, params)}
  def handle_event("submit", params, socket), do: {:noreply, submit(socket, params)}
  def handle_event("remove_attachment", params, socket), do: {:noreply, remove(socket, params)}

  def handle_event("editor:restore", params, socket) do
    {reply, restored} = restore(socket, params)
    selected = staged_videos(socket.assigns.record)
    {:reply, reply, restored |> deselect_videos(selected) |> start_cycle() |> settle()}
  end

  def handle_event("editor:recover", params, socket),
    do: {:noreply, socket |> recover(params) |> start_cycle()}

  def handle_event("editor:reconcile", _params, socket) do
    {:noreply,
     socket
     |> assign(refusal: nil, outcome: nil)
     |> fix(socket.assigns.attrs)
     |> reconcile()
     |> settle()}
  end

  def handle_event("editor:cleared", params, socket) do
    {left?, socket} = cleared(socket, params)
    {:reply, %{left: left?}, socket}
  end

  defp change(socket, params) do
    kind = kind(socket.assigns.identity.target)

    socket
    |> update(:record, &describe_images(&1, params["image_descriptions"]))
    |> bind_images()
    |> assign_attrs(typed_attrs(kind, params[Atom.to_string(kind)], socket.assigns.attrs))
  end

  defp describe_images(%{intent: %{uploads: [_ | _] = uploads}} = record, descriptions)
       when is_map(descriptions) do
    uploads =
      Enum.map(uploads, fn
        {:missing_image, slot, image} when is_binary(:erlang.map_get(slot, descriptions)) ->
          {:missing_image, slot, %{image | description: descriptions[slot]}}

        upload ->
          upload
      end)

    put_in(record.intent.uploads, uploads)
  end

  defp describe_images(record, _descriptions), do: record

  # Binds each selected file to an image slot: its own, else the first slot
  # awaiting reselection, else a new slot at the end. The slot's descriptor
  # follows its file and keeps its description. A selection the page cannot
  # know (`nil`) takes no files.
  defp bind_images(%{assigns: %{record: %{intent: %{uploads: nil}}}} = socket), do: socket

  defp bind_images(socket) do
    entries = socket.assigns.uploads.images.entries

    refs =
      Map.filter(socket.assigns.images, fn {_slot, ref} ->
        Enum.any?(entries, &(&1.ref == ref))
      end)

    free = Enum.reject(entries, &(&1.ref in Map.values(refs)))

    {uploads, {refs, free}} =
      Enum.map_reduce(socket.assigns.record.intent.uploads, {refs, free}, fn
        {:missing_image, slot, image}, {refs, [entry | free]} when not is_map_key(refs, slot) ->
          {{:missing_image, slot, image(entry, image.description)},
           {Map.put(refs, slot, entry.ref), free}}

        upload, acc ->
          {upload, acc}
      end)

    {added, refs} =
      Enum.map_reduce(free, refs, fn entry, refs ->
        slot = Ecto.UUID.generate()
        {{:missing_image, slot, image(entry, nil)}, Map.put(refs, slot, entry.ref)}
      end)

    socket
    |> assign(:images, refs)
    |> update(:record, &put_in(&1.intent.uploads, uploads ++ added))
  end

  defp image(entry, description) do
    %{
      filename: entry.client_name,
      type: entry.client_type,
      size: entry.client_size,
      description: description
    }
  end

  defp remove(socket, %{"slot" => slot}) do
    socket =
      case socket.assigns.images do
        %{^slot => ref} -> LiveView.cancel_upload(socket, :images, ref)
        _unbound -> socket
      end

    socket
    |> update(:images, &Map.delete(&1, slot))
    |> drop_upload(&match?({:missing_image, ^slot, _image}, &1))
  end

  defp remove(socket, %{"media_id" => id}) do
    drop_upload(socket, fn
      {:retained, media_id, _description} -> Integer.to_string(media_id) == id
      _other -> false
    end)
  end

  defp remove(socket, %{"video" => value}) do
    case Enum.find(staged_videos(socket.assigns.record), &(Integer.to_string(&1) == value)) do
      nil -> socket
      id -> discard_video(socket, id)
    end
  end

  defp drop_upload(socket, removed?) do
    update(socket, :record, fn record ->
      update_in(record.intent.uploads, &Enum.reject(&1, removed?))
    end)
  end

  ## Videos

  # Reserves the selected video, or resumes the interrupted one from the same
  # file. Each preflight readmits the session first.
  defp preflight_video(entry, socket) do
    with {:ok, socket} <- UserAuth.readmit(socket),
         {mode, {:ok, upload}} <- reserve_video(socket, entry) do
      meta = %{
        uploader: "Tus",
        media_id: upload.media_id,
        upload_url: upload.upload_url,
        expires_at: upload.expires_at
      }

      {:ok, meta, socket |> stage_video(mode, entry, upload) |> start_cycle()}
    else
      {:error, :unauthenticated} ->
        {:error, %{reason: video_error(:unauthenticated, entry, socket)}, socket}

      {mode, {:error, reason}} ->
        {:error, %{reason: video_error({mode, reason}, entry, socket)},
         video_refused(socket, reason)}
    end
  end

  defp reserve_video(socket, entry) do
    %{current_scope: scope, record: record} = socket.assigns
    file = %{size: entry.client_size}

    case record.intent.uploads && staged_videos(record) do
      [] ->
        {:begin, Content.begin_video_upload(scope, upload_target(record), file)}

      [id] ->
        if interrupted?(socket.assigns, id),
          do: {:resume, Content.resume_video_upload(scope, id, file)},
          else: {:begin, {:error, :one_video}}

      _several_or_unknown ->
        {:begin, {:error, :one_video}}
    end
  end

  defp upload_target(%{target: :new_tip, submission_key: key}), do: {:new_tip, key}

  defp upload_target(%{target: {:new_review, tip_id}, submission_key: key}),
    do: {:new_review, tip_id, key}

  defp upload_target(%{target: {:edit, :tip, id}}), do: {:edit_tip, id}
  defp upload_target(%{target: {:edit, :review, id}}), do: {:edit_review, id}

  defp stage_video(socket, mode, entry, %{media_id: id, expires_at: expires_at}) do
    socket =
      socket
      |> update(:video_refs, &Map.put(&1, id, entry.ref))
      |> put_video_states([
        %{media_id: id, state: :uploading, expires_at: expires_at, refresh: :ok}
      ])

    case mode do
      :begin ->
        update(
          socket,
          :record,
          &update_in(&1.intent.uploads, fn u -> u ++ [{:staged_video, id}] end)
        )

      :resume ->
        socket
    end
  end

  defp staged_videos(%{intent: %{uploads: uploads}}),
    do: for({:staged_video, id} <- uploads || [], do: id)

  # A staged upload this page is not transferring, not known to have finished
  # or expired. Only Content decides whether it resumes.
  defp interrupted?(assigns, id) do
    live_video_entry(assigns.uploads.videos, assigns.video_refs, id) == nil and
      case assigns.video_states[id] do
        nil -> true
        %{state: :uploading} = status -> not expired?(status)
        _other -> false
      end
  end

  defp live_video_entry(upload, refs, id) do
    ref = refs[id]
    Enum.find(upload.entries, &(&1.ref == ref))
  end

  # The publication behind a published key, as a submit shows it.
  defp video_refused(socket, {:published, receipt}),
    do:
      refuse(
        socket,
        :published_earlier,
        receipt.state != :deleted && destination(socket, receipt)
      )

  defp video_refused(socket, _reason), do: socket

  defp video_error(:unauthenticated, _entry, _socket),
    do:
      "Your sign-in has expired, so the video wasn't added. Sign in again, then select it again."

  defp video_error({_mode, :unauthenticated}, entry, socket),
    do: video_error(:unauthenticated, entry, socket)

  defp video_error({_mode, :unconfirmed}, _entry, _socket),
    do: "Confirm your email address before you add a video."

  defp video_error({_mode, :forbidden}, _entry, _socket), do: "This account can't add videos."

  defp video_error({_mode, {:rate_limited, seconds}}, _entry, _socket),
    do: "Too many uploads. Try again in #{AuthMailAdmission.retry_in(seconds)}."

  defp video_error({_mode, {:capacity, seconds}}, _entry, _socket),
    do: "Tips is busy. Try again in #{AuthMailAdmission.retry_in(seconds)}."

  defp video_error({:resume, :not_found}, entry, _socket),
    do: "#{entry.client_name} isn't the same file as the interrupted upload."

  defp video_error({:begin, :not_found}, _entry, socket) do
    %{target: target} = socket.assigns.identity
    refusal(:not_found, kind(target), verb(target))
  end

  defp video_error({:begin, :one_video}, _entry, _socket),
    do: "Remove the selected video before adding another."

  defp video_error({:begin, {:published, _receipt}}, entry, _socket),
    do: "#{entry.client_name} wasn't added, because this draft was published earlier."

  defp video_error({:begin, :conflict}, _entry, _socket), do: "This draft belongs to another tip."

  # No URL was released, the outcome is unknown, or the size is out of range.
  defp video_error({mode, {:upload_failed, _ids}}, entry, socket),
    do: video_error({mode, :outcome_unknown}, entry, socket)

  defp video_error({mode, %Ecto.Changeset{}}, entry, socket),
    do: video_error({mode, :outcome_unknown}, entry, socket)

  defp video_error({_mode, :outcome_unknown}, entry, _socket),
    do: "#{entry.client_name} couldn't be uploaded. Select it again."

  # Discards the staged upload, drops its slot and aborts its transfer. An
  # upload Content no longer has is dropped too.
  defp discard_video(socket, id) do
    with {:ok, socket} <- UserAuth.readmit(socket),
         result when result in [:ok, {:error, :not_found}] <-
           Content.discard_video_upload(socket.assigns.current_scope, id) do
      socket
      |> cancel_video_entries()
      |> update(:video_refs, &Map.delete(&1, id))
      |> update(:video_states, &Map.delete(&1, id))
      |> drop_upload(&(&1 == {:staged_video, id}))
      |> LiveView.push_event("editor:abort_video", %{media_id: id})
      |> start_cycle()
    else
      {:error, :unauthenticated} -> refuse(socket, :unauthenticated)
      {:error, :outcome_unknown} -> refuse(socket, :video_remove_unknown)
    end
  end

  # A restored record replaced the selection: the videos it dropped lose
  # their entry and their transfer. Content keeps each row until it expires.
  defp deselect_videos(socket, selected) do
    Enum.reduce(selected -- staged_videos(socket.assigns.record), socket, fn id, socket ->
      socket
      |> cancel_video_entry(id)
      |> update(:video_refs, &Map.delete(&1, id))
      |> update(:video_states, &Map.delete(&1, id))
      |> LiveView.push_event("editor:abort_video", %{media_id: id})
    end)
  end

  defp cancel_video_entry(socket, id) do
    case live_video_entry(socket.assigns.uploads.videos, socket.assigns.video_refs, id) do
      %{ref: ref} -> LiveView.cancel_upload(socket, :videos, ref)
      nil -> socket
    end
  end

  # One video per editor: its entry, or a rejected selection, goes with it.
  defp cancel_video_entries(socket) do
    Enum.reduce(socket.assigns.uploads.videos.entries, socket, fn entry, socket ->
      LiveView.cancel_upload(socket, :videos, entry.ref)
    end)
  end

  @doc """
  Handles the video status cycle's scheduled `{:refresh_videos, generation}`,
  ignoring one from an earlier generation, and `:video_deadline`, which marks
  the videos whose deadline passed.
  """
  @spec handle_info(term(), LiveView.Socket.t()) :: {:noreply, LiveView.Socket.t()}
  def handle_info({:refresh_videos, generation}, socket) do
    case socket.assigns.video_cycle do
      %{generation: ^generation} -> {:noreply, run_cycle(socket)}
      _stale -> {:noreply, socket}
    end
  end

  def handle_info(:video_deadline, socket), do: {:noreply, put_video_states(socket, [])}

  @doc """
  Applies a `:video_status` read of the current cycle generation. A read of
  an earlier generation is dropped, and the current one reads at once.
  """
  @spec handle_async(atom(), term(), LiveView.Socket.t()) :: {:noreply, LiveView.Socket.t()}
  def handle_async(:video_status, result, socket) do
    socket = update(socket, :video_cycle, &%{&1 | reading: false})
    generation = socket.assigns.video_cycle.generation

    case result do
      {:ok, {^generation, ids, result}} ->
        {:noreply, cycled(socket, ids, result)}

      {:ok, _stale} ->
        {:noreply, run_cycle(socket)}

      {:exit, reason} ->
        {:noreply, retry(socket, pending_videos(socket.assigns), {:exit, reason})}
    end
  end

  # The selection changed: the deadline timer follows it before any read,
  # which may never succeed.
  defp start_cycle(socket) do
    socket
    |> update(:video_cycle, &%{&1 | generation: &1.generation + 1, delay_ms: @status_delay_ms})
    |> put_video_states([])
    |> run_cycle()
  end

  # Readmits the session, then reads the pending videos outside the page
  # process. A read in flight runs the next one when it completes.
  defp run_cycle(%{assigns: %{video_cycle: %{reading: true}}} = socket), do: socket

  defp run_cycle(socket) do
    with [_ | _] = ids <- pending_videos(socket.assigns),
         {:ok, socket} <- UserAuth.readmit(socket) do
      %{current_scope: scope, video_cycle: %{generation: generation}} = socket.assigns

      socket
      |> update(:video_cycle, &%{&1 | reading: true})
      |> LiveView.start_async(:video_status, fn ->
        # A closed page lets the bounded read finish rather than kill it mid-query,
        # which would drop its database connection. Nothing schedules another.
        Process.flag(:trap_exit, true)
        {generation, ids, Content.get_video_uploads(scope, ids)}
      end)
    else
      [] -> socket
      {:error, :unauthenticated} -> refuse(socket, :unauthenticated)
    end
  end

  # Selected videos not known to be ready, failed or removed.
  defp pending_videos(assigns) do
    assigns.record
    |> staged_videos()
    |> Enum.reject(&(assigns.video_states[&1][:state] in [:ready, :failed, :removed]))
    |> Enum.take(@max_status_ids)
  end

  defp cycled(socket, ids, {:ok, statuses}) do
    selected = staged_videos(socket.assigns.record)
    statuses = Enum.filter(statuses, &(&1.media_id in selected))
    socket = put_video_states(socket, statuses)

    case Enum.find(statuses, &(&1.refresh != :ok)) do
      nil -> schedule(socket, @status_delay_ms)
      %{refresh: reason} -> retry(socket, ids, reason)
    end
  end

  defp cycled(socket, ids, {:error, :not_found}) do
    put_video_states(
      socket,
      Enum.map(ids, &%{media_id: &1, state: :removed, expires_at: nil, refresh: :ok})
    )
  end

  defp cycled(socket, _ids, {:error, reason})
       when reason in [:unauthenticated, :forbidden, :unconfirmed],
       do: refuse(socket, reason)

  defp cycled(socket, ids, {:error, %Ecto.Changeset{}}) do
    Logger.error("Video status stopped: media=#{inspect(ids)} reason=invalid_ids")
    socket
  end

  defp cycled(socket, ids, {:error, :outcome_unknown}), do: retry(socket, ids, :outcome_unknown)

  defp retry(socket, ids, reason) do
    delay = min(socket.assigns.video_cycle.delay_ms * 2, @status_max_delay_ms)

    Logger.warning(
      "Video status retry: media=#{inspect(ids)} reason=#{inspect(reason, limit: 5)} next_ms=#{delay}"
    )

    schedule(socket, delay)
  end

  defp schedule(socket, delay) do
    socket = update(socket, :video_cycle, &%{&1 | delay_ms: delay})

    if pending_videos(socket.assigns) != [],
      do:
        Process.send_after(
          self(),
          {:refresh_videos, socket.assigns.video_cycle.generation},
          delay
        )

    socket
  end

  # Puts the statuses, marks every known status expired by one clock reading,
  # then arms one timer for the next deadline among the selected videos. A
  # deadline that passed before its timer ran is marked here, never scheduled.
  defp put_video_states(socket, statuses) do
    now = DateTime.utc_now()

    socket
    |> update(:video_states, fn states ->
      states
      |> Map.merge(Map.new(statuses, &{&1.media_id, &1}))
      |> Map.new(fn {id, status} ->
        {id, Map.put(status, :expired, past?(status.expires_at, now))}
      end)
    end)
    |> arm_deadline(now)
  end

  defp past?(%DateTime{} = deadline, now), do: DateTime.compare(deadline, now) != :gt
  defp past?(nil, _now), do: false

  defp arm_deadline(socket, now) do
    %{record: record, video_states: states, video_cycle: cycle} = socket.assigns
    if cycle.deadline, do: Process.cancel_timer(cycle.deadline)

    deadlines =
      for id <- staged_videos(record),
          %{expired: false, expires_at: %DateTime{} = deadline} <- [states[id]],
          do: deadline

    timer =
      if deadlines != [] do
        delay = DateTime.diff(Enum.min(deadlines, DateTime), now, :millisecond) + 1
        Process.send_after(self(), :video_deadline, delay)
      end

    update(socket, :video_cycle, &%{&1 | deadline: timer})
  end

  defp expired?(%{expired: expired}), do: expired
  defp expired?(nil), do: false

  @doc """
  Why Publish waits: `:expired` while a selected video's committed deadline
  has passed, else `:pending` while one is uploading, processing or not yet
  read; `nil` when nothing holds it.
  """
  @spec publish_wait(map(), map()) :: :expired | :pending | nil
  def publish_wait(record, video_states) do
    statuses = Enum.map(staged_videos(record), &video_states[&1])

    cond do
      Enum.any?(statuses, &expired?/1) -> :expired
      Enum.any?(statuses, &(&1 == nil or &1.state in [:uploading, :processing])) -> :pending
      true -> nil
    end
  end

  # Validates every field, including untouched ones, then readmits the session
  # and publishes or saves the typed values. An unresolved submission sends
  # its fixed values again. Every refusal keeps the input. A failed validation
  # pushes `editor:refused`, so the hook opens the evidence disclosure around
  # an error and focuses the error summary.
  defp submit(socket, params) do
    socket
    |> assign(refusal: nil, outcome: nil)
    |> submitted(params)
    |> settle()
  end

  defp submitted(%{assigns: %{pending: pending, record: record}} = socket, _params)
       when pending != nil,
       do: write(socket, record.intent.attrs)

  defp submitted(socket, params) do
    socket = change(socket, params)
    attrs = socket.assigns.attrs

    case Content.change_content(kind(socket.assigns.identity.target), attrs) do
      %{valid?: true} -> socket |> assign(:check, nil) |> assign_attrs(attrs) |> write(attrs)
      %{errors: errors} -> invalid(socket, errors)
    end
  end

  defp write(socket, attrs) do
    socket = fix(socket, attrs)

    with {:ok, socket} <- UserAuth.readmit(socket),
         {:ok, receipt} <-
           save(socket.assigns.current_scope, socket.assigns.record, files(socket)) do
      acknowledge(socket, receipt)
    else
      {:error, %Ecto.Changeset{errors: errors}} ->
        socket |> assign(:pending, nil) |> invalid(errors)

      {:error, :outcome_unknown} ->
        reconcile(socket)

      {:error, reason} ->
        refuse(socket, reason)
    end
  end

  # The submitted values, kept with the key, base and version for a lookup,
  # a retry and reconnect recovery.
  defp fix(socket, attrs), do: update(socket, :record, &put_in(&1.intent.attrs, attrs))

  defp save(scope, %{target: :new_tip, submission_key: key} = record, files),
    do: Content.publish_tip(scope, key, record.intent.attrs, uploads(record, files))

  defp save(scope, %{target: {:new_review, tip_id}, submission_key: key} = record, files),
    do: Content.publish_review(scope, tip_id, key, record.intent.attrs, uploads(record, files))

  defp save(scope, %{target: {:edit, :tip, id}, expected_version: version} = record, files),
    do: Content.edit_tip(scope, id, version, record.intent.attrs, uploads(record, files))

  defp save(scope, %{target: {:edit, :review, id}, expected_version: version} = record, files),
    do: Content.edit_review(scope, id, version, record.intent.attrs, uploads(record, files))

  # The uploaded file of each bound slot. The entries stay until a confirmed
  # receipt consumes them, so a retry sends them again. An entry that never
  # uploaded, such as a rejected one, leaves its slot missing.
  defp files(socket) do
    slots = Map.new(socket.assigns.images, fn {slot, ref} -> {ref, slot} end)
    {done, _not_uploaded} = LiveView.uploaded_entries(socket, :images)

    for %{ref: ref} = entry <- done, Map.has_key?(slots, ref), into: %{} do
      LiveView.consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:postpone, {slots[ref], %{path: path, filename: entry.client_name}}}
      end)
    end
  end

  defp consume_files(socket) do
    {done, _not_uploaded} = LiveView.uploaded_entries(socket, :images)
    Enum.each(done, &LiveView.consume_uploaded_entry(socket, &1, fn _file -> {:ok, nil} end))
    socket
  end

  # Browser image metadata never proves saved bytes; only a page file does.
  defp uploads(%{intent: %{uploads: nil}}, _files), do: nil

  defp uploads(%{intent: %{uploads: uploads}}, files),
    do: Enum.map(uploads, &attachment(&1, files))

  defp attachment({:missing_image, slot, image}, files) do
    case files do
      %{^slot => file} -> {:image_file, slot, file, image.description}
      _missing -> {:missing_image, slot}
    end
  end

  defp attachment(media, _files), do: media

  defp invalid(socket, errors) do
    socket
    |> assign(:check, %{attrs: socket.assigns.attrs, errors: errors})
    |> assign_attrs(socket.assigns.attrs)
    |> LiveView.push_event("editor:refused", %{})
  end

  # Only content acknowledged as submitted clears the submitted draft.
  defp acknowledge(socket, %{outcome: outcome} = receipt)
       when outcome in [:created, :existing_equivalent, :updated, :noop] do
    %{storage: storage, draft: %{draft_id: draft_id}} = socket.assigns.record
    socket = socket |> consume_files() |> confirm(receipt)

    LiveView.push_event(socket, "editor:clear", %{
      storage: storage_json(storage),
      draft_id: draft_id,
      to: socket.assigns.receipt.to
    })
  end

  defp acknowledge(socket, receipt) do
    socket
    |> assign(:pending, nil)
    |> refuse(:published_earlier, receipt.state != :deleted && destination(socket, receipt))
  end

  # Holds the confirmed receipt and its destination until the hook's clear.
  defp confirm(socket, receipt),
    do: assign(socket, pending: nil, receipt: Map.put(receipt, :to, destination(socket, receipt)))

  # One lookup of what an unknown outcome left saved. A publication is looked
  # up by its key and the submitted values; an edit reads the saved version
  # and keeps its expected version, so saving again keeps the version guard.
  defp reconcile(socket), do: reconciled(socket, lookup(socket))

  defp lookup(%{assigns: %{record: %{mode: :new} = record}} = socket) do
    with {:ok, socket} <- UserAuth.readmit(socket) do
      Content.get_publication(
        socket.assigns.current_scope,
        publication_kind(record.target),
        record.submission_key,
        %{attrs: record.intent.attrs, uploads: uploads(record, %{})}
      )
    end
  end

  defp lookup(%{assigns: %{record: %{target: {:edit, kind, id}}}} = socket) do
    with {:ok, socket} <- UserAuth.readmit(socket),
         do: Content.get_edit_form(socket.assigns.current_scope, kind, id)
  end

  defp publication_kind(:new_tip), do: :tip
  defp publication_kind({:new_review, tip_id}), do: {:review, tip_id}

  defp reconciled(socket, {:ok, %{base: %{attrs: saved}}}),
    do: socket |> assign(pending: nil, saved: saved) |> refuse(:unconfirmed_edit)

  defp reconciled(socket, {:ok, nil}), do: unresolved(socket, :absent)
  defp reconciled(socket, {:ok, receipt}), do: acknowledge(socket, receipt)
  defp reconciled(socket, {:error, :unauthenticated}), do: unresolved(socket, :signed_out)
  defp reconciled(socket, {:error, :outcome_unknown}), do: unresolved(socket, :unchecked)
  defp reconciled(socket, {:error, reason}), do: socket |> assign(:pending, nil) |> refuse(reason)

  defp unresolved(socket, pending),
    do: socket |> assign(:pending, pending) |> refuse({:unresolved, pending})

  # Tells the hook whether a submission is still unresolved, so it looks it
  # up again after a reconnect.
  defp settle(socket),
    do:
      LiveView.push_event(socket, "editor:settled", %{unresolved: socket.assigns.pending != nil})

  # The hook's result for the confirmed draft: cleared, not stored or not
  # clearable leave the editor; other browser work keeps it open. Returns
  # whether the page is leaving; without a receipt (a remounted page) the
  # hook leaves by itself.
  defp cleared(%{assigns: %{receipt: nil}} = socket, _params), do: {false, socket}

  defp cleared(%{assigns: %{receipt: receipt}} = socket, %{"status" => "conflict"}),
    do: {false, assign(socket, receipt: nil, outcome: kept(receipt))}

  defp cleared(%{assigns: %{receipt: receipt}} = socket, _params) do
    {true,
     socket
     |> assign(:receipt, nil)
     |> LiveView.put_flash(:info, done(receipt))
     |> LiveView.push_navigate(to: receipt.to)}
  end

  defp done(%{outcome: outcome}) when outcome in [:updated, :noop], do: "Changes saved."
  defp done(_receipt), do: "Published."

  defp kept(%{outcome: outcome}) when outcome in [:updated, :noop],
    do: "Changes saved. A different draft saved in this browser was kept; it isn't saved."

  defp kept(_receipt),
    do: "Published. A different draft saved in this browser was kept; it isn't published."

  # The item's page, from its current projection.
  defp destination(_socket, %{kind: :review, id: id}), do: ~p"/reviews/#{id}"

  defp destination(socket, %{kind: :tip, id: id}) do
    case Content.get_tip_page(UserAuth.viewer(socket), id) do
      {:ok, %{tip: tip}} -> Reader.tip_path(tip)
      {:error, _reason} -> Reader.tip_path(%{id: id, slug: "tip"})
    end
  end

  defp refuse(socket, reason, view \\ false) do
    %{target: target} = socket.assigns.identity

    assign(socket, :refusal, %{
      message: refusal(reason, kind(target), verb(target)),
      sign_in: reason in [:unauthenticated, {:unresolved, :signed_out}] && sign_in_path(target),
      check: reason == {:unresolved, :unchecked},
      view: view
    })
  end

  defp verb({:edit, _kind, _id}), do: "save"
  defp verb(_new), do: "publish"

  defp refusal(:unauthenticated, _kind, verb),
    do:
      "Your sign-in has expired, so nothing was #{past(verb)}. Sign in again, then #{verb} again."

  defp refusal(:forbidden, _kind, _verb),
    do:
      "This account can't publish or edit. You can still read, and delete your own tips, reviews or account."

  defp refusal(:unconfirmed, _kind, verb),
    do: "Confirm your email address before you #{verb}. Nothing was #{past(verb)}."

  defp refusal({:rate_limited, seconds}, _kind, verb),
    do:
      "Too many attempts, so nothing was #{past(verb)}. Try again in #{AuthMailAdmission.retry_in(seconds)}."

  defp refusal({:capacity, seconds}, _kind, verb),
    do:
      "Tips is busy, so nothing was #{past(verb)}. Try again in #{AuthMailAdmission.retry_in(seconds)}."

  defp refusal(:not_found, :review, "publish"), do: "This tip is no longer open for reviews."
  defp refusal(:not_found, kind, _verb), do: "This #{kind} is no longer available."
  defp refusal(:already_reviewed, _kind, _verb), do: "You have already reviewed this tip."

  defp refusal(:conflict, kind, "save"),
    do: "This #{kind} changed after you opened it, so your changes were not saved."

  defp refusal(:conflict, _kind, _verb), do: "This draft belongs to another tip."

  defp refusal(:published_earlier, kind, _verb),
    do:
      "This draft was published earlier, and that #{kind} may differ from what is here. Nothing new was published."

  defp refusal({:unresolved, :absent}, kind, _verb),
    do:
      "We couldn't confirm whether your #{kind} was published, and it isn't published now. Retry to publish it."

  defp refusal({:unresolved, :unchecked}, _kind, verb),
    do: "We couldn't check whether this was #{past(verb)}. Check again before you change it."

  defp refusal({:unresolved, :signed_out}, _kind, verb),
    do:
      "We couldn't check whether this was #{past(verb)} because your sign-in has expired. Sign in again to check."

  defp refusal(:unconfirmed_edit, kind, _verb),
    do:
      "We couldn't confirm whether your changes were saved. The saved #{kind} is below. If you save again and your changes were already saved, you'll be told the #{kind} changed."

  defp refusal({:too_long, 1}, kind, _verb),
    do: "This #{kind} is too long. Shorten it by about 1 word."

  defp refusal({:too_long, words}, kind, _verb),
    do: "This #{kind} is too long. Shorten it by about #{words} words."

  defp refusal({upload, _refs}, _kind, verb) when upload in [:upload_failed, :upload_pending],
    do: "An attachment isn't ready, so nothing was #{past(verb)}."

  defp refusal(:video_remove_unknown, _kind, _verb),
    do: "We couldn't confirm that the video was removed. Remove it again."

  defp past("publish"), do: "published"
  defp past("save"), do: "saved"

  defp sign_in_path(target), do: UserAuth.with_return_to(~p"/users/log-in", editor_path(target))

  defp editor_path(:new_tip), do: ~p"/editor/tips/new"
  defp editor_path({:new_review, tip_id}), do: ~p"/editor/tips/#{tip_id}/reviews/new"
  defp editor_path({:edit, :tip, id}), do: ~p"/editor/tips/#{id}/edit"
  defp editor_path({:edit, :review, id}), do: ~p"/editor/reviews/#{id}/edit"

  # Applies the record the hook read when its identity, storage slot and
  # target are this form's. Returns the reply to send.
  defp restore(socket, %{"identity" => identity, "record" => json}) do
    with true <- identity == identity_json(socket.assigns.identity),
         {:ok, record} <- own_record(socket, json) do
      reopen(socket, record, json)
    else
      _ -> {reply("rejected", json), socket}
    end
  end

  defp restore(socket, params), do: {reply("rejected", params["record"]), socket}

  # A new draft may have been published from another page: its key is looked
  # up first. An equivalent publication restores the draft while the hook
  # clears it, so recovery keeps its key until the clear settles; a missing
  # one restores the ordinary draft.
  defp reopen(socket, %{mode: :new} = record, json) do
    restored = assign_record(socket, record)

    case lookup(restored) do
      {:ok, nil} ->
        {reply("restored", json), restored}

      {:ok, %{outcome: :existing_equivalent} = receipt} ->
        restored = confirm(restored, receipt)
        {Map.put(reply("published", json), :to, restored.assigns.receipt.to), restored}

      result ->
        {reply("restored", json), reconciled(restored, result)}
    end
  end

  defp reopen(socket, record, json), do: {reply("restored", json), assign_record(socket, record)}

  defp reply(status, json) when is_map(json),
    do: %{status: status, storage: json["storage"], draft: json["draft"]}

  defp reply(status, _json), do: %{status: status, storage: nil, draft: nil}

  # After a reconnect, when the hidden identity is this freshly mounted
  # form's, keeps the hidden record (submission key, base, expected version)
  # and the recovered field values, blanks included. Otherwise keeps the
  # fresh mount and ignores the recovered values. Fixed fields are disabled
  # and send no values, so the record's submitted values stay.
  defp recover(socket, %{"editor" => %{"identity" => identity, "record" => record}} = params) do
    expected = identity_json(socket.assigns.identity)
    kind = kind(socket.assigns.identity.target)

    with {:ok, ^expected} <- JSON.decode(identity),
         {:ok, json} <- JSON.decode(record),
         {:ok, record} <- own_record(socket, json) do
      socket
      |> assign(:record, record)
      |> bind_images()
      |> assign_attrs(typed_attrs(kind, params[Atom.to_string(kind)], record.intent.attrs))
    else
      _ -> socket
    end
  end

  defp recover(socket, _params), do: socket

  # A record for this account's slot and this form's target. A handoff record
  # (an edit target in a new slot) is #93's.
  defp own_record(socket, json) do
    %{account_id: account_id, target: target} = socket.assigns.identity

    case decode_record(json) do
      {:ok, %{storage: %{account_id: ^account_id, slot: ^target}, target: ^target} = record} ->
        {:ok, record}

      _ ->
        :error
    end
  end

  @doc "The attributes of the editor form: id, hook, recovery and its data."
  @spec form_attrs(map()) :: keyword()
  def form_attrs(%{identity: identity, record: record}) do
    [
      id: form_id(identity),
      "phx-hook": "EditorDraft",
      "phx-change": "change",
      "phx-submit": "submit",
      "phx-auto-recover": "editor:recover",
      "data-editor-identity": JSON.encode!(identity_json(identity)),
      "data-editor-record": JSON.encode!(record_json(record))
    ]
  end

  @doc "The form and hook element id: `editor-<account_id>-<tip|review>`."
  @spec form_id(EditorContract.identity()) :: String.t()
  def form_id(%{account_id: account_id, target: target}),
    do: "editor-#{account_id}-#{kind(target)}"

  @doc "Renders the hidden identity and record that LiveView recovers on reconnect."
  attr :identity, :map, required: true
  attr :record, :map, required: true

  def hidden_inputs(assigns) do
    ~H"""
    <input type="hidden" name="editor[identity]" value={JSON.encode!(identity_json(@identity))} />
    <input type="hidden" name="editor[record]" value={JSON.encode!(record_json(@record))} />
    """
  end

  @doc """
  Renders the model and environment selects. A saved choice that is no longer
  curated stays selectable.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :choices, :map, required: true, doc: "`Tips.Content.list_filter_choices/0`"
  attr :helper, :string, default: nil

  def setup_fields(assigns) do
    form = assigns.form

    assigns =
      assign(assigns,
        models:
          [{"Not specified", ""}] ++
            options(assigns.choices.models, form[:model_id].value) ++ [{"Other model…", "other"}],
        environments:
          [{"Not specified", ""}] ++
            options(assigns.choices.environments, form[:environment_id].value)
      )

    ~H"""
    <div class="grid gap-2">
      <div class="grid gap-4 sm:grid-cols-2">
        <TipsWeb.UI.model_field
          select_field={@form[:model_id]}
          text_field={@form[:model_other]}
          options={@models}
        />
        <TipsWeb.UI.field
          field={@form[:environment_id]}
          type="select"
          label="Environment used (optional)"
          options={@environments}
        />
      </div>
      <p :if={@helper} class="text-sm text-muted-foreground">{@helper}</p>
    </div>
    """
  end

  @doc "Renders the select options of curated `choices`, keeping a saved retired `value`."
  @spec options([%{id: String.t(), label: String.t()}], String.t() | nil) :: [
          {String.t(), String.t()}
        ]
  def options(choices, value) do
    options = Enum.map(choices, &{&1.label, &1.id})

    if value in [nil, "", "other"] or Enum.any?(choices, &(&1.id == value)),
      do: options,
      else: options ++ [{value, value}]
  end

  @doc """
  Renders the optional Prompt and Result disclosure with the image
  selection, open when either text field holds text or something is
  selected. The `EditorDraft` hook opens it when a restored draft has
  evidence. Each selected or restored image shows its file name and size, its
  description and Remove; a slot without a file asks for it again. Saved
  attachments of an edit show Remove. A staged video shows its state from
  the last status read and this page's transfer, with Resume, Replace or
  Remove as the state allows; the `VideoTransfers` hook on the list paints
  the browser's transfer progress. Errors of the last refused submit and of
  a rejected file show beside their item.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :id, :string, required: true
  attr :upload, Phoenix.LiveView.UploadConfig, required: true
  attr :selection, :list, required: true, doc: "the record's selection; `nil` when unknown"
  attr :images, :map, required: true, doc: "image slot to upload entry ref"
  attr :attached, :map, required: true, doc: "saved attachment id to kind"
  attr :video_upload, Phoenix.LiveView.UploadConfig, required: true
  attr :video_states, :map, required: true, doc: "staged video id to its last status"
  attr :video_refs, :map, required: true, doc: "staged video id to its upload entry ref"

  def evidence_fields(assigns) do
    entries = Map.new(assigns.upload.entries, &{&1.ref, &1})
    selection = assigns.selection || []
    video_errors = video_errors(assigns.video_upload)
    staged? = Enum.any?(selection, &match?({:staged_video, _id}, &1))

    assigns =
      assign(assigns,
        items: Enum.map(selection, &attachment_item(&1, assigns, entries, video_errors)),
        video_errors: if(staged?, do: [], else: video_errors),
        staged: staged?,
        open:
          selection != [] or
            Enum.any?([:prompt, :output], &(assigns.form[&1].value not in [nil, ""])),
        summary: summary(length(selection)),
        invalid: Keyword.has_key?(assigns.form.errors, :uploads) && "true"
      )

    ~H"""
    <TipsWeb.UI.disclosure id={@id} open={@open} summary={@summary}>
      <TipsWeb.UI.field
        field={@form[:prompt]}
        type="textarea"
        rows={4}
        label="Prompt (optional)"
        helper="Up to 10,000 characters. Shown exactly as you type it."
      />
      <TipsWeb.UI.field
        field={@form[:output]}
        type="textarea"
        rows={4}
        label="Result text (optional)"
        helper="Up to 10,000 characters. Shown exactly as you type it."
      />
      <%!-- Always rendered: the hook keeps the browser's transfers while the list empties. --%>
      <ol
        id={"#{@id}-attachments"}
        phx-hook="VideoTransfers"
        hidden={@items == []}
        aria-label="Attachments"
        class="grid gap-3"
      >
        <li
          :for={item <- @items}
          id={item.id}
          data-media-id={item.video && item.video.media_id}
          class="grid gap-2 rounded-md border p-3"
        >
          <p class="text-sm">
            <strong id={"#{item.id}-name"}>{item.name}</strong>
            <span :if={item.size}>· {item.size}</span>
          </p>
          <p
            :if={item.note}
            id={"#{item.id}-note"}
            data-video-interrupted={item.video && item.video.resume}
            class="text-sm text-muted-foreground"
          >
            {item.note}
          </p>
          <span
            :if={item.video}
            id={"#{item.id}-transfer"}
            phx-update="ignore"
            data-video-transfer={item.video.media_id}
            class="text-sm"
          ></span>
          <p :if={item.video && item.video.checking} class="text-sm text-muted-foreground">
            Still checking
          </p>
          <p :for={error <- item.errors} class="text-sm font-medium text-destructive">{error}</p>
          <div :if={item.slot} class="grid gap-1">
            <label for={"#{item.id}-description"} class="text-sm font-medium">
              Image description (optional)
            </label>
            <input
              type="text"
              id={"#{item.id}-description"}
              name={"image_descriptions[#{item.slot}]"}
              value={item.description}
              class="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-base focus-visible:border-ring disabled:cursor-not-allowed disabled:opacity-50"
            />
          </div>
          <p :if={!item.slot && item.description} class="text-sm">
            Description: {item.description}
          </p>
          <div class="flex flex-wrap gap-2">
            <TipsWeb.UI.button
              :if={item.video && item.video.resume}
              type="button"
              variant="outline"
              data-video-resume={item.video.media_id}
              aria-describedby={"#{item.id}-note"}
            >
              Resume
            </TipsWeb.UI.button>
            <TipsWeb.UI.button
              :if={item.video && item.video.replace}
              type="button"
              variant="outline"
              phx-click="remove_attachment"
              {item.remove}
              aria-describedby={"#{item.id}-name"}
            >
              Replace
            </TipsWeb.UI.button>
            <TipsWeb.UI.button
              type="button"
              variant="outline"
              phx-click="remove_attachment"
              {item.remove}
              aria-describedby={"#{item.id}-name"}
            >
              Remove
            </TipsWeb.UI.button>
          </div>
        </li>
      </ol>
      <div class="grid gap-1">
        <label for={@upload.ref} class="text-sm font-medium">Add an image (optional)</label>
        <.live_file_input
          upload={@upload}
          aria-describedby={"#{@id}-image-help"}
          aria-invalid={@invalid}
          class="text-sm"
        />
        <p id={"#{@id}-image-help"} class="text-sm text-muted-foreground">
          PNG, JPEG, WebP or GIF up to 10 MB.
        </p>
        <p
          :for={error <- upload_errors(@upload)}
          class="text-sm font-medium text-destructive"
        >
          {file_error(error)}
        </p>
      </div>
      <%!-- Stays in the page while a video is selected: Resume reopens it. --%>
      <div id={"#{@id}-video-input"} class="grid gap-1" hidden={@staged}>
        <label for={@video_upload.ref} class="text-sm font-medium">Add a video (optional)</label>
        <.live_file_input
          upload={@video_upload}
          aria-describedby={"#{@id}-video-help"}
          class="text-sm"
        />
        <p id={"#{@id}-video-help"} class="text-sm text-muted-foreground">
          MP4, MOV or WebM up to 1 GB and 3 minutes. It uploads while you write.
        </p>
        <p :for={error <- @video_errors} class="text-sm font-medium text-destructive">{error}</p>
      </div>
    </TipsWeb.UI.disclosure>
    """
  end

  defp summary(0), do: "Prompt and result"
  defp summary(1), do: "Prompt and result · 1 attachment"
  defp summary(count), do: "Prompt and result · #{count} attachments"

  defp attachment_item({:missing_image, slot, image}, assigns, entries, _video_errors) do
    entry = entries[assigns.images[slot]]
    id = "#{assigns.id}-image-#{slot}"

    %{
      id: id,
      slot: slot,
      name: image.filename,
      size: size(image.size),
      description: image.description,
      note: if(entry, do: nil, else: "Select this image again to attach it."),
      errors:
        Enum.map(entry_errors(assigns.upload, entry), &"#{image.filename} #{file_error(&1)}.") ++
          submit_errors(assigns.form, image.filename, slot: slot),
      remove: ["phx-value-slot": slot],
      video: nil
    }
  end

  defp attachment_item({:retained, media_id, description}, assigns, _entries, _video_errors) do
    name =
      case assigns.attached[media_id] do
        :image -> "Saved image"
        :video -> "Saved video"
        nil -> "Saved attachment"
      end

    %{
      id: "#{assigns.id}-media-#{media_id}",
      slot: nil,
      name: name,
      size: nil,
      description: description,
      note: nil,
      errors: submit_errors(assigns.form, name, media_id: media_id),
      remove: ["phx-value-media_id": media_id],
      video: nil
    }
  end

  # A rejected selection, such as a resume with another file, shows at the slot.
  defp attachment_item({:staged_video, media_id}, assigns, _entries, video_errors) do
    status = assigns.video_states[media_id]
    live? = live_video_entry(assigns.video_upload, assigns.video_refs, media_id) != nil
    {note, actions} = video_slot(status, live?)

    %{
      id: "#{assigns.id}-video-#{media_id}",
      slot: nil,
      name: "Video",
      size: nil,
      description: nil,
      note: note,
      errors: video_errors ++ submit_errors(assigns.form, "Video", media_id: media_id),
      remove: ["phx-value-video": media_id],
      video: %{
        media_id: media_id,
        resume: :resume in actions,
        replace: :replace in actions,
        checking: status != nil and status.refresh in [:uncertain, :rate_limited]
      }
    }
  end

  # The slot's note and actions besides Remove, from the committed state and
  # whether this page is transferring the file.
  defp video_slot(nil, _live?), do: {"Checking this video.", []}

  defp video_slot(%{state: :removed}, _live?),
    do: {"This video is no longer available.", [:replace]}

  defp video_slot(status, live?) do
    if expired?(status),
      do: {"This upload expired.", [:replace]},
      else: committed_slot(status, live?)
  end

  defp committed_slot(%{state: :uploading}, true), do: {nil, []}

  defp committed_slot(%{state: :uploading}, false),
    do: {"Upload interrupted. Select the same file to resume.", [:resume]}

  defp committed_slot(%{state: :processing}, _live?), do: {"Processing", []}
  defp committed_slot(%{state: :ready, expires_at: nil}, _live?), do: {"Ready", []}

  defp committed_slot(%{state: :ready, expires_at: expires_at}, _live?),
    do: {"Ready. Publish by #{deadline(expires_at)}.", []}

  defp committed_slot(%{state: :failed}, _live?),
    do: {"Couldn't be processed. Videos must be under 3 minutes.", [:replace]}

  defp deadline(expires_at), do: Calendar.strftime(expires_at, "%-d %b %Y, %H:%M UTC")

  defp video_errors(upload) do
    for error <-
          upload_errors(upload) ++ Enum.flat_map(upload.entries, &upload_errors(upload, &1)) do
      video_file_error(error)
    end
  end

  defp video_file_error({:external_metadata_failure, %{reason: message}}), do: message
  defp video_file_error(:too_large), do: "The video is larger than 1 GB."
  defp video_file_error(:not_accepted), do: "The video is not an MP4, MOV or WebM file."
  defp video_file_error(:too_many_files), do: "Remove the selected video before adding another."

  defp video_file_error(:external_client_failure),
    do: "The video couldn't be uploaded. Select it again."

  defp entry_errors(_upload, nil), do: []
  defp entry_errors(upload, entry), do: upload_errors(upload, entry)

  defp submit_errors(form, name, [{key, value}]) do
    for {:uploads, {_message, keys} = error} <- form.errors, keys[key] == value do
      "#{name} #{CoreComponents.translate_error(error)}."
    end
  end

  defp file_error(:too_large), do: "is larger than 10 MB"
  defp file_error(:not_accepted), do: "is not a PNG, JPEG, WebP or GIF"
  defp file_error(:too_many_files), do: "Remove the selected image before adding another."

  defp file_error({:writer_failure, _reason}),
    do: "could not be uploaded. Remove it and select it again"

  defp size(bytes) when bytes < 1_000_000, do: "#{max(div(bytes, 1000), 1)} KB"
  defp size(bytes), do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  @doc """
  Renders the error summary of the last refused submit: one link per error,
  to its field. The hook focuses it and opens the evidence disclosure around
  a linked field.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :identity, :map, required: true

  def error_summary(assigns) do
    kind = kind(assigns.identity.target)
    order = fields(kind) |> Enum.with_index() |> Map.new()

    errors =
      assigns.form.errors
      |> Enum.sort_by(fn {field, _error} -> Map.get(order, field, map_size(order)) end)
      |> Enum.map(fn {field, error} ->
        {field_id(kind, field, assigns.identity),
         "#{label(kind, field)}: #{CoreComponents.translate_error(error)}"}
      end)

    assigns = assign(assigns, :errors, errors)

    ~H"""
    <TipsWeb.UI.error_summary id={"#{form_id(@identity)}-errors"} errors={@errors} />
    """
  end

  defp field_id(kind, field, identity) do
    if field in fields(kind), do: "#{kind}_#{field}", else: "#{form_id(identity)}-fields"
  end

  defp label(:tip, :body), do: "Tip"
  defp label(:review, :body), do: "Review"
  defp label(_kind, :title), do: "Title"
  defp label(_kind, :tag_id), do: "Technique"
  defp label(_kind, :model_id), do: "Model"
  defp label(_kind, :model_other), do: "Model name"
  defp label(_kind, :environment_id), do: "Environment"
  defp label(_kind, :prompt), do: "Prompt"
  defp label(_kind, :output), do: "Result text"
  defp label(_kind, :uploads), do: "Attachments"
  defp label(_kind, field), do: Phoenix.Naming.humanize(field)

  @doc """
  Renders the saved version of an edit whose outcome was unknown, beside the
  author's proposal.
  """
  attr :identity, :map, required: true
  attr :saved, :map, default: nil, doc: "the saved `t:Tips.Content.attrs/0`"
  attr :choices, :map, required: true, doc: "`Tips.Content.list_filter_choices/0`"

  def saved_version(assigns) do
    kind = kind(assigns.identity.target)

    rows =
      for field <- fields(kind) -- [:model_other],
          value = shown(field, assigns.saved || %{}, assigns.choices),
          value != nil,
          do: {label(kind, field), value}

    assigns = assign(assigns, :rows, rows)

    ~H"""
    <section
      :if={@saved}
      id={"#{form_id(@identity)}-saved"}
      aria-labelledby={"#{form_id(@identity)}-saved-title"}
      class="grid gap-3 rounded-md border p-4"
    >
      <h2 id={"#{form_id(@identity)}-saved-title"} class="font-semibold">Saved version</h2>
      <dl class="grid gap-2">
        <div :for={{label, value} <- @rows}>
          <dt class="text-sm text-muted-foreground">{label}</dt>
          <dd class="whitespace-pre-wrap">{value}</dd>
        </div>
      </dl>
    </section>
    """
  end

  defp shown(:model_id, %{model_other: other}, _choices) when other not in [nil, ""], do: other
  defp shown(field, saved, choices), do: choice(field, Map.get(saved, field), choices)

  defp choice(_field, value, _choices) when value in [nil, ""], do: nil

  defp choice(field, value, choices) when field in [:tag_id, :model_id, :environment_id] do
    list =
      Map.fetch!(
        choices,
        %{tag_id: :tags, model_id: :models, environment_id: :environments}[field]
      )

    Enum.find_value(list, value, &(&1.id == value && &1.label))
  end

  defp choice(_field, value, _choices), do: value

  @doc """
  Renders the draft status line, which the hook writes, the "Reload saved
  draft" button the hook shows while autosave is paused, the refusal or
  confirmation of the last submit, and the submit button. While a
  submission is unresolved, the button retries it or is disabled until it
  is checked again. While a selected video holds it (`publish_wait/2`), the
  button is disabled with the reason beside it.
  """
  attr :identity, :map, required: true
  attr :submit, :string, required: true
  attr :refusal, :map, default: nil
  attr :outcome, :string, default: nil
  attr :pending, :atom, default: nil
  attr :wait, :atom, default: nil, doc: "`publish_wait/2`"

  def editor_bar(assigns) do
    ~H"""
    <div class="grid gap-3 border-t pt-4">
      <p
        id={"#{form_id(@identity)}-status"}
        role="status"
        phx-update="ignore"
        class="min-h-5 text-sm text-muted-foreground"
      >
      </p>
      <div>
        <TipsWeb.UI.button id={"#{form_id(@identity)}-reload"} type="button" variant="outline" hidden>
          Reload saved draft
        </TipsWeb.UI.button>
      </div>
      <TipsWeb.UI.notice
        :if={@refusal}
        id={"#{form_id(@identity)}-refusal"}
        tone="error"
        role="alert"
      >
        {@refusal.message} Your text stays on this page.
        <:actions :if={@refusal.sign_in || @refusal.check || @refusal.view}>
          <a :if={@refusal.sign_in} href={@refusal.sign_in}>Sign in</a>
          <TipsWeb.UI.button
            :if={@refusal.check}
            type="button"
            variant="outline"
            phx-click="editor:reconcile"
          >
            Check again
          </TipsWeb.UI.button>
          <a :if={@refusal.view} href={@refusal.view}>View it</a>
        </:actions>
      </TipsWeb.UI.notice>
      <p id={"#{form_id(@identity)}-outcome"} role="status" class="text-sm font-medium">
        {@outcome}
      </p>
      <div class="grid gap-2">
        <div>
          <TipsWeb.UI.button
            type="submit"
            size="lg"
            disabled={@pending in [:unchecked, :signed_out] or @wait != nil}
            aria-describedby={@wait && "#{form_id(@identity)}-wait"}
          >
            {if @pending == :absent, do: "Retry", else: @submit}
          </TipsWeb.UI.button>
        </div>
        <p :if={@wait} id={"#{form_id(@identity)}-wait"} class="text-sm text-muted-foreground">
          {wait(@wait)}
        </p>
      </div>
    </div>
    """
  end

  defp wait(:pending), do: "Waiting for your video to be ready"
  defp wait(:expired), do: "This video expired. Replace or remove it."

  defp kind(:new_tip), do: :tip
  defp kind({:new_review, _tip_id}), do: :review
  defp kind({:edit, kind, _id}), do: kind

  ## Form values

  # The model select holds a curated id, "" for none, or "other" with the
  # typed name beside it; attrs hold `model_id` or `model_other`.
  defp form_params(kind, attrs) do
    params = Map.new(fields(kind), &{Atom.to_string(&1), Map.get(attrs, &1) || ""})

    case attrs do
      %{model_other: other} when is_binary(other) -> %{params | "model_id" => "other"}
      _ -> params
    end
  end

  # A field the event left out keeps its current value.
  defp typed_attrs(kind, params, current) when is_map(params) do
    attrs =
      Map.new(fields(kind), fn field ->
        case params[Atom.to_string(field)] do
          value when is_binary(value) -> {field, value}
          _ -> {field, Map.get(current, field)}
        end
      end)

    case Map.fetch(params, "model_id") do
      {:ok, "other"} -> %{attrs | model_id: nil, model_other: text_or(params["model_other"], "")}
      {:ok, _model_id} -> %{attrs | model_other: nil}
      :error -> attrs
    end
  end

  defp typed_attrs(_kind, _params, current), do: current

  defp text_or(value, _default) when is_binary(value), do: value
  defp text_or(_value, default), do: default

  ## JSON, as in assets/js/editor_contract.js

  defp identity_json(%{account_id: account_id, target: target}),
    do: %{"account_id" => account_id, "target" => target_json(target)}

  defp storage_json(%{account_id: account_id, slot: slot}),
    do: %{"account_id" => account_id, "slot" => target_json(slot)}

  defp record_json(record) do
    %{
      "storage" => storage_json(record.storage),
      "draft" => %{"draft_id" => record.draft.draft_id, "revision" => record.draft.revision},
      "mode" => Atom.to_string(record.mode),
      "target" => target_json(record.target),
      "submission_key" => record.submission_key,
      "intent" => intent_json(record.intent),
      "base" => record.base && intent_json(record.base),
      "expected_version" => record.expected_version
    }
  end

  defp target_json(:new_tip), do: %{"tag" => "new_tip"}
  defp target_json({:new_review, tip_id}), do: %{"tag" => "new_review", "tip_id" => tip_id}

  defp target_json({:edit, kind, id}),
    do: %{"tag" => "edit", "kind" => Atom.to_string(kind), "id" => id}

  defp intent_json(%{attrs: attrs, uploads: uploads}) do
    %{
      "attrs" => Map.new(attrs, fn {field, value} -> {Atom.to_string(field), value} end),
      "uploads" => uploads && Enum.map(uploads, &media_json/1)
    }
  end

  defp media_json({:retained, media_id, description}),
    do: %{"tag" => "retained", "media_id" => media_id, "description" => description}

  defp media_json({:staged_video, media_id}),
    do: %{"tag" => "staged_video", "media_id" => media_id}

  defp media_json({:missing_image, slot, image}) do
    %{
      "tag" => "missing_image",
      "slot" => slot,
      "filename" => image.filename,
      "type" => image.type,
      "size" => image.size,
      "description" => image.description
    }
  end

  # Decodes a record with the store's rules (`copyRecord` in
  # assets/js/editor_draft_store.js): exact keys, one kind throughout, and a
  # new record only in its own new slot.
  defp decode_record(
         %{
           "storage" => storage,
           "draft" => draft,
           "mode" => mode,
           "target" => target,
           "submission_key" => key,
           "intent" => intent,
           "base" => base,
           "expected_version" => version
         } = json
       )
       when map_size(json) == 8 do
    with {:ok, storage} <- decode_storage(storage),
         {:ok, target} <- decode_target(target),
         kind = kind(target),
         true <- kind(storage.slot) == kind,
         {:ok, mode} <- decode_mode(mode, target, storage.slot),
         {:ok, draft} <- decode_draft(draft),
         {:ok, key} <- optional(key, &uuid/1),
         {:ok, intent} <- decode_intent(intent, kind),
         {:ok, base} <- optional(base, &decode_intent(&1, kind)),
         {:ok, version} <- optional(version, &positive/1) do
      {:ok,
       %{
         storage: storage,
         draft: draft,
         mode: mode,
         target: target,
         submission_key: key,
         intent: intent,
         base: base,
         expected_version: version
       }}
    else
      _ -> :error
    end
  end

  defp decode_record(_json), do: :error

  defp decode_storage(%{"account_id" => account_id, "slot" => slot} = json)
       when map_size(json) == 2 do
    with {:ok, account_id} <- positive(account_id),
         {:ok, slot} <- decode_target(slot),
         do: {:ok, %{account_id: account_id, slot: slot}}
  end

  defp decode_storage(_json), do: :error

  defp decode_target(%{"tag" => "new_tip"} = json) when map_size(json) == 1, do: {:ok, :new_tip}

  defp decode_target(%{"tag" => "new_review", "tip_id" => tip_id} = json)
       when map_size(json) == 2 do
    with {:ok, tip_id} <- positive(tip_id), do: {:ok, {:new_review, tip_id}}
  end

  defp decode_target(%{"tag" => "edit", "kind" => kind, "id" => id} = json)
       when map_size(json) == 3 and is_map_key(@kinds, kind) do
    with {:ok, id} <- positive(id), do: {:ok, {:edit, @kinds[kind], id}}
  end

  defp decode_target(_json), do: :error

  # A new record lives in its own new slot. An edit record lives in its own
  # edit slot, or in a new slot after a handoff.
  defp decode_mode("new", {:edit, _kind, _id}, _slot), do: :error
  defp decode_mode("new", target, target), do: {:ok, :new}
  defp decode_mode("edit", {:edit, _kind, _id} = target, target), do: {:ok, :edit}
  defp decode_mode("edit", {:edit, _kind, _id}, :new_tip), do: {:ok, :edit}
  defp decode_mode("edit", {:edit, _kind, _id}, {:new_review, _tip_id}), do: {:ok, :edit}
  defp decode_mode(_mode, _target, _slot), do: :error

  defp decode_draft(%{"draft_id" => draft_id, "revision" => revision} = json)
       when map_size(json) == 2 and is_binary(draft_id) and draft_id != "" and
              is_integer(revision) and revision >= 0,
       do: {:ok, %{draft_id: draft_id, revision: revision}}

  defp decode_draft(_json), do: :error

  defp decode_intent(%{"attrs" => attrs, "uploads" => uploads} = json, kind)
       when map_size(json) == 2 and is_map(attrs) do
    names = Map.new(fields(kind), &{Atom.to_string(&1), &1})

    with true <-
           Enum.all?(attrs, fn {name, value} -> is_map_key(names, name) and text?(value) end),
         {:ok, uploads} <- optional(uploads, &decode_uploads/1) do
      {:ok,
       %{attrs: Map.new(attrs, fn {name, value} -> {names[name], value} end), uploads: uploads}}
    else
      _ -> :error
    end
  end

  defp decode_intent(_json, _kind), do: :error

  defp decode_uploads([]), do: {:ok, []}

  defp decode_uploads([json | rest]) do
    with {:ok, media} <- decode_media(json),
         {:ok, rest} <- decode_uploads(rest),
         do: {:ok, [media | rest]}
  end

  defp decode_uploads(_json), do: :error

  defp decode_media(%{"tag" => "retained", "media_id" => id, "description" => description} = json)
       when map_size(json) == 3 do
    with {:ok, id} <- positive(id),
         true <- text?(description),
         do: {:ok, {:retained, id, description}}
  end

  defp decode_media(%{"tag" => "staged_video", "media_id" => id} = json)
       when map_size(json) == 2 do
    with {:ok, id} <- positive(id), do: {:ok, {:staged_video, id}}
  end

  defp decode_media(
         %{
           "tag" => "missing_image",
           "slot" => slot,
           "filename" => filename,
           "type" => type,
           "size" => size,
           "description" => description
         } = json
       )
       when map_size(json) == 6 and is_binary(slot) and is_binary(filename) and is_binary(type) and
              is_integer(size) and size >= 0 do
    if text?(description),
      do:
        {:ok,
         {:missing_image, slot,
          %{filename: filename, type: type, size: size, description: description}}},
      else: :error
  end

  defp decode_media(_json), do: :error

  defp optional(nil, _decode), do: {:ok, nil}
  defp optional(value, decode), do: decode.(value)

  defp positive(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive(_value), do: :error

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> {:ok, value}
      _ -> :error
    end
  end

  defp text?(value), do: is_nil(value) or is_binary(value)
end
