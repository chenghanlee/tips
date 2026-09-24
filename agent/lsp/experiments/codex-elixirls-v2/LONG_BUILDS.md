# Long-build and failure contract

The current stack remains provisional. These rules define the behavior against
which its operational fixes and the proposed plain-Mix alternative are tested.

- Neovim registration makes MCP available. Compilation is not a startup gate.
- A changed-source hook waits at most five seconds in total, including scanning,
  batching, and RPC. It returns diagnostics when available, otherwise pending or
  an explicit synchronization/unavailability error. Empty cached diagnostics are
  not proof that the edited source compiled successfully.
- Reaching the feedback deadline does not cancel ElixirLS. Its existing pending
  and in-flight sets retain edits for subsequent incremental compilation.
- An unchanged eligible tool does not wait another five seconds. Its hook can
  deliver newly available diagnostics. Stop can spend one further bounded wait
  on outstanding feedback. There is no unsolicited asynchronous message.
- If Stop still reports pending, the agent must describe validation as unfinished.
  Repeating Stop must not trap the agent in an unlimited wait loop. Ending the
  session terminates its compiler; unfinished compilation is not successful validation.
- Each launcher owns one specific Neovim instance. Its death makes the session
  unavailable; neither MCP nor a hook silently adopts a replacement at the same root.
- Source-observation failure must not erase a received build-completion event.
  Report a retryable synchronization error, preserve queued changes, and recover
  on a successful scan without requiring another edit.
- Shutdown has a bounded process cleanup path independent of Neovim RPC. Optional
  event recording must not keep the session alive.

## Why these are separate contracts

1. Why can a five-second hook return before a compiler result? Compilation can
   outlast the latency budget.
2. Why preserve that compilation? Killing every long build can prevent useful
   feedback from ever completing.
3. Why retain subsequent changes? The agent can edit again while it runs.
4. Why doesn't a later successful incremental build alone settle correctness?
   The reproduced Mix race can give an old artifact a newer source digest.
5. Why retain targeted invalidation? It supplies the tested recovery behavior for
   observed changes instead of assuming an additional no-op compile repairs them.
6. Why can't process replacement inherit readiness by root? A new process has
   none of the old session's observation or delivery history.
7. Why not wait on RPC during shutdown? A stopped peer cannot acknowledge it;
   process cleanup must remain possible precisely when the peer is unhealthy.

The last two questions reinforce the same boundaries: own the session lifetime,
bound feedback latency, and retain unfinished compiler work independently.

## Plain-Mix comparison

Evaluate a CLI compiler hook against these rules, not only warm compile timings.
Returning at the deadline while stock Mix continues has already reproduced stale
artifacts. A second candidate may terminate and reap its whole compiler process
tree at the deadline, then retry later; test long-build progress and partial-build
recovery. A third candidate may wait to completion, but that deliberately changes
the bounded-feedback rule. A larger finite budget changes frequency, not the
existence of this decision. CLI feedback does not by itself fix ElixirLS navigation.
