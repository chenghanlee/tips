# Stream reservation trace

Evidence for [#63](https://github.com/chenghanlee/tips/issues/63): real reservations
through `Tips.Content.Media.begin_video_upload/4`, from
`test/tips/content/media/video_upload_real_test.exs`. Run it with
`TIPS_REAL_PROVIDERS=1`; it takes about 2.5 minutes.

Every transaction commits outside the SQL sandbox, and each check of the row runs on
its own connection, so it sees only committed state. A test plug forwards Tips's
reservation request to Stream and decides when, and whether, Stream's response
reaches Tips. Each test deletes every reservation Stream created and confirms it with
`GET` 404.

## Result

All five cases passed on 2026-10-07 at 21:22 UTC. Afterwards, Stream listed no video
named `tips-media-*`.

| Case | Real Stream | Tips |
|---|---|---|
| Success | 201; `requireSignedURLs: true`, `maxDurationSeconds: 180`, `uploadExpiry` equal to the row's `expires_at`, `meta.name` `tips-media-<media id>`, state `pendingupload`. tus `HEAD` on the URL with no API token: 200, `Upload-Offset: 0` | Before the call, the committed row is `uploading` with a NULL uid. When the URL is returned, the committed row holds the `stream-media-id` uid, before the first request to the URL |
| Lost response | 201 reached the plug; Tips got a timeout. The reservation stays `pendingupload` | `{:upload_failed, [id]}`; the row stays `uploading` with a NULL uid |
| Response after cleanup | 201, returned after a cleanup committed on another connection | `{:upload_failed, [id]}`; the uid stays NULL and the cleanup row is not revived |
| Response after the deadline | The row's deadline and the reservation expiry moved together to 125 seconds ahead (Stream refuses less than two minutes); the 201 was held until both passed. A tus `PATCH` to the withheld URL then got 400, code 10017 | `{:upload_failed, [id]}`; the uid stays NULL and the row keeps its deadline |
| Rejected reservation | Expiry 30 seconds ahead: 400, code 10005 | `{:upload_failed, [id]}`; the row is `failed` with a NULL uid |

The lock-wait race needs a lock held during the uid write, so the lock-session test
`video_upload_concurrency_test.exs` covers it with a stubbed provider response.
