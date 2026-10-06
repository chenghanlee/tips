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
[cleanup](stream-completion-probe/cleanup-20261006T191603Z-3126.json)). Since then the
probe sends 5 MiB non-final chunks and stops a case whose chunk is not acknowledged
with 204 and the expected `Upload-Offset`.

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

The third run, `diagnose` at `11587c9` with no tracked changes, failed the same way far
from expiry ([report](stream-completion-probe/diagnose-20261006T193911Z-4c50.json)):
after a 5 MiB first chunk (204), the unthrottled 10 MB rest got 500, code 10000; `HEAD`
showed the full 15,339,962-byte offset and the video stayed `pendingupload`. The
throttled upload was skipped. Both reservations were deleted, each confirmed by
`GET` 404. Ten of the 20 authorized uploads are used.

The #61 client completed the same kind of upload, so the probe now sends uploads the
way that client did. Differences from the #61 client before this change:

| | #61 client | Runs 2 and 3 | Now |
|---|---|---|---|
| Largest `PATCH` | 5 MiB chunks; final chunk shorter | final `PATCH` of about 10 MB | 5 MiB chunks; final chunk shorter |
| Fixture | 720p, 30 fps, 6 Mbit/s, 12 s, no audio | 720p with a noise filter, 12 Mbit/s constant bitrate with filler, AAC audio | #61 recipe at 10 s and 10 Mbit/s, about 13 MB |
| Body | one binary; Req sets `Content-Length` | always a stream with an explicit `Content-Length` and an empty last piece | one binary, except the one slow `PATCH`, which the measurement needs |
| Order | one request at a time | four cases at once | one case at a time |

Creation headers, `Upload-Metadata` keys and the `PATCH` headers already matched. Req
0.7.4 is the version both use.

Already known from the [#61 probe](https://github.com/chenghanlee/tips/blob/bb876b87e7e5f920faef8b6d722d2d46b6dda768/docs/development/media-provider-probe.md#stream_deadline):

- `uploaded` is set at reservation, before any byte. No field records completion time.
- The video leaves `pendingupload` only after the last byte.
- Every `PATCH` started after `uploadExpiry` was rejected (400, code 10017), at 130 s
  and at one hour.

## Cases

One reservation each, run one after another, with the same 10 s, 720p clip of about
13 MB: two 5 MiB chunks and a shorter final one. Each reservation expires 130 s after it
is made (Stream refuses less than two minutes). Each case sends its chunks unthrottled
except one slow `PATCH`. Times are relative to `uploadExpiry`. A boundary case counts
only if its slow `PATCH` started before expiry and was still sending after it.

| Case | Slow `PATCH` | Question |
|---|---|---|
| `before` | final chunk, −40 s to −20 s | Control: does the upload complete, and which timestamps does the finished video carry? |
| `span-10` | final chunk, −10 s to +10 s | Is a final `PATCH` still sending at expiry accepted, and does the video complete? |
| `span-60` | final chunk, −10 s to +60 s | The same with a longer overrun. |
| `nonfinal-span-10` | second 5 MiB chunk, −10 s to +10 s, then the final chunk at once if stored | Does Stream store a non-final chunk that spans expiry? |

Server-side API calls use the production timeouts (5 s connect, 5 s receive, no
retry). The slow `PATCH` stands in for the browser and has a 180 s receive timeout.

## Run it

Needs `TIPS_REAL_PROVIDERS=1`, the provider file named by `TIPS_PROVIDER_ENV_FILE`,
a checkout with no tracked changes and `ffmpeg` on `PATH`. `run` makes four
reservations and `diagnose` two; each deletes them and confirms each with `GET` 404.
`diagnose` uploads twice, 15 minutes from expiry: once unthrottled, then, only if that
completes, with the final chunk throttled over 20 s like the `before` control.

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
