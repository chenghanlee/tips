# Stream completion probe

Evidence for [#243](https://github.com/chenghanlee/tips/issues/243): what Cloudflare
Stream does with a tus `PATCH` that is still sending when the upload expiry passes,
and which fields a completed upload carries. The
[video deadline contract](../design/data-model.md#video-states-and-deadlines) relies
on it.

## Result

**Pending.** No run is recorded yet.

Already known from the [#61 probe](https://github.com/chenghanlee/tips/blob/bb876b87e7e5f920faef8b6d722d2d46b6dda768/docs/development/media-provider-probe.md#stream_deadline):

- `uploaded` is set at reservation, before any byte. No field records completion time.
- The video leaves `pendingupload` only after the last byte.
- Every `PATCH` started after `uploadExpiry` was rejected (400, code 10017), at 130 s
  and at one hour.

## Cases

One reservation each, with the same 10 s, 640×480 clip and a 130 s expiry (Stream
refuses less than two minutes). Each sends the first 256 KiB at once, then one slow
`PATCH`. Times are relative to `uploadExpiry`.

| Case | Slow `PATCH` | Question |
|---|---|---|
| `before` | rest of the file, −40 s to −20 s | Control: does the upload complete, and which timestamps does the finished video carry? |
| `span-10` | rest of the file, −10 s to +10 s | Is a final `PATCH` still sending at expiry accepted, and does the video complete? |
| `span-60` | rest of the file, −10 s to +60 s | The same with a longer overrun. |
| `nonfinal-span-10` | 1 MiB, −10 s to +10 s, then the rest at once if accepted | Does Stream store a non-final chunk that spans expiry? |

Server-side API calls use the production timeouts (5 s connect, 5 s receive, no
retry). The slow `PATCH` stands in for the browser and has a 180 s receive timeout.

## Run it

Needs `TIPS_REAL_PROVIDERS=1`, the provider file named by `TIPS_PROVIDER_ENV_FILE`,
a checkout with no tracked changes and `ffmpeg` on `PATH`. It makes four reservations,
deletes them and confirms each with `GET` 404.

```sh
TIPS_REAL_PROVIDERS=1 unbuffer mix run --no-start scripts/stream_completion_probe.exs run
TIPS_REAL_PROVIDERS=1 unbuffer mix run --no-start scripts/stream_completion_probe.exs cleanup
```

`cleanup` is only for a run that stopped early: it deletes every reservation in the
inventories or found by the `tips-probe-243-` name prefix. Output goes to ignored
`tmp/stream-completion-probe/`: the redacted report, the redacted call log under
`private/` and the inventory. The report records the git SHA, tracked changes,
fixture hash and recipe, every call's status and `date` header, and the cleanup.
