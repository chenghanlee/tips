# Pinned generated authentication baseline

Inspection for [#24](https://github.com/chenghanlee/tips/issues/24), dated 2026-09-21,
against `main` **`e107b7f6393282d785f9c6b25e5b0b1f6d66dc1f`**. All production
file/line references below refer to that revision, which this probe leaves unchanged.
The [readiness amendments A1–A5](https://github.com/chenghanlee/tips/issues/24#issuecomment-5761394427)
are applied using the actual source line numbers.

The baseline is Phoenix **1.8.14**, LiveView **1.2.12** (`mix.lock:37,42`),
Elixir **1.20.4**, OTP **29.1** ([toolchain](toolchain.md)).
[#23's recorded command](https://github.com/chenghanlee/tips/issues/23#issuecomment-5752041493)
was `mix phx.gen.auth Accounts User users --live`; commit `6a3c68d` added its
unchanged auth output. This is the LiveView/scope generator with magic-link
registration **and retained password login/settings**, not a password-free variant.
Password removal is tracked in [#160](https://github.com/chenghanlee/tips/issues/160).

The governing targets are [Sessions and authentication foundation](../design/technical/backend-design.md#sessions-and-authentication-foundation),
[Session renewal and logout](../design/technical/backend-design.md#session-renewal-and-logout),
[Changing the sign-in email](../design/technical/backend-design.md#changing-the-sign-in-email),
and [Tables](../design/technical/data-model.md#tables).
This document and the [executable fixture](../../test/tips/accounts/auth_baseline_test.exs)
inspect those adaptation points; they implement no production adaptation.

## Token formats, lifetimes and timestamps

| Concern | Actual generated source and default | Tips target and owning issue |
|---|---|---|
| Magic link | `lib/tips/accounts/user_token.ex:11,107`: `verify_magic_link_token_query/1` accepts `"login"` rows newer than 15 minutes and requires `sent_to == user.email`. | Keep **15 minutes**. [#45](https://github.com/chenghanlee/tips/issues/45) shares validity; [#44](https://github.com/chenghanlee/tips/issues/44) adds registration-expiry guards. |
| Email-change link | `user_token.ex:12,137`: `verify_change_email_token_query/2` accepts rows newer than seven days in `"change:" <> original_email`. | Keep **seven days**. [#102](https://github.com/chenghanlee/tips/issues/102) owns guarded account/email confirmation. |
| Session validity | `user_token.ex:13,58`: `verify_session_token_query/1` accepts session rows newer than **14 days**, returning `{user, token.inserted_at}`. | Change to **60 days**, explicitly a Tips adaptation, [#45](https://github.com/chenghanlee/tips/issues/45). |
| Reissue age | `lib/tips_web/user_auth.ex:27,94`: `maybe_reissue_user_session_token/3` uses whole-day token age `>= 7`. | Keep **seven days**, already a generator default; add family semantics in [#45](https://github.com/chenghanlee/tips/issues/45). |
| Persistent cookie | `user_auth.ex:12,14,160`: `write_remember_me_cookie/2` uses **14 days** (`1,209,600` seconds). | Change to **60 days** (`5,184,000` seconds), aligned with server validity, [#45](https://github.com/chenghanlee/tips/issues/45). |
| Recent authentication | `lib/tips/accounts.ex:91`: `sudo_mode?/2` defaults to a **20-minute** window (`minutes = -20`); nil recency fails. `user_auth.ex:234,237` explicitly uses **10 minutes** for the settings mount. | Preserve genuine-authentication recency and the existing settings guards; [#45](https://github.com/chenghanlee/tips/issues/45) preserves timestamps, [#102](https://github.com/chenghanlee/tips/issues/102) owns email-change authorization. |

The abbreviated `user_token.ex` and `user_auth.ex` references in this document
mean `lib/tips/accounts/user_token.ex` and `lib/tips_web/user_auth.ex` respectively.
All three token validity queries use strict `inserted_at > ago(...)`; exactly
at the cutoff is expired. Reissue is separate and does not impose a fixed maximum
continuous sign-in duration.

Keep these formats and names when adapting the code:

- `UserToken.build_session_token/1` (`user_token.ex:44`) creates **32 random bytes**,
  stored directly in the `token` binary column with context `"session"`. It returns
  the raw token; the browser session/remember-me storage signs it. It is not an
  email-style SHA-256 digest.
- `build_email_token/2` → `build_hashed_token/3` (`user_token.ex:81,85`) generates
  32 random bytes, sends URL-safe Base64 **without padding**, and stores their
  **SHA-256 hash**. `sent_to` records the destination; login and change-email
  contexts remain distinct. No second token format is needed for families.
- `User` (`lib/tips/accounts/user.ex:5–12`) persists `confirmed_at`, `inserted_at`
  and `updated_at`; `authenticated_at` is **virtual** on the user. `UserToken`
  (`user_token.ex:15–22`) persists `authenticated_at` and `inserted_at`, with no
  `updated_at`. These are `:utc_datetime` values with second precision.
- The generated migration
  `priv/repo/migrations/20260920192551_create_users_auth_tables.exs:7–28`
  has integer ids, case-insensitive `citext` email/unique index, token ownership
  with `on_delete: :delete_all`, a user-id index and unique `(context, token)`
  index. There is **no `session_family_id`**. [#25](https://github.com/chenghanlee/tips/issues/25)
  owns canonical identity/schema changes and the UUID field, session-only CHECK
  and partial `(user_id, session_family_id)` index. Preserve generated timestamp
  names and UTC meaning while aligning types with the canonical schema.

## Session creation, Plug renewal and token reissue

`Accounts.generate_user_session_token/1` (`lib/tips/accounts.ex:175`) inserts
one `UserToken` and returns its raw token. `get_user_by_session_token/1` (`:186`)
returns `{user_with_token_recency, token_inserted_at}` or nil. It does not return
a session-row id or family.

The two meanings of renewal must remain distinct:

1. **Plug session renewal:** `UserAuth.renew_session/2` (`user_auth.ex:124,144`)
   returns the connection unchanged for the same signed-in user. Otherwise it
   deletes the CSRF token, requests session-ID renewal and clears session data
   against fixation. It does not revoke a database token or family.
2. **Token reissue:** `fetch_current_scope_for_user/2` (`user_auth.ex:68`) loads a
   valid token/user, then `maybe_reissue_user_session_token/3` (`:94`) calls
   `create_or_extend_session/3` (`:112`) when the row is at least seven days old.
   That function inserts a new row, invokes Plug renewal, writes the new token
   with `put_token_in_session/2` (`:166`), and updates the persistent cookie if
   selected. **The predecessor row remains valid until it expires**; reissue
   neither deletes it nor groups it into a family.

`log_in_user/3` (`user_auth.ex:35`) also uses `create_or_extend_session/3`.
The magic-link controller (`lib/tips_web/controllers/user_session_controller.ex:16`)
passes the user returned by `Accounts.login_user_by_magic_link/1` to that function.

[#45](https://github.com/chenghanlee/tips/issues/45) must adapt the second path:
lock the account, revalidate the predecessor's context/expiry/account, create
successors in the same server-generated family, and share validity with pruning
and consumers. Fresh login starts a family; same-account reauthentication retains
it. Generated token creation has none of those locks or family rules.

### Cookies and browser session keys

- `lib/tips_web/endpoint.ex:11–20,57`: `Plug.Session` uses `store: :cookie`, key
  `_tips_key`, a signing salt and `same_site: "Lax"`. No encryption salt or
  persistent `max_age` is specified. LiveView receives this session in connect info.
- `user_auth.ex:13–18`: `_tips_web_user_remember_me` explicitly uses `sign: true`,
  14-day `max_age` and `same_site: "Lax"`. `http_only` and `secure` are not explicitly
  overridden; the locked Plug implementation defaults HttpOnly to true and sets
  Secure for an HTTPS connection (`deps/plug/lib/plug/conn.ex:1699–1701,1722`).
  Do not mistake the absence of an explicit option for an explicitly false option.
- `ensure_user_token/1` (`user_auth.ex:79`) prefers `:user_token` in the session;
  otherwise it verifies the signed remember-me cookie and sets `:user_remember_me`.
  `maybe_write_remember_me_cookie/4` (`:152–158`) writes only when requested with
  `"remember_me" => "true"` or already remembered.
- `put_token_in_session/2` (`:166`) writes `:user_token` and `:live_socket_id`.
  `user_session_topic/1` (`:181`) derives the topic from **the token**:
  `"users_sessions:#{Base.url_encode64(token)}"` (default padding).

### Scope, session-row reference and logout

`Scope.for_user/1` (`lib/tips/accounts/scope.ex:21–32`) holds only `user`; it returns
nil for anonymous callers. `mount_current_scope/2` (`user_auth.ex:249`) reads the
session token and discards the returned token insertion time. Generated
`:require_authenticated` (`:219`) and `require_authenticated_user/2` (`:271`)
check user presence, not confirmation, deletion, bans or current mutation admission.

[#33](https://github.com/chenghanlee/tips/issues/33) owns the scope/admission
contract; [#47](https://github.com/chenghanlee/tips/issues/47) owns fresh admission
at privileged boundaries. Adapt the Accounts lookup and these mounts to retain
each LiveView's **private session-row reference**. The stable **family disconnect
topic** belongs alongside `put_token_in_session/2`, `user_session_topic/1` and
`disconnect_sessions/1` (`user_auth.ex:175`); a broadcast is feedback, not proof
of admission.

`log_out_user/1` (`user_auth.ex:49`) deletes only the current token through
`Accounts.delete_user_session_token/1` (`accounts.ex:279`), broadcasts its token
topic, clears the Plug session and removes the remember-me cookie. Account
switching clears Plug data but does not revoke the old account's browser tokens.
[#46](https://github.com/chenghanlee/tips/issues/46) must revoke the entire browser
family under the account lock and broadcast **after commit**, preserving other
browsers. Account switching locks both accounts in id order. Generated code
supplies none of these family semantics.

## `authenticated_at` and sudo: the actual mechanism

`UserToken.build_session_token/1` (`user_token.ex:46`) uses
`user.authenticated_at || DateTime.utc_now(:second)`. A session lookup projects
the row's time into the virtual user field (`verify_session_token_query/1`, `:63`).
Generating another session from that loaded user therefore **preserves** recency.

For a confirmed user, `Accounts.login_user_by_magic_link/1`
(`accounts.ex:240–242`) deletes the consumed login token and returns the user.
It does **not** advance `authenticated_at`. Its query selects `{user, token}`
(`user_token.ex:117`), leaving the virtual field nil. Only the following session
creation supplies the current time. If Tips accidentally passes a session-loaded
user to session creation after reauthentication, it will silently **preserve the
old time**. [#45](https://github.com/chenghanlee/tips/issues/45) must guard this
handover while retaining the same browser family.

The fixture's `generator session reissue preserves authenticated_at; magic-link
reauthentication advances it` test follows amendment A3:

1. Create confirmed user/session A with recency one hour in the past.
2. Load A through Accounts and create B from that user; B's persisted time equals
   A's and its loaded user is outside sudo mode.
3. Consume a real magic link for that account; assert the returned user has nil
   recency. Create C from that user; its persisted time is later and its loaded
   user is in sudo mode. The login link cannot be consumed again.
4. A and B still authenticate, exposing the generator's lack of family revocation.

No sleeps or clock mocks are used. Only timestamps are backdated in the sandbox.
The fixture exercises the Accounts mechanism; it is not a cookie/family race test.

Settings uses `on_mount {UserAuth, :require_sudo_mode}`
(`lib/tips_web/live/user_live/settings.ex:4`), hence the explicit ten-minute mount
window, and `handle_event("update_email", ...)` (`:114–117`) checks the default
20-minute window again. Accounts' current `update_user_email/2` has no internal
sudo check. Keep recent authentication when moving authorization to the #102
Accounts boundary; do not treat a cached scope as permanent permission.

## Routes, registration and confirmation

All routes below are in `lib/tips_web/router.ex`; its browser pipeline (`:11–18`)
fetches sessions/scopes and installs CSRF and secure-browser-header plugs.

| Route | Generated handler / protection |
|---|---|
| `GET /users/register` (`:76`) | `UserLive.Registration`, `:mount_current_scope` live session (`:74–75`). |
| `GET /users/log-in` (`:77`) | `UserLive.Login`, same live session. |
| `GET /users/log-in/:token` (`:78`) | `UserLive.Confirmation`, same live session. |
| `POST /users/log-in` (`:81`) | `UserSessionController.create/2`, accepts magic link **or password**. |
| `DELETE /users/log-out` (`:82`) | `UserSessionController.delete/2`. |
| `GET /users/settings` (`:64`) | `UserLive.Settings`, authenticated Plug and `:require_authenticated` live session (`:60–63`), plus the Settings sudo mount. |
| `GET /users/settings/confirm-email/:token` (`:65`) | Same protections; `Settings.mount/3` confirms the email. |
| `POST /users/update-password` (`:68`) | Authenticated Plug; `UserSessionController.update_password/2` checks sudo. Must be removed by #160. |

`Registration.handle_event("save", ...)`
(`lib/tips_web/live/user_live/registration.ex:58`) calls `Accounts.register_user/1`
(`accounts.ex:77`), which inserts an email-only user through `User.email_changeset/3`
(`lib/tips/accounts/user.ex:26`). It then delivers a login link. There is no
handle, Turnstile or separate registration table; [#43](https://github.com/chenghanlee/tips/issues/43)
owns the one-form signup adaptation.

`Confirmation.mount/3` (`lib/tips_web/live/user_live/confirmation.ex:76`) checks
the magic link for display; the form posts the token to the controller for
consumption. In `login_user_by_magic_link/1`, the password-safety guard starts
at `accounts.ex:225`, while the normal `confirmed_at: nil` branch is at **`:235`**.
That branch calls `User.confirm_changeset/1` (`user.ex:112`) and
`update_user_and_delete_all_tokens/1` (`accounts.ex:286`), transactionally confirming
the user and deleting all their tokens. The controller disconnects returned
tokens before logging in (`user_session_controller.ex:19–23`).

**No seven-day unconfirmed-registration expiry exists in the generator.**
A fresh login link can confirm an old registration. [#44](https://github.com/chenghanlee/tips/issues/44)
must guard both `register_user/1` (`:77`, reclaim conflicts) and the normal
unconfirmed branch (`:235`, confirmation), sharing guarded cleanup. The design
requires locking/rechecking the same user row and immutable original
`users.inserted_at + 7 days` deadline after lock waits. Resends must not extend
it, and cleanup must not delete a confirmed account. This probe adds no hook.

## Email change

`Settings.handle_event("update_email", ...)` (`settings.ex:114`) checks sudo,
validates the proposed email and passes a changed in-memory user plus the original
email to `Accounts.deliver_user_update_email_instructions/3` (`accounts.ex:258`).
The current login address stays in the database. That function persists the
hashed `"change:<original email>"` token, with the proposed address as `sent_to`,
then calls `UserNotifier.deliver_update_email_instructions/2`
(`lib/tips/accounts/user_notifier.ex:24`). Login mail uses
`Accounts.deliver_login_instructions/2` (`accounts.ex:269`) and notifier `:44`,
which selects confirmation wording for unconfirmed users. Delivery is synchronous;
[#50](https://github.com/chenghanlee/tips/issues/50) owns timeout/limiter/provider
failure handling, and the fixture uses Swoosh's test adapter, not a real provider.

`Settings.mount/3` (`settings.ex:73`) calls `Accounts.update_user_email/2`
(`accounts.ex:119`). Its transaction verifies the change-email context/age,
updates the supplied user's email with uniqueness validation, and removes that
user's tokens in the original change-email context. The lookup itself has no
explicit `user_id` predicate (`user_token.ex:143`); it does not yet implement the
full account/original-email/deletion recheck required by #102. It also does not
revoke session rows, start a fresh family or broadcast family disconnects.
Old login links fail the email-match query after the address changes, but that
is not all the required revocation behavior.

[#102](https://github.com/chenghanlee/tips/issues/102) owns the guarded request and
confirmation operations, stable account identity, account-bound proof, old-link
invalidation, revoking all prior session families and creating a fresh family
for the confirming browser. Retain the seven-day hashed-token format and sudo
requirement. Failed confirmation must leave email and sessions unchanged.

## Password paths that must be absent from Tips

[#160](https://github.com/chenghanlee/tips/issues/160) records this inspection's
bounded follow-up. The generated registration form is email-only, but the rest
of the password surface exists today:

| Layer | Generated paths to remove together |
|---|---|
| Accounts | `lib/tips/accounts.ex:41,146,164`: `get_user_by_email_and_password/2`, `change_user_password/3`, `update_user_password/2`; review the password-specific guard at `:225`. |
| User/schema | `lib/tips/accounts/user.ex:7–8,74,81,92,123`: password fields, changeset, validation, hashing and verification. Coordinate migration `:9` (`hashed_password`) with #25. |
| Controller/router | `lib/tips_web/controllers/user_session_controller.ex:33,49`: password `create/3` clause and `update_password/2`; `lib/tips_web/router.ex:68`: password-update route. |
| LiveViews | `login.ex:62,110`: password form/event; `settings.ex:33,89,135,147`: password form, mount dependency and events; `confirmation.ex:67`: password promotion. All are under `lib/tips_web/live/user_live/`. |
| Tests/dependencies | Password tests in `test/tips/accounts_test.exs`, `test/tips_web/controllers/user_session_controller_test.exs`, `test/tips_web/live/user_live/{login,settings,confirmation}_test.exs`; password helpers in `test/support/fixtures/accounts_fixtures.ex:13,53`; bcrypt dependency in `mix.exs:43` and test cost config in `config/test.exs:4`. |

Removal must keep magic-link registration/login, email change, session timestamps
and their tests working. No password reset or OAuth replacement is in scope.

## Executable evidence and limits

The fixture was written and run **before this document**, against unchanged
production code. Its initial run passed: this is an inspection of existing
behavior, not a production behavior change requiring an invented failing test.
Each lifetime test names the generator default so the 60-day adaptation must
update the 14-day baseline assertion deliberately.

| Acceptance evidence | Fixture / existing coverage |
|---|---|
| 14-day generated sessions | `generator 14-day sessions are valid at 13 days and invalid at 15 days`. |
| 15-minute generated magic links | `generator 15-minute magic links are valid at 14 minutes and invalid at 16 minutes`; checks lookup and expired login. |
| Seven-day generated email change | `generator 7-day email-change links update the email at 6 days` and `generator 7-day email-change links leave the email unchanged at 8 days`. |
| A3 preservation/advance | `generator session reissue preserves authenticated_at; magic-link reauthentication advances it`; persisted rows, Accounts reloads, sudo and consumed proof. |
| Default 20-minute sudo window | `test/tips/accounts_test.exs:90–106`: accepts 19 minutes, rejects 21 minutes and nil recency, and checks the ten-minute override. |
| Existing Plug/cookie/reissue behavior | `test/tips_web/user_auth_test.exs:24,37,47,78,121,197,296`; generated tests cover session writes/clearing, remember-me cookie, logout, reissue and sudo. |
| Production auth consumer flows | `test/tips/accounts_test.exs`, `test/tips_web/controllers/user_session_controller_test.exs`, `test/tips_web/live/user_live/*_test.exs`. |

The seven-day reissue threshold and 14-day cookie `max_age` belong to the web
layer, outside this Accounts fixture. Their source inspection and existing
`UserAuth` tests above provide the baseline evidence.

Exact local commands, from `.worktrees/24-auth-baseline` on Elixir 1.20.4 / OTP 29.1:

```sh
codex mcp get elixir-lsp --json
pwd
export TIPS_DB_SUFFIX=_24
export TIPS_TEST_PORT=4024
export MIX_ENV=test
unbuffer mix format test/tips/accounts/auth_baseline_test.exs
unbuffer mix test test/tips/accounts/auth_baseline_test.exs --trace
unbuffer mix compile --warnings-as-errors
unbuffer mix format --check-formatted
unbuffer mix credo --strict test/tips/accounts/auth_baseline_test.exs
unbuffer mix test
python3 scripts/check_docs.py
git diff --check
```

LSP configuration and shell cwd both resolved to
`/Users/chenghanlee/Software_Projects/tiny_big_agents/tips/.worktrees/24-auth-baseline`.
Expert resolved `Tips.Accounts.generate_user_session_token/1` in that worktree and
returned zero published fixture diagnostics, with no document version (not a
freshness guarantee). Formatting, compile and scoped strict Credo passed. The
focused fixture passed **5 tests**; the full local suite passed **129**, with
**3 browser tests excluded**. Initial dependency compilation emitted upstream
warnings but succeeded. Database: `tips_test_24`, existing extension-enabled
PostgreSQL at `localhost:5433`; endpoint: `4024`.

The lifetime samples intentionally avoid clock-boundary flakiness; exact cutoff
and concurrent family/cookie race tests remain #45/#46. No real-provider delivery
or browser gate is claimed by the local fixture. The existing `checks` CI job
runs `mix test --include browser --trace` and will discover this fixture normally;
CI results and independent review verdicts are recorded on the PR, not assumed here.
