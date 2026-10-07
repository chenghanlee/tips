# M1 gate: local text prototype

Evidence for [#96](https://github.com/chenghanlee/tips/issues/96). All four acceptance
lines pass on revision
[`78157f3`](https://github.com/chenghanlee/tips/commit/78157f3425175478e24dc8889bd87a8ad26bf12a),
with no tracked changes, on 2026-10-07.

Machine: macOS 26.5, Elixir 1.20.4, OTP 29, the Compose database on port 5433,
agent-browser 0.38.1. The dev app ran with the [manual browser review](../../agent/teams/README.md#manual-browser-review)
command on its own database (`tips_dev_team1_dev`) and port 4110, with the dev mailbox,
no Turnstile and real OpenRouter embeddings. Each `agent-browser --session` name is a
separate browser.

## Results

| Acceptance line | Result | Embedding requests |
|---|---|---|
| Register through the dev mailbox; return from another browser | Pass, browser | 0 |
| Lost-ack publish/edit; author delete; hide/restore | Pass: publish/edit in the browser; delete and hide/restore by test run | at most 4 |
| Minimal tip and single-review pages in initial HTML | Pass, `curl` | 1 (the review) |
| Ten-query hybrid search gate | Pass: #60 run 5 and the replay test | 0 |

The developer used at most 5 of the 40 authorized embedding requests. The
`EmbedSearch` worker sends one request per text version it embeds: two tips published
and edited, and one review. No search page was opened, so no query was embedded.

## Registration and return

1. Session A opened `/users/register`, submitted a new email and followed the
   "Confirmation instructions" link from `/dev/mailbox`. The account was confirmed
   ("User confirmed successfully.") and signed in.
2. Session B, signed out, opened `/editor/tips/new` and was sent to `/users/log-in`.
   It requested a link for the same email, opened the newest "Log in instructions"
   message in `/dev/mailbox`, followed it and chose "Log me in only this time".
3. Session B landed on `/editor/tips/new`, signed in.

## Publish and edit with lost acknowledgements

1. In session B a tip was published ("Published.", `/tips/1/plan-before-you-code`) and
   edited ("Changes saved.").
2. Lost publish reply, in session A: after the draft was saved in the browser, the
   page dropped every `phx_reply` frame (the `drop_replies` script in
   [`editor_reconcile_test.exs`](../../test/tips_web/features/editor_reconcile_test.exs)),
   and Publish was clicked. The page stayed on the editor and two replies were
   dropped. After a disconnect and reconnect (the test's `reconnect` script) the page
   opened `/tips/2/lost-reply-publish` with "Published.". The database then had one
   row for it, and reopening `/editor/tips/new` showed empty fields: the draft was
   cleared.
3. Lost edit reply, in session A: on `/editor/tips/2/edit` the body was changed,
   replies were dropped and Save changes was clicked. The row reached
   `edit_version` 2. After the reconnect the page stayed on the editor with "We
   couldn't confirm whether your changes were saved. The saved tip is below.", showed
   the saved version beside the kept text, and kept `expected_version` 1. Saving again
   showed "This tip changed after you opened it, so your changes were not saved." and
   did not write.

The browser feature test itself was not run: this machine has no ChromeDriver
(`which chromedriver` finds none). CI runs it. The steps above use its scripts by
hand, with two changes for `agent-browser eval`: wrap the `reconnect` script in
`(async () => { ... })()`, since `eval` does not accept top-level `await`; and check
the connection with `window.liveSocket.isConnected()`, since
`agent-browser wait '.phx-connected'` timed out on a connected page.

LiveView tests on this revision:

```sh
mix test test/tips_web/live/editor_test.exs test/tips_web/live/editor_lookup_test.exs
```

Result: 9 passed.

## Author delete and hide/restore

No page offers delete, hide or restore yet, so this line is a test run on this
revision:

```sh
mix test test/tips/content/lifecycle_test.exs test/tips_web/live/tip_live/show_test.exs
```

Result: 18 passed.

## Initial HTML

With the server running and no JavaScript:

```sh
curl -s http://localhost:4110/tips/1/plan-before-you-code
curl -s http://localhost:4110/reviews/1
```

Both returned 200 `text/html`. The tip response contains its title "Plan before you
code" and its edited body. The review response contains its body, "Tried it on a
refactor. The plan caught a wrong file before any edits.". The review was published
from `/editor/tips/1/reviews/new` in session A.

## Hybrid search gate

No live run, by the dispatcher's
[decision](https://github.com/chenghanlee/tips/issues/96): this revision's tree equals
the tree #60 run 5 tested.

- [Run 5 report](../../test/fixtures/search_probe/evidence/60-integrated-run-5.json):
  status `passed`, all 15 gates pass, `Qwen/Qwen3-Embedding-8B` through Nebius,
  90 requests, each returning 1024 values.
- Replay on this revision, `mix test test/tips/search_gate_test.exs`: 9 passed.
