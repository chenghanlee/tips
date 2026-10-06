# Stream completion probe

Evidence for [#243](https://github.com/chenghanlee/tips/issues/243): what Cloudflare
Stream does with a tus `PATCH` that is still sending when the upload expiry passes,
and which fields a completed upload carries. It informed the 10-minute cleanup margin
in the [video deadline contract](../design/data-model.md#video-states-and-deadlines).
The probe script was removed; it is at
[`75f819e`](https://github.com/chenghanlee/tips/blob/75f819e4e95431ba7765add2d99348116295d0aa/scripts/stream_completion_probe.exs).

## Result

**Unproven.** No run completed an upload, so whether Stream can complete a `PATCH`
still sending at expiry is not measured. The user stopped further runs and accepted a
10-minute margin after the upload deadline instead
([decision](https://github.com/chenghanlee/tips/issues/243#issuecomment-6024452901)).
Partial evidence: three expiry-spanning `PATCH` requests were refused with 400, code
10017, when their bodies finished. Ten of the 20 authorized uploads were used; every
reservation was deleted and confirmed by `GET` 404.

The first run, at `f440270` with no tracked changes, measured nothing: Stream rejected
every 256 KiB first chunk with 400, code 10015, "Minimum allowed ChunkSize for a
non-final chunk is 5242880 bytes". The tester stopped it before expiry and deleted all
four reservations, each confirmed by `GET` 404
([run](stream-completion-probe/tester-aborted-20261006T191501Z-0938.json),
[cleanup](stream-completion-probe/cleanup-20261006T191603Z-3126.json)). Later versions
sent 5 MiB non-final chunks and stopped a case whose chunk was not acknowledged with
204 and the expected `Upload-Offset`.

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
`GET` 404.

The #61 client completed the same kind of upload. The last probe version sent uploads
the way that client did, but was never run. Differences from the #61 client:

| | #61 client | Runs 2 and 3 | Last version, not run |
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

Each case had one reservation expiring 130 s after it was made (Stream refuses less
than two minutes) and one slow `PATCH`. Times are relative to `uploadExpiry`.

| Case | Slow `PATCH` | Question |
|---|---|---|
| `before` | final chunk, −40 s to −20 s | Control: does the upload complete, and which timestamps does the finished video carry? |
| `span-10` | final chunk, −10 s to +10 s | Is a final `PATCH` still sending at expiry accepted, and does the video complete? |
| `span-60` | final chunk, −10 s to +60 s | The same with a longer overrun. |
| `nonfinal-span-10` | second 5 MiB chunk, −10 s to +10 s, then the final chunk at once if stored | Does Stream store a non-final chunk that spans expiry? |

Server-side API calls used the production timeouts (5 s connect, 5 s receive, no
retry). Reports record the launch SHA, tracked changes, fixture hash and recipe, every
call's status and `date` header, and the cleanup.
