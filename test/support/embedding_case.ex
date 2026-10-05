defmodule Tips.EmbeddingCase do
  @moduledoc """
  Committed-row tests for embedding work run by real Oban instances.

  Oban executes jobs in its own processes, so the sandbox runs in auto mode:
  every write commits. Each test owns an author; cleanup deletes the author's
  tips, their reviews and reviewers, all search rows for them and every
  `EmbedSearch` job. Req.Test stubs are shared so Oban's processes reach them.
  """
  use ExUnit.CaseTemplate

  import Ecto.Query
  import ExUnit.Assertions

  alias Ecto.Adapters.SQL.Sandbox
  alias Tips.Accounts.User
  alias Tips.Content.{Review, Tip}
  alias Tips.Repo
  alias Tips.Workers.EmbedSearch

  using do
    quote do
      import Tips.AccountsFixtures
      import Tips.EmbeddingCase
      import Tips.SearchFixtures

      alias Tips.Repo
    end
  end

  setup do
    Sandbox.mode(Repo, :auto)
    Req.Test.set_req_test_to_shared()
    delete_jobs!()

    on_exit(fn ->
      Req.Test.set_req_test_to_private()
      Sandbox.mode(Repo, :manual)
    end)

    author = Tips.AccountsFixtures.user_fixture()
    on_exit(fn -> delete_owned!(author) end)
    %{author: author}
  end

  @doc "Starts a uniquely named Oban instance running only the embeddings queue."
  def start_oban!(opts \\ []) do
    name = {__MODULE__, System.unique_integer([:positive])}

    ExUnit.Callbacks.start_supervised!(
      {Oban,
       [
         name: name,
         repo: Repo,
         queues: [embeddings: 1],
         plugins: false,
         testing: :disabled,
         notifier: Oban.Notifiers.Isolated,
         peer: Oban.Peers.Isolated
       ] ++ opts},
      id: name
    )

    name
  end

  @doc "Inserts one scan tick into `oban`."
  def insert_scan(oban), do: Oban.insert(oban, EmbedSearch.new(%{}))

  @doc "Polls the committed job row until it reaches `state`, for at most five seconds."
  def await_state(job, state, attempts \\ 500) do
    case Repo.get!(Oban.Job, job.id) do
      %{state: ^state} ->
        :ok

      %{state: other} when attempts == 0 ->
        flunk("job #{job.id} is #{other}, expected #{state}")

      _not_yet ->
        Process.sleep(10)
        await_state(job, state, attempts - 1)
    end
  end

  defp delete_jobs! do
    Repo.delete_all(from(j in Oban.Job, where: j.worker == "Tips.Workers.EmbedSearch"))
  end

  defp delete_owned!(author) do
    delete_jobs!()
    tip_ids = Repo.all(from(t in Tip, where: t.user_id == ^author.id, select: t.id))
    reviews = Repo.all(from(r in Review, where: r.tip_id in ^tip_ids, select: {r.id, r.user_id}))
    {review_ids, reviewer_ids} = Enum.unzip(reviews)

    Repo.query!("DELETE FROM review_search WHERE review_id = ANY($1)", [review_ids])
    Repo.delete_all(from(r in Review, where: r.id in ^review_ids))
    Repo.query!("DELETE FROM tip_search WHERE tip_id = ANY($1)", [tip_ids])
    Repo.delete_all(from(t in Tip, where: t.id in ^tip_ids))
    Repo.delete_all(from(u in User, where: u.id in ^[author.id | reviewer_ids]))
  end
end
