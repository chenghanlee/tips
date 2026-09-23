# Media provider probe (#61)

Disposable evidence for [issue #61](https://github.com/chenghanlee/tips/issues/61):
Cloudflare Stream tus limits, private playback, completion and deadline facts, R2
semantics and image parser selection. The probe code is not a production path.

## Verdict

**Blocked.** Media lifecycle work may rely only on the rows marked *proven*.

| Acceptance | Experiment | Result |
|---|---|---|
| Server-authorized byte cap ≤ 1,000,000,000 | `stream_length` | **Proven.** Stream stores no byte beyond the declared `Upload-Length`, and the browser cannot raise it. Stream itself accepts 1,000,000,001, so the cap is the server authorizer's job. |
| Private from reservation; 180 s limit | `stream_private` | **Proven.** Metadata applied at reservation; unsigned manifest, poster and iframe return 401; signed HLS decodes 100 H.264 frames; signed poster is a JPEG; expired and wrong-key tokens return 401; after delete the signed manifest returns 404. A 200 s video fails with `ERR_DURATION_EXCEED_CONSTRAINT`. |
| Trusted completion; completion + 48 h | `stream_deadline` | **Blocking gap.** Stream's `uploaded` is the reservation time, not transfer completion. No field observed records completion. Proven: the one-hour expiry is fixed at reservation, is not extended by pause/resume, and rejects bytes after it (full one-hour run). |
| R2 put/get/delete | `r2_roundtrip` | **S3 reads proven; public delivery unproven.** The owner's ISP has a routing loop to `r2.dev` ([owner decision](https://github.com/chenghanlee/tips/issues/61#issuecomment-5794223944)). Custom-domain cache purge is **deferred/unproven, #178 (M4)**. |
| Maintained parser selected before #62 | `parser_formats_bounds` | **Blocked.** No candidate passes every required fixture. Nothing is selected. |
| Secrets never in evidence; bounded calls; cleanup | `redaction_cleanup` | **Proven** for the runs recorded here. |

Unsupported semantics go to technical review. Consumers of completion time
(unattached-video expiry, recovery windows) and of image classification (#62) stay
blocked until the gaps below are resolved.

## Run it

From the repository root. Parser and redaction modes are offline. Provider modes
refuse to run without `TIPS_REAL_PROVIDERS=1` and read the ten fixed names from
`TIPS_PROVIDER_ENV_FILE` (default `.env`) through `Tips.ProviderConfig.load/2`;
exported values win.

```sh
bash scripts/media_probe.sh parser
bash scripts/media_probe.sh redaction-check
TIPS_REAL_PROVIDERS=1 bash scripts/media_probe.sh stream
TIPS_REAL_PROVIDERS=1 bash scripts/media_probe.sh stream-hour   # about 62 minutes
TIPS_REAL_PROVIDERS=1 bash scripts/media_probe.sh r2
TIPS_REAL_PROVIDERS=1 bash scripts/media_probe.sh cleanup
TIPS_REAL_PROVIDERS=1 bash scripts/media_probe.sh signing-key  # owner only; see below
python3 scripts/check_docs.py
git diff --check
```

Each mode prints one line per named assertion (`pass`, `fail`, `unproven`, `info`)
and exits nonzero when a required assertion fails or is unproven, or when the
report leak scan finds a secret. Output goes to ignored `tmp/media-probe/`:

- `<mode>-<run-id>.json`: redacted report (copies of the recorded runs are in
  `docs/development/media-provider-probe/`).
- `private/<mode>-<run-id>-calls.jsonl`: every request, redacted of credentials.
- `inventory/<mode>-<run-id>.jsonl`: every owned Stream reservation and R2 key,
  written before the request and again with its id. `cleanup` reads all of them.

Requirements: Elixir 1.20.4 / OTP 29, `ffmpeg`/`ffprobe` 8.1 on `PATH` (fixtures
and the ffprobe candidate), network access to Hex on first run. Candidate
dependencies are pinned in the scripts with `Mix.install` and stay out of
`mix.exs`/`mix.lock`: `vix 0.41.0` (precompiled NIF, libvips 8.18.3),
`req 0.7.4`, `jose 1.11.12`, `jason 1.4.5`.

## Sources

Retrieved 2026-09-23. The Stream API is `client/v4`, which is not versioned
further; results describe the service on that date.

- [Stream direct creator uploads](https://developers.cloudflare.com/stream/uploading-videos/direct-creator-uploads/)
  and [resumable uploads](https://developers.cloudflare.com/stream/uploading-videos/resumable-uploads/): tus 1.0.0,
  `?direct_user=true`, `Upload-Metadata` keys, `stream-media-id`, 256 KiB chunk rule.
- [Securing your Stream](https://developers.cloudflare.com/stream/viewing-videos/securing-your-stream/):
  RS256 tokens with `sub`, `kid`, `exp`; token replaces the uid in iframe, manifest and thumbnail URLs.
- [Direct upload API](https://developers.cloudflare.com/api/resources/stream/subresources/direct_upload/methods/create/):
  `maxDurationSeconds` 1–36,000; `expiry` semantics.
- [R2 consistency](https://developers.cloudflare.com/r2/reference/consistency/): strong
  read-after-write and read-after-delete at the origin; custom-domain caching relaxes it.

## Stream findings

Recorded run: `stream` `20260923T114819Z-1edd` at `72c393c`, clean tracked tree, 91
calls ([report](media-provider-probe/stream-20260923T114819Z-1edd.json)). Every request
is sequential, never retried, with a 30 s receive and 10 s connect timeout and a
400-call budget. Timestamps quoted below from the pause/resume case come from an
earlier run (`20260923T104941Z-dd93`, `0487970`); the recorded run repeats the result
(`uploaded` 11:49:21.150Z before the first chunk at 11:49:22.220Z; final chunk
11:49:44.927Z; `uploaded` unchanged).

### `stream_length`

- The probe's authorizer (the stand-in for Phoenix) refuses `0`, `-1`, `abc` and
  1,000,000,001 without calling Stream.
- Stream itself rejects `0`, `-1` and `abc` (400, code 10026) but **accepts
  1,000,000,001** (201). Stream does not know the Tips cap.
- Reservations for the small fixture, 200,000,000 and 1,000,000,000 bytes return
  201 with `stream-media-id`; `HEAD` reports the declared `Upload-Length` and offset 0.
  These are reservations only: no bytes were sent to them.
- A `PATCH` carrying `Upload-Length: 2000000000` does not change the declared
  length (the request fails; `HEAD` still reports 200,000,000).
- Declared 262,144 bytes, sent 524,288 in one `PATCH`: 400, offset stays 0.
- Declared 262,144, sent exactly 262,144 (204), then 262,144 more at the end offset:
  Stream answers **204 but the offset stays 262,144**. Extra bytes are not stored, but
  the status does not signal refusal; a client must read `Upload-Offset`.
- Bytes actually transferred in this experiment: 524,288 + 262,144 × 2 (random data).
- Chunk rule observed: a `PATCH` that is not a multiple of 256 KiB (and not final)
  is rejected with 400, code 10031.

### `stream_private`

- `requireSignedURLs: true`, `maxDurationSeconds: 180` and `uploadExpiry` equal to
  the requested one-hour expiry are present on the video immediately after
  reservation. The uid is read from `stream-media-id`, never from `Location`.
- Unsigned `/<uid>/manifest/video.m3u8`, `/<uid>/thumbnails/thumbnail.jpg` and
  `/<uid>/iframe` all return **401**.
- The 10 s fixture reaches `ready` with `duration: 10` about 5 s after transfer.
- The 200 s fixture ends in `state: error`, `errorReasonCode:
  ERR_DURATION_EXCEED_CONSTRAINT`, `readyToStream: false`, `duration: 0`.
- Tokens are signed locally with JOSE RS256 (`sub`, `kid`, `exp` +1 h,
  `downloadable: false`) from `CLOUDFLARE_STREAM_SIGNING_KEY`, read through
  `Tips.ProviderConfig.load/2`.
- Signed `/<token>/manifest/video.m3u8` → 200 `application/vnd.apple.mpegurl`; its
  first variant and first media segment → 200, 33,923 bytes `video/mp4`.
- **Playback:** ffprobe 8.1 opens the signed manifest like a player and decodes 100
  H.264 frames at 320×240 from the first 4 s. This, not the iframe status, is the
  playback evidence.
- Signed `/<token>/thumbnails/thumbnail.jpg` → 200 `image/jpeg`, JPEG magic bytes.
- Signed `/<token>/iframe` → 200 HTML (informational only).
- A token with `exp` 120 s in the past → 401. A token signed by a fresh RSA key with
  the real `kid` → 401.
- The over-180 s video's signed manifest → 424 (not playable).
- After `DELETE` (200): API `GET` → 404, repeated `DELETE` → 404 (code 10003), signed
  manifest with a fresh token → 404.
- A real browser rendering the iframe player was not tested.

### `stream_deadline`

- **`uploaded` is the reservation time.** Pause/resume run: reservation sent
  10:50:12.212Z; `uploaded` 10:50:12.677Z and `created` 10:50:12.681Z before any byte;
  first chunk 10:50:13.872Z; final chunk 10:50:37.184Z (acknowledged 10:50:38.570Z);
  `uploaded` unchanged afterwards. The 10 s
  small-file case cannot tell the two apart because its transfer takes about 1 s.
- `modified` moves when the transfer completes (`pendingupload` → `queued`) and again
  during processing. It is a last-change field, not a completion record.
- `readyToStreamAt` is later than both and is processing readiness.
- `uploadExpiry` is fixed at reservation; pausing 20 s mid-transfer and resuming
  does not change it.
- Expiry shorter than two minutes is refused (400, code 10005, "expiry must be more
  than two minutes in the future"); 130 s is accepted.
- With a 130 s expiry: a transfer started before expiry and finished after it is
  rejected (400, code 10017, "Expiration for upload has passed"); a first `PATCH`
  after expiry is rejected the same way. Both videos stay `pendingupload`.
- **One-hour enforcement** (`stream-hour` `20260923T103853Z-93b9`,
  [report](media-provider-probe/stream-hour-20260923T103853Z-93b9.json)): expiry
  11:38:53Z (provider `uploadExpiry` equal); first chunk 204 at 10:38:54Z; final chunk
  at 11:39:56Z (about 1 min after expiry) → 400, code 10017; video stays
  `pendingupload`; deleted. The report names `72c393c` because the SHA is read when the
  report is written; the code was loaded at launch (10:38Z) from `214750e` plus the
  then-uncommitted `stream-hour` fixes, and that module's logic equals `72c393c`.
- Lost creation response: a creation call with a 1 ms receive timeout fails at the
  client after one attempt (no retry). The reservation **does exist** at Stream,
  found only by its `name` metadata. A caller that loses the response has no uid.
- Creation latency across 11 successful reservations: min 503 ms, median 582 ms, max 668 ms.

#### Gap: completion time

The design stores `completed_at` from Stream's `uploaded` and sets unattached expiry
to completion + 48 h. At this date `uploaded` does not mean completion, so that rule
cannot be implemented as written. What is proven instead:

- No byte is accepted after the reservation's expiry, so a successful transfer always
  completes before `created + 1 h`.
- The state leaves `pendingupload` only after the last byte.

Options for technical review (not chosen here): define the recovery deadline from
the fixed reservation expiry (`expires_at + 48 h`, a bound that never depends on
observation); or treat the first observation outside `pendingupload` as completion,
which depends on polling time and was ruled out by the design. A Stream webhook was
excluded by the design and was not tested.

## R2 findings

Recorded run: `r2` `20260923T105816Z-a0af` at `00e727a`, clean tracked tree
([report](media-provider-probe/r2-20260923T105816Z-a0af.json)); `r2` includes the public
reads, so it is not rerun under the owner decision. Keys are `media/probe-61/<run-id>/<uuid>.<ext>` in
the development bucket, with synthetic 64×48 PNG and GIF fixtures.

- S3 `PUT` with `Content-Type` → 200. S3 `GET` returns identical bytes (SHA-256
  checked) and the stored `Content-Type`.
- S3 `DELETE` → 204; S3 `GET` right after → 404 `NoSuchKey`; repeated `DELETE` → 204;
  `ListObjectsV2` on the run prefix → empty.
- **Public delivery unproven.** Reads through `R2_PUBLIC_URL` never got an HTTP
  response (TCP connect timeouts to every `r2.dev` address, while the S3 endpoint and
  `api.cloudflare.com` work). The owner reproduced it on their host for every `r2.dev`
  name and attributes it to an ISP routing loop; the [owner decision](https://github.com/chenghanlee/tips/issues/61#issuecomment-5794223944) accepts
  public delivery as unproven and forbids further public reads or network workarounds.
  Origin deletion is proven; public delivery and public caching after delete are not.
- Custom media domain and cache purge: **deferred/unproven, #178** (M4).

## Parser findings

Recorded run: `parser` at `0487970`, 28 synthetic fixtures. Report:
[parser-report.json](media-provider-probe/parser-report.json).

Each classification runs in a fresh OS process under `/usr/bin/time -l`, killed at
the parent deadline. The classifier sniffs magic bytes, calls only the matching
libvips loader (`pngload`/`jpegload`/`webpload`/`gifload`), applies the header
bounds, then decodes every pixel sequentially with `fail-on: error`.

Proposed bounds (checked before decoding): 10,000,000 bytes, 8,192 px per side,
40,000,000 px per frame, 300 frames, 100,000,000 px in total, 5 s per parse.

| Fixture | Bytes | Expected | Vix 0.41.0 / libvips 8.18.3 | ms | Peak RSS MiB | libvips high-water B | ffprobe 8.1 | ms |
|---|---|---|---|---|---|---|---|---|
| `static.png` | 442 | png static | ✓ accept png static | 18.0 | 127 | 62,860 | ✓ accept png static | 65.4 |
| `animated.apng` | 982 | png animated | **✗** accept png static | 15.0 | 129 | 66,003 | ✓ accept png animated | 30.2 |
| `single-frame.apng` | 442 | png static | ✓ accept png static | 14.8 | 124 | 56,693 | ✓ accept png static | 30.1 |
| `static.jpg` | 1,981 | jpeg static | ✓ accept jpeg static | 17.4 | 117 | 69,288 | ✓ accept jpeg static | 32.4 |
| `static.gif` | 1,650 | gif static | ✓ accept gif static | 14.1 | 122 | 66,003 | ✓ accept gif static | 33.2 |
| `animated.gif` | 3,823 | gif animated | ✓ accept gif animated | 18.5 | 117 | 162,513 | ✓ accept gif animated | 30.2 |
| `static.webp` | 908 | webp static | ✓ accept webp static | 16.1 | 119 | 81,782 | ✓ accept webp static | 33.0 |
| `animated.webp` | 4,170 | webp animated | ✓ accept webp animated | 15.1 | 120 | 210,381 | **✗** reject malformed | 29.2 |
| `spoofed-jpeg-as.png` | 1,981 | jpeg static | ✓ accept jpeg static | 21.0 | 119 | 75,645 | ✓ accept jpeg static | 32.0 |
| `spoofed-text-as.gif` | 27 | reject unclassifiable | ✓ reject unclassifiable | 0.2 | 116 | 0 | ✓ reject malformed | 26.5 |
| `svg-as.png` | 64 | reject unclassifiable | ✓ reject unclassifiable | 0.1 | 122 | 0 | ✓ reject unclassifiable | 43.8 |
| `bmp.bmp` | 9,270 | reject unclassifiable | ✓ reject unclassifiable | 0.1 | 115 | 0 | ✓ reject unclassifiable | 30.0 |
| `tiff.tif` | 7,715 | reject unclassifiable | ✓ reject unclassifiable | 0.2 | 116 | 0 | ✓ reject unclassifiable | 33.1 |
| `empty.png` | 0 | reject unclassifiable | ✓ reject unclassifiable | 0.3 | 121 | 0 | ✓ reject malformed | 27.2 |
| `random.bin` | 4,096 | reject unclassifiable | ✓ reject unclassifiable | 0.1 | 117 | 0 | ✓ reject malformed | 26.3 |
| `png-signature-garbage.png` | 520 | reject malformed | ✓ reject malformed | 10.9 | 116 | 0 | ✓ reject malformed | 29.8 |
| `truncated.png` | 265 | reject malformed | ✓ reject malformed | 16.1 | 115 | 37,716 | ✓ reject malformed | 35.1 |
| `truncated.jpg` | 1,188 | reject malformed | ✓ reject malformed | 30.6 | 125 | 66,074 | **✗** accept jpeg static | 30.0 |
| `truncated.gif` | 2,293 | reject malformed | **✗** accept gif animated | 16.9 | 127 | 150,012 | **✗** accept gif animated | 28.7 |
| `truncated.webp` | 2,502 | reject malformed | ✓ reject malformed | 14.6 | 118 | 0 | ✓ reject malformed | 38.6 |
| `truncated.apng` | 589 | reject malformed | **✗** accept png static | 22.4 | 121 | 59,717 | **✗** accept png static | 33.4 |
| `corrupt-idat.png` | 442 | reject malformed | ✓ reject malformed | 16.2 | 117 | 53,431 | ✓ reject malformed | 29.7 |
| `huge-dimensions.png` | 389,648 | reject dimensions_over_limit | ✓ reject dimensions_over_limit | 18.6 | 121 | 0 | **✗** reject malformed | 29.5 |
| `frame-pixels-over.png` | 62,587 | reject frame_pixels_over_limit | ✓ reject frame_pixels_over_limit | 13.1 | 118 | 0 | ✓ reject frame_pixels_over_limit | 75.5 |
| `at-pixel-budget.png` | 35,330 | png static | ✓ accept png static | 29.7 | 125 | 10,663,881 | ✓ accept png static | 57.4 |
| `many-frames.gif` | 25,836 | reject frames_over_limit | ✓ reject frames_over_limit | 12.7 | 118 | 0 | ✓ reject frames_over_limit | 30.5 |
| `total-pixels-over.gif` | 5,303,194 | reject total_pixels_over_limit | ✓ reject total_pixels_over_limit | 15.0 | 128 | 0 | ✓ reject total_pixels_over_limit | 391.3 |
| `over-10mb.png` | 17,310,389 | reject bytes_over_limit | ✓ reject bytes_over_limit | 0.2 | 116 | 0 | ✓ reject bytes_over_limit | 0.1 |

Measured, not claimed:

- Peak RSS is 115–129 MiB for every Vix case; the BEAM plus `Mix.install` baseline
  dominates. libvips' own tracked high-water is 10.7 MB at the 36 MP budget fixture
  and 0 for header-only rejections, so pixel/frame budgets bound decode work. No OS
  memory cap is applied; the 5 s deadline alone is not a memory bound.
- Slowest Vix parse: about 31 ms. ffprobe decodes every frame before bounds can be
  applied (391 ms on the 5 MB total-pixel fixture).

Blocking results:

- **Vix/libvips does not support APNG.** An animated APNG is reported as a static
  PNG (no `n-pages`), and a truncated APNG passes because later frames are never read.
- **Vix accepts a truncated GIF** as a valid 3-frame animation (libnsgif tolerates a
  missing trailer), even with `fail-on: error`.
- **Vix silently ignores unknown option names.** `fail_on:` is dropped; only the libvips
  spelling `"fail-on":` applies. With `fail_on:` truncated PNG and JPEG were accepted.
  Any caller must use `"fail-on"` and test it.
- **ffprobe 8.1** cannot decode animated WebP, accepts truncated JPEG, GIF and APNG,
  and is an external executable rather than a library.
- `ex_image_info 1.0.0` was examined and dropped: it reports no motion at all
  (animated and static WebP both `webpVP8X`; APNG reported as `PNG`).

Nothing is selected. Options for technical review: Vix plus a bounded APNG chunk
check (`acTL`/`fcTL`/`fdAT` walk with CRC) and a GIF trailer check, which is our own
parsing code; or a different maintained decoder with APNG support.

## Redaction and cleanup

- Reports and call logs replace the API token, R2 keys, OpenRouter key, signing
  material, upload `Location` URLs, signed tokens, account id, customer code, bucket,
  R2 endpoint and public URL. Every report is scanned for secret values, JWT-shaped
  strings and upload URLs before it is written; the mode fails on any hit.
- The signing-key creation response is marked sensitive: its body and any exception
  text are dropped before logging. `redaction-check` (`20260923T104809Z-3e37` at
  `0487970`, [report](media-provider-probe/redaction-check-20260923T104809Z-3e37.json)) proves this with synthetic
  key-shaped success, error, small, malformed and exception responses, and fails when
  suppression is disabled.
- Cleanup (`cleanup` `20260923T115343Z-094e` at `72c393c`, clean tree,
  [report](media-provider-probe/cleanup-20260923T115343Z-094e.json)): read 13
  inventory files (132 requested reservations, including interrupted runs and
  lost-response reservations), searched Stream by the `tips-probe-61-` name prefix,
  and reconciled 90 uids: 76 already deleted, 14 deleted now, each confirmed by `GET`
  404; none remain by name. The R2 prefix `media/probe-61/` is empty. The shared
  signing key is kept.
- Two runs were cut short and have no report: `20260923T112904Z-5c2e` (a local DNS
  outage at 11:30Z made every later call fail) and `20260923T113726Z-8d78` (the
  session ended; its partial log showed `signed_hls_decodes_video_frames` failing
  with no retained detail). Their resources are covered by the cleanup above. The
  recorded run passes that check.

## Signing key (owner step)

`signing-key` creates one Stream signing key and appends
`CLOUDFLARE_STREAM_SIGNING_KEY=<base64 JWK>` (the JWK includes `kid`) to
`TIPS_PROVIDER_ENV_FILE`. It refuses before calling Stream when the variable is
already set or the file is not writable, and never deletes keys. The developer
session was not permitted to write the secret store; the owner ran the reviewed
helper at `0487970` (run `20260923T110825Z-a180`), and the key now lives in the main
checkout's `.env`.
