defmodule Tips.Accounts.SessionRef do
  @moduledoc """
  Server-private reference to the session row that admitted a LiveView.

  It holds the `users_tokens` row id and the mounted user id, never the bearer
  token. Only Accounts creates it, from a session token it has just verified
  (`get_scope_by_session_token/1`, #47). Re-admission (`readmit_scope/1`, #47)
  queries that row, binds both ids and applies the session validity definition.

  This struct is not a security proof. Never build it from request, event or
  job payloads. Keep it out of render assigns, templates, events, public
  projections and logs. It deliberately has no JSON encoder.
  """

  @enforce_keys [:token_id, :user_id]
  defstruct [:token_id, :user_id]

  @opaque t :: %__MODULE__{token_id: pos_integer(), user_id: pos_integer()}
end
