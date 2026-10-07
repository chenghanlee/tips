# Stream reservation trace

Evidence for [#63](https://github.com/chenghanlee/tips/issues/63): one real
reservation through `Tips.Content.Media.begin_video_upload/4`, from the
`:real_provider` test "a real reservation is private and bounded, and its uid is
stored before release" in `test/tips/content/media/video_upload_test.exs`. Run it with
`TIPS_REAL_PROVIDERS=1`.

## Result

Run on 2026-10-07 at 21:03 UTC. The account id, uid and upload URL token are left out.

| Step | Observed |
|---|---|
| Row before the call | `uploading`, NULL uid, `created_at` 21:03:02Z, `expires_at` 22:03:02Z |
| Reservation | 201; Stream `uploaded` 21:03:03.54Z, `created` 21:03:03.55Z |
| Row when the URL was returned | `uploading`, `stream_uid` equal to the `stream-media-id` header |
| tus `HEAD` on the URL, no API token | 200, `Upload-Offset: 0`, `Upload-Length: 12345678` |
| `GET /stream/<uid>` | `requireSignedURLs: true`, `maxDurationSeconds: 180`, `uploadExpiry` 22:03:02Z (the row's `expires_at`), `meta.name` `tips-media-<media id>`, state `pendingupload` |
| Cleanup | `DELETE` 200, then `GET` 404 |

The URL host was `upload.cloudflarestream.com` under `/tus`. The uid was stored before
the URL was returned and used: the test reads the row before its first request to the
URL. The lost-response, late-response and lock-wait cases need a provider response
that cannot be timed reliably, so the Req.Test and lock-session tests cover them.
