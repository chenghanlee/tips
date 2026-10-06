# Stream completion probe

Evidence for [#243](https://github.com/chenghanlee/tips/issues/243): what Cloudflare
Stream does with a tus `PATCH` that is still sending when the upload expiry passes,
and which fields a completed upload carries. The
[video deadline contract](../design/data-model.md#video-states-and-deadlines) relies
on it.

## Result

**Pending.** No complete run is recorded yet.

The first run, at `f440270` with no tracked changes, measured nothing: Stream rejected
every 256 KiB first chunk with 400, code 10015, "Minimum allowed ChunkSize for a
non-final chunk is 5242880 bytes". The tester stopped it before expiry and deleted all
four reservations, each confirmed by `GET` 404
([run](stream-completion-probe/tester-aborted-20261006T191501Z-0938.json),
[cleanup](stream-completion-probe/cleanup-20261006T191603Z-3126.json)). The probe now
sends 5 MiB non-final chunks from a 15 MB clip and stops a case whose first chunk is
not acknowledged with 204 and the expected `Upload-Offset`.

The second run, at `335a117` with no tracked changes, stopped on a provider error
([run](stream-completion-probe/tester-blocked-20261006T192535Z-5bae.json),
[cleanup](stream-completion-probe/cleanup-20261006T192849Z-a22b.json)):

- All four 5 MiB first chunks: 204, `Upload-Offset` 5242880.
- Control: the final `PATCH`, throttled over 20 s, started 40 s before expiry and got
  500, code 10000 ("Internal Server Error"), 17 s before expiry. `HEAD` then reported
  the full 15,356,905-byte offset, yet the video stayed `pendingupload`.
- All three boundary `PATCH` requests got 400, code 10017 ("Expiration for upload has
  passed"), answered after their bodies finished sending. This is partial evidence
  only: the control failed and the run was interrupted before its timing assertions.
- All four reservations were deleted, each confirmed by `GET` 404.

Next, `diagnose` separates a provider fault from the throttled body: two uploads 15
minutes from expiry, one sending the rest unthrottled, then one throttled over 20 s
like the control.

Already known from the [#61 probe](https://github.com/chenghanlee/tips/blob/bb876b87e7e5f920faef8b6d722d2d46b6dda768/docs/development/media-provider-probe.md#stream_deadline):

- `uploaded` is set at reservation, before any byte. No field records completion time.
- The video leaves `pendingupload` only after the last byte.
- Every `PATCH` started after `uploadExpiry` was rejected (400, code 10017), at 130 s
  and at one hour.

## Cases

One reservation each, with the same 10 s, 720p clip of about 15 MB and a 130 s expiry
(Stream refuses less than two minutes). Each sends the first 5 MiB at once, then one
slow `PATCH`. Times are relative to `uploadExpiry`. A boundary case counts only if its
`PATCH` started before expiry and was still sending after it.

| Case | Slow `PATCH` | Question |
|---|---|---|
| `before` | rest of the file, −40 s to −20 s | Control: does the upload complete, and which timestamps does the finished video carry? |
| `span-10` | rest of the file, −10 s to +10 s | Is a final `PATCH` still sending at expiry accepted, and does the video complete? |
| `span-60` | rest of the file, −10 s to +60 s | The same with a longer overrun. |
| `nonfinal-span-10` | 5 MiB, −10 s to +10 s, then the rest at once if accepted | Does Stream store a non-final chunk that spans expiry? |

Server-side API calls use the production timeouts (5 s connect, 5 s receive, no
retry). The slow `PATCH` stands in for the browser and has a 180 s receive timeout.

## Run it

Needs `TIPS_REAL_PROVIDERS=1`, the provider file named by `TIPS_PROVIDER_ENV_FILE`,
a checkout with no tracked changes and `ffmpeg` on `PATH`. `run` makes four
reservations and `diagnose` two; each deletes them and confirms each with `GET` 404.
`diagnose` sends the throttled upload only if the unthrottled one completes.

```sh
TIPS_REAL_PROVIDERS=1 unbuffer mix run --no-start scripts/stream_completion_probe.exs run
TIPS_REAL_PROVIDERS=1 unbuffer mix run --no-start scripts/stream_completion_probe.exs diagnose
TIPS_REAL_PROVIDERS=1 unbuffer mix run --no-start scripts/stream_completion_probe.exs cleanup
```

`cleanup` is only for a run that stopped early: it deletes every reservation in the
inventories or found by the `tips-probe-243-` name prefix. Output goes to ignored
`tmp/stream-completion-probe/`: the redacted report, the redacted call log under
`private/` and the inventory. The report records the git SHA, tracked changes,
fixture hash and recipe, every call's status and `date` header, and the cleanup.
