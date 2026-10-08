# State and failure

Read the applicable sections at the retrieval points in the [engineering map](../SKILL.md#when-to-read).

## Handle state and failure

### Incoming actions

Parse and validate untrusted input into a defined internal representation at the
receiving boundary; reuse schema or SDK guarantees where they establish the needed
contract. Do not spread guesses about data shapes through downstream code.
Authorize the action where it is received, even if mount, an earlier step or another
layer already checked. Earlier checks may be stale when the action runs.

### State, resources and delayed work

Identify where the affected state can change and which transitions could break the
requirement. Establish who owns each resource, who releases it and what survives
the caller's exit.

- Do not release capacity while the work it bounds still runs. Cancellation
  requested does not mean work has stopped.
- Before applying a result, establish that it still belongs to the current operation.
  A read started before reconnect must not overwrite newer input.
- Revalidate delayed or retried actions when their inputs or permissions may have
  changed. Refresh or reject permanently invalid inputs rather than offering a
  retry that cannot succeed.
- Record completion only when the required work is done. Reuse production's success
  decision; cleanup running is not evidence of success.
- When adding or changing a timeout, retry, deadline, quota or resource limit: bound
  the whole operation. Add up sequential work, retries, queueing, cleanup and work
  that outlives the caller; a per-step timeout does not bound the operation.
- For a shared deadline, quota or concurrency limit, define which results stop new
  work and what happens to work already in progress.

### Fallible boundaries

Check relevant returns, exceptions, exits, timeouts, partial effects and required
response fields. Handle each failure at the layer responsible for its recovery,
preserving the distinctions that change recovery. Add a branch only when it changes
the required response or recovery; otherwise let the existing error boundary handle
it, after confirming it gives the needed behavior. Do not disguise an unexpected
failure as a default value.

Every affected caller must handle or propagate a new result shape. An unmatched
error can become a crash or the wrong response. Do not report "not found", "invalid
input" or "success" unless the contract permits it.

Before retrying or rolling back, establish what may already have committed and what
evidence can settle an uncertain outcome. No response does not prove failure; a
local rollback does not undo an external effect.
