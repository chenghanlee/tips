defmodule Tips.Content.Moderation do
  @moduledoc """
  Reports, moderation cases and guarded hide/restore for `Tips.Content`.

  See "Reporting" and "Deletion and moderation" in `Tips.Content`. A report
  locks the reporter, then only its direct target `FOR SHARE`, so author
  deletion and hiding either wait for it and see the report, or commit first
  and make it fail. A case is read in one short
  repeatable-read transaction, so its content, media, version and open reports
  come from one snapshot. Hide and restore lock the moderator, then the tip,
  then the review (`Tips.Content.Deletion`), and compare the version and the
  reviewed reports the moderator saw before changing `dead_at`.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Tips.Accounts
  alias Tips.Accounts.{Scope, User}
  alias Tips.Content.{Deletion, Flag, Publication, Read}
  alias Tips.Repo

  require Logger

  # Positive bigint ids; anything else cannot name a row.
  @row_ids 1..9_223_372_036_854_775_807

  @doc "See `Tips.Content.get_moderation_case/3`."
  @spec get_case(term(), term(), term()) ::
          {:ok, Tips.Content.moderation_case()}
          | {:error, :unauthenticated | :forbidden | :not_found | :outcome_unknown}
  def get_case(session_ref, kind, id) do
    unknown_on_database_error(fn ->
      with {:ok, scope} <- Accounts.readmit_scope(session_ref),
           :ok <- moderator(scope),
           {:ok, kind} <- Deletion.kind(kind),
           {:ok, id} <- read_id(id) do
        snapshot(scope, kind, id)
      end
    end)
  end

  @doc "See `Tips.Content.hide_content/5` and `Tips.Content.restore_content/5`."
  @spec moderate(:hide | :restore, Scope.t() | nil, term(), term(), term(), term()) ::
          {:ok, Tips.Content.lifecycle_receipt()} | {:error, Tips.Content.moderation_error()}
  def moderate(action, scope, kind, id, expected_version, report_ids) do
    unknown_on_database_error(fn ->
      with {:ok, user} <- Deletion.actor(scope),
           :ok <- Publication.admit(scope),
           {:ok, kind} <- Deletion.kind(kind),
           {:ok, id} <- Deletion.write_id(id),
           :ok <- validate(expected_version, report_ids) do
        action
        |> save(kind, user.id, id, expected_version, report_ids)
        |> settle(kind, user.id, id)
      end
    end)
  end

  @doc "See `Tips.Content.report_content/4`."
  @spec report(Scope.t() | nil, term(), term(), map()) ::
          {:ok, Tips.Content.report_receipt()} | {:error, Tips.Content.report_error()}
  def report(scope, kind, id, attrs) do
    unknown_on_database_error(fn ->
      with {:ok, user} <- Deletion.actor(scope),
           :ok <- Publication.admit(scope),
           {:ok, kind} <- Deletion.kind(kind),
           {:ok, id} <- Deletion.write_id(id),
           {:ok, changeset} <- report_changeset(kind, user.id, id, attrs) do
        changeset
        |> store(kind, user.id, id)
        |> settle_report(kind, user.id, id)
      end
    end)
  end

  ## Report

  defp report_changeset(kind, user_id, id, attrs) do
    changeset =
      %Flag{user_id: user_id}
      |> Map.put(Deletion.key(kind), id)
      |> Flag.report_changeset(attrs)

    if changeset.valid?, do: {:ok, changeset}, else: {:error, %{changeset | action: :insert}}
  end

  defp store(changeset, kind, user_id, id) do
    Repo.transact(fn ->
      with :ok <- Deletion.lock_account(user_id, :contribute),
           :ok <- share_reportable(kind, id) do
        Repo.insert(changeset)
      end
    end)
  end

  # Only the direct target, never a review's parent tip. Hidden and deleted
  # content cannot be reported, as its capabilities say.
  defp share_reportable(kind, id) do
    reportable =
      from(c in Deletion.schema(kind),
        where: c.id == ^id and is_nil(c.deleted_at) and is_nil(c.dead_at),
        lock: "FOR SHARE",
        select: c.id
      )

    if Repo.one(reportable), do: :ok, else: {:error, :not_found}
  end

  defp settle_report({:ok, flag}, kind, _user_id, id),
    do: {:ok, report_receipt(kind, id, flag.id, :stored)}

  # Validation passed, so a rejected insert is the one-open-report index.
  defp settle_report({:error, %Ecto.Changeset{}}, kind, user_id, id),
    do: open_receipt(kind, user_id, id)

  defp settle_report({:error, _reason} = error, _kind, _user_id, _id), do: error

  # The insert rolled back. The lock waits for a resolution in progress, so the
  # receipt is the open report's actual state. If that report was resolved,
  # this submission stored nothing and there is no receipt to give.
  defp open_receipt(kind, user_id, id) do
    open =
      from(f in Flag,
        where:
          f.user_id == ^user_id and field(f, ^Deletion.key(kind)) == ^id and
            is_nil(f.resolved_at),
        lock: "FOR SHARE",
        select: f.id
      )

    case Repo.one(open) do
      nil -> {:error, :outcome_unknown}
      report_id -> {:ok, report_receipt(kind, id, report_id, :already_open)}
    end
  end

  defp report_receipt(kind, id, report_id, outcome),
    do: %{kind: kind, id: id, report_id: report_id, outcome: outcome}

  ## Case read

  # Readmission proves the account is current and undeleted. Reading a case needs
  # only the role: a full ban or missing confirmation stops actions, not reads.
  defp moderator(%Scope{user: %User{role: :moderator}}), do: :ok
  defp moderator(_scope), do: {:error, :forbidden}

  defp read_id(value) do
    case Ecto.Type.cast(:id, value) do
      {:ok, id} when id in @row_ids -> {:ok, id}
      _invalid -> {:error, :not_found}
    end
  end

  defp snapshot(scope, kind, id) do
    Repo.transact(fn ->
      Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")

      case Repo.get(Deletion.schema(kind), id) do
        nil -> {:error, :not_found}
        row -> {:ok, moderation_case(scope, kind, row)}
      end
    end)
  end

  defp moderation_case(scope, kind, row) do
    %{
      kind: kind,
      id: row.id,
      tip_id: Deletion.tip_id(row),
      state: Deletion.state(row),
      edit_version: row.edit_version,
      content: Read.project(scope, row),
      reports: open_reports(kind, row.id)
    }
  end

  # Reporter identity stays out of the case.
  defp open_reports(kind, id) do
    Repo.all(
      from(f in Flag,
        where: field(f, ^Deletion.key(kind)) == ^id and is_nil(f.resolved_at),
        order_by: [f.created_at, f.id],
        select: %{id: f.id, reason: f.reason, detail: f.detail, created_at: f.created_at}
      )
    )
  end

  ## Hide and restore

  defp validate(expected_version, report_ids) do
    changeset =
      {%{}, %{edit_version: :integer, reviewed_report_ids: {:array, :integer}}}
      |> change()
      |> validate_version(expected_version)
      |> validate_report_ids(report_ids)

    if changeset.valid?, do: :ok, else: {:error, %{changeset | action: :update}}
  end

  defp validate_version(changeset, version) when is_integer(version) and version > 0,
    do: changeset

  defp validate_version(changeset, _version),
    do: add_error(changeset, :edit_version, "is invalid")

  defp validate_report_ids(changeset, ids) when is_list(ids) do
    if Enum.all?(ids, &(is_integer(&1) and &1 in @row_ids)) and
         length(Enum.uniq(ids)) == length(ids),
       do: changeset,
       else: add_error(changeset, :reviewed_report_ids, "is invalid")
  end

  defp validate_report_ids(changeset, _ids),
    do: add_error(changeset, :reviewed_report_ids, "is invalid")

  defp save(action, kind, user_id, id, expected_version, report_ids) do
    Repo.transact(fn ->
      with :ok <- Deletion.lock_account(user_id, :moderate),
           {:ok, row} <- Deletion.lock_target(kind, id),
           :ok <- check_current(kind, row, expected_version, report_ids) do
        apply_action(action, kind, row, user_id, report_ids)
      end
    end)
  end

  # Deleted content cannot be hidden or restored. The version and every reviewed
  # report must be as the moderator saw them; later reports are not compared.
  defp check_current(_kind, %{deleted_at: %DateTime{}}, _version, _ids), do: {:error, :conflict}

  defp check_current(kind, %{edit_version: version} = row, version, ids) do
    open =
      Repo.aggregate(
        from(f in Flag,
          where:
            f.id in ^ids and field(f, ^Deletion.key(kind)) == ^row.id and is_nil(f.resolved_at)
        ),
        :count
      )

    if open == length(ids), do: :ok, else: {:error, :conflict}
  end

  defp check_current(_kind, _row, _version, _ids), do: {:error, :conflict}

  defp apply_action(:hide, _kind, %{dead_at: %DateTime{}} = row, _user_id, _ids),
    do: {:ok, {:unchanged, row}}

  # Hiding resolves exactly the reviewed reports.
  defp apply_action(:hide, kind, row, user_id, ids) do
    Repo.update_all(from(f in Flag, where: f.id in ^ids),
      set: [resolved_at: now(), resolved_by: user_id]
    )

    {:ok, {:changed, Deletion.update_row!(kind, row.id, set: [dead_at: now()])}}
  end

  defp apply_action(:restore, _kind, %{dead_at: nil} = row, _user_id, _ids),
    do: {:ok, {:unchanged, row}}

  defp apply_action(:restore, kind, row, _user_id, _ids),
    do: {:ok, {:changed, Deletion.update_row!(kind, row.id, set: [dead_at: nil])}}

  defp settle({:ok, {outcome, row}}, kind, _user_id, _id),
    do: {:ok, Deletion.receipt(kind, row, outcome)}

  defp settle({:error, :conflict}, kind, user_id, id), do: recover(kind, user_id, id)
  defp settle({:error, _reason} = error, _kind, _user_id, _id), do: error

  # The attempt rolled back. A fresh snapshot shows the moderator the current case,
  # unless they may no longer act.
  defp recover(kind, user_id, id) do
    with {:ok, user} <- current_user(user_id),
         :ok <- Accounts.check_eligibility(user, :moderate),
         {:ok, current} <- snapshot(Scope.for_user(user), kind, id) do
      {:error, {:conflict, current}}
    end
  end

  defp current_user(id) do
    case Repo.get(User, id) do
      nil -> {:error, :unauthenticated}
      user -> {:ok, user}
    end
  end

  defp now, do: DateTime.utc_now(:second)

  # A database error or lost connection leaves the outcome unknown, never rejected.
  defp unknown_on_database_error(fun) do
    fun.()
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.error("Moderation outcome unknown: #{database_reason(error)}")
      {:error, :outcome_unknown}
  end

  # Postgres details can quote stored values; log only the code and message.
  defp database_reason(%Postgrex.Error{postgres: %{code: code, message: message}}),
    do: "#{code}: #{message}"

  defp database_reason(error), do: Exception.message(error)
end
