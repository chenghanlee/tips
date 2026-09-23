defmodule Tips.Accounts.Scope do
  @moduledoc """
  The caller's current account identity, built by the server.

  `TipsWeb.UserAuth` builds a scope from the server-side session with
  `for_user/1`. Anonymous callers have a `nil` scope. A scope carries current
  account identity and state, not permission grants, bearer tokens or session
  row references. Operations check eligibility with
  `Tips.Accounts.check_eligibility/2` on the locked account row.

  Never build a scope from request params, LiveView events or job args, and
  never render or serialize it. See the "Admission contract" section of
  `Tips.Accounts`.
  """

  alias Tips.Accounts.User

  @enforce_keys [:user]
  defstruct [:user]

  @type t :: %__MODULE__{user: User.t()}

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  @spec for_user(User.t()) :: t()
  @spec for_user(nil) :: nil
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil
end
