# Manual browser review

Clients launch with `MIX_ENV=test`, which runs tests but cannot serve a manual
browser session. Wait for `mix test` to exit before starting the app: both use
`$TIPS_TEST_PORT`. Start the app with:

```sh
MIX_ENV=dev unbuffer mix ecto.setup && MIX_ENV=dev PORT="$TIPS_TEST_PORT" unbuffer mix do assets.setup, assets.build, phx.server
```

Use `agent-browser` to test the app. Codex testers: start each browser session
with this exact command, replacing only `<name>`:

```sh
agent-browser open about:blank --session <name>
```

Run it alone: no `&&`, no shell variables, nothing before `open`. Any other form
can start Chrome inside the Codex sandbox and fail with `Chrome exited early`.
After it succeeds, use any `agent-browser` command. Repeat it after `close`.

Read mail at `/dev/mailbox`. The development
app calls real providers; test those scenarios only with the user's authorization
on the issue. Stop the server before handing off or notifying the dispatcher.

## Recover a failed browser launch

If `open` fails with `Chrome exited early` or `without writing DevToolsActivePort`,
the session may have a daemon started inside the Codex sandbox. Retrying `open`
reuses that daemon. Close only your failed session, then reopen it and verify
the connection. Replace `<name>` with the same session name throughout and run
each command in a separate tool call:

```sh
agent-browser close --session <name>
```

```sh
agent-browser open about:blank --session <name>
```

```sh
agent-browser get url --session <name>
```

The last command should print `about:blank`. If recovery fails, retain the full
error and follow the [browser setup diagnostics](SETUP.md#browser-access-for-the-tester).
Do not disable Chrome's sandbox or switch to the user's personal browser profile.
