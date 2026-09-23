defmodule Tips.Content.Visibility do
  @moduledoc """
  The one read-visibility decision for a tip or review.

  Every Content read that returns content to a caller decides through
  `decision/2` and then projects through `Tips.Content.Projection`.

  | Stored markers | Every viewer | Author or moderator | Others |
  |---|---|---|---|
  | `deleted_at` set (with or without `dead_at`) | `:deleted` | `:deleted` | `:deleted` |
  | only `dead_at` set | | `:visible` | `:removed` |
  | neither | `:visible` | `:visible` | `:visible` |

  Author deletion wins for everyone, including the author and moderators.
  A review's decision is independent of its parent tip.

  The privileged branch is a pure check on the scope it receives:

    * Only the current author or a moderator reads hidden content. A full ban
      does not revoke reading, and `Tips.Accounts.check_eligibility/2` is not a
      read guard.
    * A scope whose account is deleted gets no privileged visibility.
    * The caller must have freshly admitted that scope (see "Admission contract"
      in `Tips.Accounts`) and loaded the row in the current read. This function
      verifies no session, refreshes no row and grants nothing; an old search hit
      or cached struct is not authorization.
  """

  alias Tips.Accounts.{Scope, User}
  alias Tips.Content.{Review, Tip}

  @typedoc "Whether a viewer may read content, and why not."
  @type decision :: :visible | :removed | :deleted

  @typedoc "A tip or review row loaded in the current read."
  @type content :: %Tip{} | %Review{}

  @doc "Decides whether `scope` may read the current `tip` or `review` row."
  @spec decision(Scope.t() | nil, content()) :: decision()
  def decision(_scope, %module{deleted_at: %DateTime{}}) when module in [Tip, Review],
    do: :deleted

  def decision(_scope, %module{dead_at: nil}) when module in [Tip, Review], do: :visible

  def decision(scope, %module{} = content) when module in [Tip, Review] do
    if privileged?(scope, content), do: :visible, else: :removed
  end

  defp privileged?(%Scope{user: %User{deleted_at: nil, id: id}}, %{user_id: id}), do: true
  defp privileged?(%Scope{user: %User{deleted_at: nil, role: :moderator}}, _content), do: true
  defp privileged?(_scope, _content), do: false
end
