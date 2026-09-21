# External prerequisites

Inventory for [#48], recorded on 2026-09-22. Each row names the consuming work,
the access path and the next accountable action. **Available** means access or
an artifact is recorded; it does not mean a provider gate passed. **Missing**
means availability has not been established in the linked evidence, not that
the user necessarily lacks an account.

The user owns account access, purchases, hosting/domain decisions, operator
designation and production content. `lead-tpm` coordinates requests through the
team TPM. Agents propose the concrete service, scope and dated cost estimate
before any purchase; only the user selects material spending. This inventory
does not authorize purchases, account creation or provider calls.

## Access paths and configuration

- **Local secret store:** `~/.config/tips/secrets.env`, recorded as mode 600 in an
  owner-only directory by the [OpenRouter access record]. Only an explicitly
  authorized consuming task may load its scoped credentials. This inventory
  did not read, print, source or verify secret values or inspect that file.
- **CI secret store:** GitHub Actions secrets, installed by the owner with
  `gh secret set` for explicitly invoked real-provider workflows. [#49] owns
  installation, rotation, redaction and feature-specific runtime validation.
  Ordinary PR CI must not receive production secrets or run real providers.
  Record invocation authorization on the consuming dispatch or workflow run.
- **VPS secret store:** the release environment file; location, permissions and
  loading mechanism are TBD in [#49]. Registry login uses the host's credential
  store and `docker login --password-stdin`, as specified in [toolchain.md].
- The configuration column contains **environment variable names only**. `TBD
  (#49)` means the name is unresolved, not an invented configuration contract.
  Human decisions need no environment variable. Provider hosts and resource
  requirements appear in the next-action column; secret values never belong in
  this document, an issue, a PR, evidence or a handoff.

## Prerequisite matrix

| Item | Needed-by issues | Nonsecret configuration (env names only) | Access path | Status / evidence | Owner | Next action |
|---|---|---|---|---|---|---|
| GitHub repository and ordinary CI | [#49], [#96], [#133], [#136] | `GITHUB_TOKEN` | GitHub repository permissions; workflow-scoped token | Available: [CI foundation #36]; no production provider access implied | Team TPM / tech lead | Keep ordinary checks independent of provider secrets; review authorized provider invocations separately. |
| Published GHCR database image | [#123], [#130] | None; image reference is documented | GHCR; authenticated host pull is the separate row below | Available: published amd64 manifest in [toolchain.md] and [publication run] | Tech lead | Deploy the recorded manifest digest; publication does not prove authenticated pull. |
| VPS pull credential for private GHCR image | [#123], [#130] | TBD ([#49]) | User installs package-read credential in VPS credential store | Missing: [#173] — [toolchain.md] records unauthorized anonymous pull and no completed authenticated pull | User | Supply a package-read credential through the secret store; authorize an authenticated pull of the published digest on the intended host and record a redacted result. |
| Intended single VPS / preproduction host | [#52], [#96], [#119], [#123], [#130] | TBD ([#49]) | User-granted host administration; release secret store | Missing: [#174] — no host/access record in [#48] | User | Select the host after reviewing a concrete capacity/cost proposal; provide scoped operator access. The intended VPS is preproduction for the M1 auth gate as well as the later operational rehearsal. |
| Application domain, Cloudflare DNS and proxy | [#119], [#50], [#52], [#130], [#136] | TBD ([#49]) | User-granted Cloudflare zone administration; scoped credentials in secret store | Missing: [#175] — domain/zone not recorded in [#48] | User | Select the domain and grant DNS/proxy access for TLS, origin restrictions and mail DNS records; approve any registration expense first. |
| Cloudflare Turnstile site and secret keys | [#43], [#52] | TBD ([#49]) | Local / CI / VPS secret stores; site configuration supplied separately | Missing: [#176] — [#48] / [toolchain.md] | User | Supply site configuration for the selected host and a scoped secret; [#52] must prove real validation and invalid-challenge rejection. [#43] uses [#49] config names and local contract tests without real keys. Required widget host is exactly `https://challenges.cloudflare.com`. |
| R2 media bucket and API access | [#61], [#70], [#84] | TBD ([#49]) | Scoped R2 credentials in local / CI / VPS secret stores | Missing: [#177] — [#48] | User | Provide the selected bucket/account/endpoint metadata and scoped object access, including put/list/delete for isolated fixtures and cleanup. [#61] proves provider semantics before lifecycle code. |
| Cookie-free media delivery domain and cache-purge access | [#61], [#70], [#84], [#130] | TBD ([#49]) | User-granted domain/zone access; purge credential in secret store | Missing: [#178] — [#48] / [toolchain.md] | User | Designate the cookie-free R2 media origin and grant scoped cache-purge access. Consumers must prove deletion/purge behavior; domain ownership alone is insufficient. |
| Stream account/API access, customer code and signing key | [#61], [#70], [#86] | TBD ([#49]) | Scoped Stream API/signing credentials in local / CI / VPS secret stores | Missing: [#179] — [#48] / [toolchain.md] | User | Supply account access for create/status/delete, customer code and signing material. Configure only `https://customer-<CODE>.cloudflarestream.com`; [#61] proves private-from-reservation upload and signed playback before later gates. |
| Authentication email provider and sender domain | [#50], [#52] | TBD ([#49]) | User selects provider; scoped delivery credential in secret store; DNS via domain row | Missing: [#180] — [#48] | User | Choose the provider after a concrete volume/cost proposal; provide sender/domain verification and scoped delivery access. [#52] records real acceptance and failed-delivery feedback, without claiming guaranteed inbox delivery. |
| OpenRouter hosted embedding access | [#54], [#60] | `OPENROUTER_API_KEY` | Local secret store; future authorized CI / VPS installation via [#49] | Available by [OpenRouter access record], not reverified here; [owner decision #142] | User (credential); search task owner (probe) | Evaluate Qwen3-Embedding-8B at 1024 output dimensions in [#54], including endpoint support, preparation, measured quality, limits and cost; [#60] owns integrated evidence. Key availability is not a passed gate or purchase authorization. |
| CI / release secret installation mechanism | [#49]; real-provider [#52], [#60], [#70], [#84], [#86] | Per-provider names TBD ([#49]); known name above | GitHub Actions secrets / release environment file | Available: local access and CI handoff method recorded in [OpenRouter access record]; CI/VPS installation unverified | User (installation); [#49] owner (contract) | Implement scoped loading/rotation and redacted errors in [#49]; record each provider's readiness separately. No additional provider account is implied. |
| Sentry error reporting access | [#122], [#130] | TBD ([#49]) | User-granted Sentry project access; DSN in secret store | Missing: [#181] — [#48] | User | Supply the project/DSN and alert ownership; [#122] verifies sanitization, exhausted-failure reporting and reporting-outage behavior. |
| Uptime monitoring and independent background-progress invocation | [#121], [#130] | TBD ([#49]) | User-granted monitoring access; scoped endpoint credentials in secret store if needed | Missing: [#182] — [#48] | User | Provide Sentry uptime access and an alert recipient; authorize the external invoker owned by [#121]. Its progress check must run outside Oban and detect stopped queues while app/DB remain healthy; no extra provider is selected here. |
| Private R2 backup storage and seven-day retention | [#123], [#130] | TBD ([#49]) | Separate private backup bucket; scoped credentials in VPS secret store | Missing: [#183] — [#48] | User | Provide private backup storage separate from public media delivery, with seven-day retention and restore access. [#123] proves nightly backup, retention and restore into a distinct database before real content. |
| Designated verified operator / moderator | [#106], [#130], [#134], [#136] | None (human designation) | User supplies account designation privately to the operator; existing authentication flow | Missing: [#184] — [#48] | User | Designate the actual verified account and recovery/incident owner; [#106] performs the explicit release-only bootstrap. Do not put private identity details in this matrix or expose signup role selection. |
| Owner-reviewed production vocabulary | [#132], [#134], [#136] | None (reviewed content) | Owner review recorded on the consuming issue | Missing: [#185] — production model/environment approval not recorded; [#26] provides production tags and synthetic dev/test models/environments | User | Review the proposed technique/model/environment vocabulary before production use, retaining Other technique. Synthetic [#26] / [#79] schema and editor work stays unblocked. |
| Firsthand founder / contributor content | [#132], [#134], [#136] | None (authored content) | Actual authors submit through normal forms | Missing: [#187] — no owner-confirmed production submissions in [#132] | User | Supply genuine firsthand examples through the product; label test fixtures as synthetic and never present generated experiences as production submissions. |
| Contributor recruitment and trial participation | [#132], [#134], [#136] | None (human readiness) | Owner-managed invitations and participant coordination | Missing: [#188] — no owner-confirmed recruitment in [#132] | User | Identify and recruit trial contributors; keep public signup open without invitation codes or approval queues. [#134] tracks noindex and the weekly twenty-nonstaff-visitors criterion without a new analytics platform. |

## Gate boundaries

- **M1 [#96]:** [#52] consumes Turnstile, mail and the selected host/domain
  configuration; [#54] / [#60] consume OpenRouter; [#61] / [#70] / [#84] / [#86]
  consume R2, media delivery/purge and Stream. Feature-specific probes [#54] and
  [#61] can run in isolation when their access and explicit authorization exist;
  neither requires unrelated providers or a deployed release. Integrated gates
  use [#49] and must record real-provider evidence on one revision.
- **M3 [#133]:** [#130] consumes the intended host/domain, authenticated GHCR
  pull, operator, private backup/restore, monitoring and media cleanup evidence.
  [#121] owns the independent invoker; [#122] owns sanitized reporting; [#123]
  owns private seven-day backup retention. No missing prerequisite counts as a
  successful operational rehearsal.
- **M4 [#136]:** [#132] / [#134] consume approved vocabulary, authentic content,
  contributors and operator readiness alongside the M3 evidence. The owner
  decides launch. This inventory makes no launch or live-smoke claim.

Missing access blocks its consuming real-provider or production step only.
Local schema, synthetic fixtures, contract tests and unrelated provider work
continue. A supplied key, published artifact or successful stub never replaces
a gate result. External access issues remain separate from mandatory completion
children of [#48], so this inventory can close while user actions remain Blocked.

## Verification

This is a documentation contract, with no application test or provider probe.
The reviewer checks every row against its consuming issue and the M1/M3/M4 gates,
and verifies each linked user-action issue is open, labelled `kind:contract` and
actually **Blocked** in [Project 15], with prerequisite, user owner and next action.

```sh
python3 scripts/check_docs.py
rg -q '(sk|key|token|secret)[-_]?[A-Za-z0-9]{20,}' -- docs/implementation/prerequisites.md docs/implementation/implementation-plan.md
test $? -eq 1
gh issue view <number> --repo chenghanlee/tips --json state,labels,body
gh project item-list 15 --owner chenghanlee --limit 1000 --format json
```

The quiet scan must return no-match (exit 1); an error is not a pass. It is only
a heuristic and accompanies manual review of these documents. Do not print a
matching value. `check_docs.py` checks inline local links; this matrix's reference
definitions and target anchors require separate manual review. No secrets or
provider resources were used; no cleanup is due.

[toolchain.md]: toolchain.md#p006-image-implementation-and-evidence
[publication run]: https://github.com/chenghanlee/tips/actions/runs/35535359371
[CI foundation #36]: https://github.com/chenghanlee/tips/issues/36
[OpenRouter access record]: https://github.com/chenghanlee/tips/issues/48#issuecomment-5752341894
[owner decision #142]: https://github.com/chenghanlee/tips/issues/142
[Project 15]: https://github.com/users/chenghanlee/projects/15
[#26]: https://github.com/chenghanlee/tips/issues/26
[#43]: https://github.com/chenghanlee/tips/issues/43
[#48]: https://github.com/chenghanlee/tips/issues/48
[#49]: https://github.com/chenghanlee/tips/issues/49
[#50]: https://github.com/chenghanlee/tips/issues/50
[#52]: https://github.com/chenghanlee/tips/issues/52
[#54]: https://github.com/chenghanlee/tips/issues/54
[#60]: https://github.com/chenghanlee/tips/issues/60
[#61]: https://github.com/chenghanlee/tips/issues/61
[#70]: https://github.com/chenghanlee/tips/issues/70
[#79]: https://github.com/chenghanlee/tips/issues/79
[#84]: https://github.com/chenghanlee/tips/issues/84
[#86]: https://github.com/chenghanlee/tips/issues/86
[#96]: https://github.com/chenghanlee/tips/issues/96
[#106]: https://github.com/chenghanlee/tips/issues/106
[#119]: https://github.com/chenghanlee/tips/issues/119
[#121]: https://github.com/chenghanlee/tips/issues/121
[#122]: https://github.com/chenghanlee/tips/issues/122
[#123]: https://github.com/chenghanlee/tips/issues/123
[#130]: https://github.com/chenghanlee/tips/issues/130
[#132]: https://github.com/chenghanlee/tips/issues/132
[#133]: https://github.com/chenghanlee/tips/issues/133
[#134]: https://github.com/chenghanlee/tips/issues/134
[#136]: https://github.com/chenghanlee/tips/issues/136
[#173]: https://github.com/chenghanlee/tips/issues/173
[#174]: https://github.com/chenghanlee/tips/issues/174
[#175]: https://github.com/chenghanlee/tips/issues/175
[#176]: https://github.com/chenghanlee/tips/issues/176
[#177]: https://github.com/chenghanlee/tips/issues/177
[#178]: https://github.com/chenghanlee/tips/issues/178
[#179]: https://github.com/chenghanlee/tips/issues/179
[#180]: https://github.com/chenghanlee/tips/issues/180
[#181]: https://github.com/chenghanlee/tips/issues/181
[#182]: https://github.com/chenghanlee/tips/issues/182
[#183]: https://github.com/chenghanlee/tips/issues/183
[#184]: https://github.com/chenghanlee/tips/issues/184
[#185]: https://github.com/chenghanlee/tips/issues/185
[#187]: https://github.com/chenghanlee/tips/issues/187
[#188]: https://github.com/chenghanlee/tips/issues/188
