# Fresh Elixir/Phoenix idioms review — overall architecture

Date: 2026-09-20. Status: consensus after two paired rounds; signed playback adopted by the owner.

## Review agreement

Review the current revised documents in `docs/design/technical/`, including `data-model.md` for cross-document consistency. The existing `idioms-*-review.md` records are prior history, not proof that a choice is correct. No Mix project, Elixir source or frontend implementation was found: this is a design and proposed-implementation review, not a runtime audit. Do not modify source design documents during this review.

Codex uses a José Valim-inspired lens: plain functions/data, explicit effects, justified process lifetimes and minimal mechanisms. Fable in Herdr pane `wJ:p1` uses a Chris McCord-inspired lens: Phoenix/LiveView conventions, framework facilities and complete browser/product behavior. Neither is the real person's analysis or endorsement.

Review phases sequentially: architecture, backend, frontend. Each phase ends at explicit bilateral consensus or ten paired rounds; record unresolved objections at the cap. Append under your own reviewer heading. Independently inspect evidence, then challenge each other's finding and proposed remedy. A recommendation must survive local correctness, direct/downstream effects and whole-system fit.

For each unusual/complex choice, ask 5–15 whys, stopping when two more do not change the root answer. Apply first principles, Occam's razor and Pareto's 80/20: identify the smallest working solution and the machinery it actually removes. Distinguish a convention violation, a justified exception, an implementation hazard and an optional product change. Product rules can be challenged, but label the behavior lost; do not call a scope cut equivalent. Use current primary framework/provider evidence for uncertain claims. Do not manufacture findings or consensus for round-count targets.

## Reviewed source snapshot

- `backend-design.md`: `e3261d493121aa1a79341fa05857159ab273e038e470398d92abada897f98385`
- `data-model.md`: `c4d39dea77f51083c521e85f78959bad8d8fdbd34d14322b52d1b9346386940d`
- `frontend-design.md`: `5719aec9214cfec9cd1ad35bcf095bd4c0dd5051f723841b53a6b83b6ab8d0f8`
- `software-architecture.md`: `97d6cb9d65cd9584b4363bbcb0c26c8843fcf4b875c21c82a66500c329b0021f`

## Codex (Valim lens) — Round 1

### A-J1 — Medium: eliminate the design's manual amendment layer

Evidence: architecture :17, backend :137–150 and data-model :3, :11, :19, :32. Backend now replaces domains, edit-upload identity, lock discovery and version mechanics, while the data model still calls itself the current contract and contains the old schema/flows. The stated precedence resolves authority on paper, but implementers must mentally patch one specification with another. No source implementation exists to settle a disagreement automatically.

Whys: (1) Why can two readers build different migrations? They can start from different current-looking specifications. (2) Why the amendment table? The prior task revised three documents without rewriting the fourth. (3) Why is precedence insufficient as the lasting design? It tells readers which text wins but not where every dependent query/example changed. (4) Why keep old examples as active baseline? There is no implemented compatibility requirement. (5) Why not one current schema/flow description? Nothing prevents reconciling the data model once. (6) Why another manifest/generator? That would automate a maintenance process we can remove. (7) Why stop? One normative description per fact removes the root duplication.

**First principles/Occam/80–20:** reconcile the data model to the accepted current design, replace the amendment table with a link to its canonical schema/flows, and archive historical SQL/results clearly outside normative sections. Keep architecture about boundaries and backend about operation orchestration. No new tooling or dependency. This is a documentation/implementation-risk finding, not a Phoenix runtime defect. Direct effect: migration authors need no manual overlay. Whole-system effect: frontend/backend recovery and transaction tests reference the same invariants.

### A-J2 — Medium investigation: search's extra database extension has not yet earned its deployment restriction

Evidence: data-model :800–803 says historical tests skipped both search extensions, :952 defers fusion changes until extension testing, :961 excludes several hosts because of pg_textsearch; architecture :133–149 retains the extension image and local embedding runtime with later evaluation. This is a specialized product choice, not inherently an Elixir anti-pattern. The deployment dependence currently rests on an unexecuted integration/quality gate.

Whys: (1) Why two search extensions plus an inference runtime? Keyword and meaning-based discovery are required. (2) Why does that require this particular keyword extension? BM25 was selected as a ranking strategy. (3) Why exclude otherwise suitable hosts before comparing quality? The strategy has become a platform constraint before full-stack measurement. (4) Why not use PostgreSQL's built-in text search alongside pgvector? It may satisfy the task with one fewer extension, but its ranking is not identical. (5) Why not simply drop semantic search? That cuts an agreed capability and does not isolate the keyword-extension cost. (6) Why not keep multiple search implementations? That adds permanent branches instead of making one evidence-based choice. (7) Why stop? The root is an unvalidated ranking/platform tradeoff, not a missing Elixir abstraction.

**Candidate, not a proven replacement:** at the existing search evaluation gate, compare the chosen pg_textsearch pipeline against native PostgreSQL full-text search + the existing vector branch on the same task queries, filters, excerpts and resource budget. Prefer the simpler pipeline only if it meets the agreed relevance and latency needs; retain one production implementation. Keep hybrid search and the embedding runtime unless separately justified. Ranking behavior changes, so this is a measured implementation alternative, not an assertion of identical results. If Fable shows that the extra experiment costs more than it can save for this deployment, withdraw the mandatory comparison and retain it only as a fallback for a concrete extension blocker.

### A-J3 — Keep: ordinary contexts and explicit transaction owners are already idiomatic

Evidence: architecture :36–76, :110–124; backend :157–200. Accounts and Content are plain modules; helpers are optional; the web calls public operations; unban has one transaction owner; Oban manages durable work and LiveView manages page state.

Whys: (1) Why might Content look oversized? It names many related content operations. (2) Why would splitting contexts help? Only if independent ownership or reuse exists. (3) Why create a context per table now? There is no such need. (4) Why a process per feature? Functions do not need serialized runtime ownership. (5) Why a workflow/facade framework? Existing transactions already own the effects. (6) Why change the monolith? No independent deployment requirement was identified. (7) Why stop? The remaining boundaries follow real lifetimes, not arbitrary layers.

**Disposition:** no umbrella, domain-process model, generic repository, authorization framework or context-per-table expansion. Keep Ecto, narrow database invariants and Oban in one release. A SQL trigger is not a convention violation merely because it is outside an Ecto changeset. Assess its whole write graph in phase 2. Relevant primary guidance: [Phoenix contexts](https://phoenix.hexdocs.pm/contexts.html) and [Elixir process anti-patterns](https://elixir.hexdocs.pm/process-anti-patterns.html).

### A-J4 — Keep feature complexity visible; resolve provider uncertainty before building a general recovery mechanism

Evidence: architecture :58, :139–149; backend :277–315. Media crosses browser, database and provider lifetimes; it is the largest remaining stateful feature. The current design correctly says provider correlation recovery must be proved, yet several later rules already presume that it is usable.

Whys: (1) Why media needs more states than text? Upload, processing, publication and deletion are separate effects. (2) Why retries? A remote effect can succeed without a local confirmation. (3) Why a general provider-recovery system? It is not automatically necessary for every phase. (4) Why distinguish provisioning from publication? An upload endpoint is released only after its uid is persisted; a never-released endpoint cannot have been used by this app's browser. (5) Why care? That ordering may let unused reservations expire instead of requiring arbitrary remote asset rediscovery. (6) Why not declare this safe immediately? Provider expiration/reservation behavior must be established. (7) Why stop? The smallest recovery boundary depends on the actual protocol, not an abstract distributed-state machine.

**Carry to phase 2:** inspect the provider protocol and narrow recovery obligations to externally reachable effects. Do not add a general reconciliation service, second scheduler or framework. Retain private drafts and native video in scope. Deferring native video remains a separately labelled product option, not a finding that Phoenix is unsuitable.

### Proposed phase-1 disposition for challenge

The architecture is cohesive. A-J1 is the concrete new simplification. A-J2 is an explicitly challengeable experiment, not an automatic rewrite. A-J4 bounds the next phase's provider analysis. No architecture rewrite or new architectural dependency is recommended. Fable: challenge these candidates and add independent findings, especially any current lifecycle boundary that our prior review accidentally made more complex.

## Fable (McCord lens) — Round 1

Snapshot hashes verified against the four files before reading. Independent findings first; counter-review of Codex Round 1 follows. Line numbers are from the current files.

### Verdict

The monolith, two contexts, `Repo.transact` per write, Oban in the release, LiveView pages with function components, and browser-only drafts are all conventional Phoenix and need no change. The complexity that remains is concentrated in two places: the video lifecycle, which spans browser, Postgres and Stream, and the search stack, which pins one Postgres image and one self-hosted inference container to a single VPS. Both are architecture-level because they decide which store owns a fact and how many runtimes deploy. Everything else I checked is either conventional or a documentation problem.

### A-F1 — Medium, labelled product alternative: video visibility is decided at the provider, so publication needs a second write cycle

Evidence: backend :220 (activate playback after commit), :230 (ten attempts, snooze, `activation_job_id`, status derived from a left join to the job), :232 (seven-day retention, operator retry from the retained row), :238, :270, :272 ("no expiring public playback tokens for already-public videos"), :448 (unban enqueues first activations); data-model :757–:763; frontend :187. Prior closure item 5 already carries a row-held attempt counter as a phase-2 candidate. This finding is a different, larger alternative that the prior review did not consider: it kept draft privacy and asked how to make the post-commit flip cheaper, not whether the flip is needed.

Whys:
1. Why is there an activation step? A draft video must not be public before its content commits.
2. Why does that need a provider call after commit? Privacy is a per-video flag at Stream (`requireSignedURLs`), and the database cannot flip it atomically with the commit.
3. Why is the post-commit call expensive? It can fail, be retried, race a hide, and lose its confirmation, so the design adds a counted job, a snooze rule, a job id that must survive pruning, an author-visible status derived from job history, an operator retry path, and a public-omission rule.
4. Why must publication flip the flag at all? Because the design chose to serve public videos as bare uid links so that links never expire (backend :272).
5. Why never-expiring links? It follows the image policy: R2 keys stay at their URL after hide. That is a consistency choice, not a stated user requirement.
6. Why does the image policy transfer? It does not have to. Images are already public at upload; videos are private at upload. Two different starting states are being forced to the same ending state.
7. Why not leave every video private and let the app authorize playback? Stream supports app-signed tokens with a local key: no API call per token, tokens valid up to 24 hours, key revocable ([securing your stream](https://developers.cloudflare.com/stream/viewing-videos/securing-your-stream/)). The watch page, iframe, manifests and download all accept the token in place of the uid.
8. Why does that remove the machinery? Publication becomes a database commit only. The page projection signs a token for each live attachment when it renders. Hidden content stops receiving new tokens because the projection already omits hidden media.
9. Why stop? Two more whys land on the same root: visibility should be a database fact rendered on demand, not a provider fact synchronized after the fact. Further whys only re-derive the retry rules that exist to do that synchronization.

First principles: one store owns visibility. Today it is two: `dead_at`/`shadowed_at`/`deleted_at` in Postgres and `requireSignedURLs` at Stream, reconciled by a worker. Occam: keep the media row and the readiness scan; remove `activated_at`, `activation_job_id`, the activation worker, the snooze rule, the ten-attempt budget, the retained-job-id-after-pruning rule, the author Ready/Retrying/Failed status, the public-omission-after-publication rule, the operator activation retry path, and the restore/unban activation enqueues. Add: one signing key in config, one token function, and a per-render signature. 80/20: about ten paragraphs across three documents and two columns go; the readiness and cleanup lifecycle stays as designed.

Behavior changed, stated plainly so the owner can decide:
- A copied watch link expires within 24 hours. Sharing the tip page keeps working because the page re-signs. This drops backend :272 and the "already-public links remain usable" sentences (backend :272, frontend :279).
- Hidden and deleted content's videos stop being playable once outstanding tokens expire. This is stricter than the current image policy and closer to what a reader would expect; it does not change the image policy.
- Playback URLs are per-render, so the "construct video URLs from the customer host and stored uid" sentence (backend :88) becomes "sign a token for the stored uid".
- No author-facing "Retrying/Failed" activation status exists because there is nothing to retry.

This is a product change, not an idiomatic fix, and I label it as such. I recommend it because it removes the largest reconciliation loop in the design while strengthening privacy, at the cost of link permanence. If the owner values permanent direct video links, keep the current design and pursue the phase-2 attempt counter instead. Either way, phase 2 should decide before the media contract is implemented.

### A-F2 — Medium, preserving with a model swap: the embedding container is a production topology inherited from a development convenience

Evidence: data-model :681 ("Development may use the MLX server on the Mac ... Production runs the model next to the app"), :961 (three containers on one VPS), :1001 (decision log: "MLX server locally"); backend :57 (every search request embeds the query synchronously with a bounded timeout); architecture :58 diagram and :133.

Whys:
1. Why a separate embedding server? The chosen model needs an inference runtime the BEAM does not provide for this architecture.
2. Why this model? Quality at small size, per the decision log.
3. Why on the same VPS? The design says "next to the app"; no reason is recorded.
4. Why was it chosen as a local server? The decision log records "MLX server locally", which is a developer-machine convenience.
5. Why is that a problem in production? A 0.6B model on CPU shares cores with Postgres and the app, and it sits on the request path of every search. The data model itself flags "long-document inference and resource limits" as unvalidated, and dev and prod run different runtimes for the same model, which can produce different vectors.
6. Why not a hosted embedding call? The account already depends on Cloudflare for R2, Stream, Turnstile, the proxy and uptime. Workers AI serves `@cf/baai/bge-m3`, a 1024-dimension model, so `vector(1024)` and the HNSW indexes do not change. Other hosted models exist; the point is the runtime, not the vendor.
7. Why is that smaller? One HTTP call replaces a container, model weights, a second runtime to validate, and the CPU contention question. The keyword fallback already covers provider unavailability (backend :60).
8. Why stop? Two more whys return to "the production runtime was never chosen, it was assumed". That is the root.

First principles: the app needs a function `text -> vector` with bounded latency; where it runs is a deployment choice. Occam: the design already has a provider seam with `Req` and bounded timeouts for this call, so the swap is configuration and one client module. 80/20: removes one of three containers and the largest unvalidated resource question from the single VPS. Behavior lost: none reader-facing. Changed: the model, so the agreed ten-query evaluation runs against the hosted model instead; a per-token cost that is negligible at MVP volume; embedding availability becomes a vendor dependency, already tolerated for video and images. Prior closure already said "gate the embedding container on the ten-query evaluation"; this finding says run that gate against the cheaper runtime first, and self-host only if the hosted model fails the gate. Not a product cut. Owner's choice if avoiding any per-call vendor for search is a requirement; none is recorded.

### A-F3 — Medium, documentation: authority is split and the split has already produced contradictions

I agree with Codex A-J1 and add the concrete evidence that it is not hypothetical:

- data-model :747 encodes `{:edit_tip, tip_id, expected_version}` into `target`; backend :143 and :308 remove `expected_version` from the target and the rebind operation. data-model :755 still says "may rebind an owned asset to the reloaded version".
- data-model :753 and :755 describe ready webhooks, signed callbacks and out-of-order callbacks; architecture :58 and backend :276 say the MVP has no Stream webhook endpoint. data-model :969 still tests "late callbacks".
- data-model :3 calls itself "the current design contract"; architecture :17 says its older examples do not override the backend amendments. Two documents claim to be current.
- backend :554–:558 and frontend :259–:263 are the same three paragraphs verbatim (removed-tip titles, review-list filters, "Other technique"). Prior A-J3 asked for this to go; it is still there.

Smallest fix: reconcile the data model once, delete the amendment table in favour of a link, and delete the duplicated tail paragraphs from whichever document does not own them. No tooling.

### Note, not a finding: deployment failure path

Architecture :74 stops the old app, migrates, starts the new one, and says a failed migration must not be declared successful. It does not say what serves traffic then. With "no backwards compatibility" that answer is "nothing, fix forward", which is acceptable for a single-operator MVP. State it in one sentence so the operator is not surprised. No why-chain needed.

### Not re-raised

Per-operation session admission (prior A-F1/item 4): no new evidence, and the ratified wording already allows the smallest mechanism. The context facade sentence (architecture :62): the same paragraph says no wrapper module per helper, which is the Phoenix contexts convention. Search dual-mount retrieval: already single-owner in `handle_params`.

### Counter-review of Codex Round 1

**A-J1 (amendment layer) — accept.** See A-F3 for the contradictions that prove the cost. One addition: the reconciled data model should keep its measured-history section, but move it below a heading that says it describes a superseded schema, so the numbers stop looking like validation of the current one.

**A-J2 (pg_textsearch vs native full-text) — withdraw the mandatory comparison; keep native FTS as a fallback for an extension blocker.** Reasons. The extension is GA, OSS-licensed, ships prebuilt Linux packages and builds from source for Postgres 17/18 ([pg_textsearch](https://github.com/timescale/pg_textsearch)), so the coupling is to "a Postgres image we build ourselves", which Compose on one VPS already implies; it is not a coupling to `timescaledb-ha` specifically. The managed-host exclusion only matters if the database moves off the VPS, which no requirement asks for, and the data model already names Tiger Cloud for that case. The comparison itself is not free: native FTS needs its own `tsvector` column, GIN index and `websearch_to_tsquery` normalization, so the machinery removed is one extension, not a branch. The heavier deployment cost in the search stack is the inference container, not the keyword extension; A-F2 redirects the gate there. If the pinned image fails to build the extension, native FTS is the fallback and the ten-query evaluation reruns then.

**A-J3 (keep contexts) — accept without addition.**

**A-J4 (provisioning recovery) — accept, and I checked the provider claim; the scope can be narrower than "carry to phase 2".** Backend :310 orders the flow: insert the media row with null uid, call Stream, persist the uid, then return the upload URL. Cloudflare's direct creator upload docs state: "If the video errors or is not received before the link expires, the entire reservation will be released" ([direct creator uploads](https://developers.cloudflare.com/stream/uploading-videos/direct-creator-uploads/)). Two failure windows exist: the create call fails or times out before a uid is known, and the uid arrives but its persist fails. In both, the URL was never delivered to a browser, so no bytes can reach that reservation and Stream releases it at its expiry. Therefore a null-uid row needs no provider read and no correlation lookup: after `created_at + 1 hour` it is marked failed and cleanup-eligible locally. This removes "recover a provisioning row through provider correlation with its media id" and "an absent local uid ... is not proof that no completed asset exists" (backend :280), the null-uid branch of the status scan (backend :278), and the "unknown provisioning" acceptance items (backend :551, data-model :969). Two conditions, both settable at creation: pass `expiry` on the reservation equal to the local one-hour deadline, and never retry a timed-out create call against the same row without a fresh reservation, because a duplicate empty reservation is harmless but a reused row is not. Keeping the media id in the reservation `meta` costs nothing and helps an operator; the lookup machinery is what goes. Rows with a persisted uid keep the existing scan and the 48-hour completion window unchanged. Phase 2 should verify the `expiry` metadata default and maximum against the pinned API, which the docs page I fetched does not state; the release-on-expiry rule itself is explicit.

### Proposed phase-1 disposition

1. Architecture is cohesive; no rewrite, no new dependency, contexts and transaction owners unchanged (A-J3).
2. Reconcile the data model once and delete the amendment table and duplicated paragraphs (A-J1, A-F3).
3. Owner decision before phase 2: app-signed playback tokens with no activation step (A-F1, product change: direct links expire within 24 hours) versus the current design plus the phase-2 attempt counter.
4. Run the ten-query search gate against a hosted 1024-dimension embedding model first; self-host only if it fails (A-F2). Keep pg_textsearch; native FTS is the fallback for an extension blocker, not a required experiment (A-J2 narrowed).
5. Null-uid provisioning rows expire locally with no provider read; phase 2 confirms `expiry` semantics (A-J4 narrowed).
6. One sentence on what serves traffic after a failed migration.

Unresolved from my side: none, pending Codex's challenge of A-F1 and A-F2.

## Codex (Valim lens) — Round 2

**A-F1 — accept as a recommended product alternative, not a prerequisite to continue this review.** Leaving Stream private and signing locally removes a real synchronization boundary. I verified the provider's token support and 24-hour maximum in its [primary documentation](https://developers.cloudflare.com/stream/viewing-videos/securing-your-stream/). The existing permanent-link policy is nevertheless an explicit current contract, even if originally inferred from images. We must not silently replace it. Record both branches: preserve the current public-link contract by default; recommend signed playback if the owner accepts expiring copied URLs. Phase 2 can review the current branch now; no owner decision is needed to finish a review. In the signed branch, a long-open LiveView can outlive its token: choose the minimal page-reload/retry behavior explicitly before adding proactive renewal. Do not claim per-render signing alone handles every browser lifetime. Keep author preview authorization, cleanup and upload readiness in either branch.

**A-F2 — accept hosted inference as the first candidate at the existing gate; reject “configuration-only” and “no behavior lost” as proven conclusions.** Equal vector dimensions do not mean compatible embedding spaces or equal retrieval quality. A swap needs the new model's query/document preparation, consistent ingestion and query clients, representative long documents, bounded latency, rate limits, and the same evaluation corpus. Never mix Qwen document vectors with BGE queries. Greenfield implementation can simply start with one chosen model; an existing experiment corpus must be rebuilt. Sending searches and unpublished/nonpublic text to an additional provider changes the data boundary even if no UI capability disappears. Identify what text the existing eligibility rules permit sending. No abstraction framework, model registry or dual-provider failover is justified.

The current [Workers AI model page](https://developers.cloudflare.com/workers-ai/models/bge-m3/) establishes a callable hosted candidate, not fitness for Tips. Its [published pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/) makes a bounded evaluation reasonable; “negligible” still depends on actual volume. Proposed conclusion: evaluate a hosted candidate first using the existing relevance/latency/input-size gate, then choose one runtime; keep self-hosting if the candidate fails or sending search text off-box is unacceptable. This is a conditional simplification, not a verified production replacement.

**A-J2 — withdraw the mandatory native-FTS comparison.** Fable is right that it expands the experiment without a present hosting blocker. Keep the pinned extension integration test; use [native PostgreSQL text search](https://www.postgresql.org/docs/current/textsearch.html) as a fallback only if a concrete extension/build/deployment problem appears. No parallel production search path.

**A-J1/A-F3 — accept and consolidate.** Reconcile the data model, keep measured history labelled as superseded rather than evidence for the new design, remove duplicated normative paragraphs from the non-owning document. A deployment failure sentence is useful documentation, not a new workflow.

**A-J4 — agree on null-uid simplification, with one race to close in phase 2.** Expiry must serialize with late provisioning persistence. Persist the uid and authorize releasing the URL only if the original row remains eligible and the original deadline has not elapsed. If a delayed provider response loses that guard, never expose its URL. A persisted uid is never cleared back to NULL. NULL means never released, not “unknown uploaded asset”. The provider promises reservation release on expiry, not necessarily deletion of all empty metadata; do not overstate that guarantee. No provider correlation search is needed to protect browser-uploaded bytes in this branch.

**Consensus proposal:** retain the monolith; reconcile documentation; conditional hosted-embedding evaluation; native FTS only as a blocker fallback; signed playback as an explicitly labelled product alternative; narrow null-uid recovery with the guard above. No rewrite or product change is applied. Please ratify or identify a remaining objection, then begin backend Round 1 in its shared file.

### Owner decision during Round 2 — signed playback adopted

The owner chose signed playback to reduce video machinery, accepting minimal downside. A-F1 is now the selected recommendation, not a pending option: keep Stream assets private and generate authorized playback tokens locally. Copied direct URLs expire within 24 hours; stable tip/review links remain shareable. Specify a refresh/retry path for expired links on long-open pages. Remove provider public-activation state/jobs, attempt accounting and author activation status. Upload readiness, authorized draft previews and durable deletion remain. This supersedes Round 2's default of preserving permanent provider links. The design documents have not yet been revised by this review.

## Fable (McCord lens) — Round 2: ratification and phase-1 closure

**Ratified.** I accept Codex Round 2 in full, with the owner decision above applied to A-F1. Three precisions and one correction.

**Correction to my Round 1.** I wrote that phase 2 could "pursue the phase-2 attempt counter" as the alternative to signed playback. That candidate was withdrawn in the prior backend review (Fable Round 2 concession to B-J2: the final in-flight attempt cannot be distinguished from Failed without a job link). It was not open, and my sentence should not be read as reopening it. Under the selected signed-playback branch the question is moot: there are no activation attempts to own.

**A-F1, long-open pages.** Do not embed tokens in rendered HTML. Route every playback through one controller action, for example `GET /media/:id/watch`, that checks current visibility and caller authorization, signs a token with a short expiry, and redirects to Stream. Consequences: the link a reader copies from the page is the stable app URL, so the 24-hour expiry applies only to a Stream URL copied from the address bar after the redirect; a page open for days needs no renewal because signing happens at click time; hidden or deleted content stops resolving on the next click; author draft previews use the same route under owner authorization. Machinery: one route, one signing function, one key in config created once through the Stream keys endpoint. This is the minimal refresh behavior Codex asked for, and it removes per-render signing rather than adding renewal.

**A-F2, data boundary.** The embedding scan joins `live_tips`/`live_reviews` (data-model :164), so hidden, deleted and shadowed text never reaches the embedding runtime in either branch, and browser drafts are never on the server. The only text that newly leaves the box under a hosted model is the reader's query string. All other qualifications accepted: same corpus, same preparation for ingestion and query, no mixed vector spaces, pricing checked at actual volume.

**A-J4, guard.** Persist the uid with a conditional write: `where id = $1 and stream_uid is null and cleanup_at is null and created_at + interval '1 hour' > now()`. Zero rows means the URL is never returned and the reservation expires at the provider. A persisted uid is never cleared. Set the reservation `expiry` equal to the local deadline; phase 2 confirms the metadata default and maximum against the pinned API.

### Phase 1 closure

1. One Phoenix release, `Tips.Accounts` and `Tips.Content`, explicit transaction owners, Oban in the release, LiveView pages with function components, browser-only drafts. No rewrite, no new dependency, no context split (A-J3).
2. Reconcile the data model once; delete the backend amendment table in favour of a link; delete the duplicated tail paragraphs from the non-owning document; label measured history as superseded (A-J1, A-F3).
3. Owner decision adopted: Stream assets stay private for their whole life; the app signs playback through a redirect route at click time. Activation jobs, `activated_at`, `activation_job_id`, snooze, attempt budget, author activation status, public omission after publication, operator activation retry and the unban/restore activation enqueues are removed. Readiness scan, authorized previews, 48-hour/1-hour deadlines and durable deletion remain (A-F1).
4. Evaluate a hosted 1024-dimension embedding model first at the existing ten-query gate with the qualifications in Codex Round 2; self-host only if it fails or off-box query text is unacceptable. Keep pg_textsearch; native full-text search is a fallback for a concrete extension blocker only (A-F2, A-J2).
5. Null-uid provisioning rows expire locally under the conditional-persist guard; no provider correlation lookup (A-J4).
6. One sentence stating that a failed migration leaves the site down until fixed forward.

Source designs unchanged. Phase 2 begins in `idioms-v2-backend-review.md` under the signed-playback branch.

### Codex — closure confirmation

Consensus at two paired rounds. I accept click-time authorization and redirect as the smallest way to keep app links stable and avoid LiveView renewal timers; the backend phase will specify the route and verify provider destination support. Correction to Fable's data-boundary wording: eligible public document text also newly leaves the box under hosted inference, not only queries. A worker can read text just before a concurrent hide, so “never” is too strong: eligibility is checked at admission, not retroactive revocation of an already sent request. These qualifications do not alter the conditional evaluation recommendation.

## Fable — document application verification and signoff

Read-only check of the four revised design documents after consensus (two rounds per phase). Hashes at signoff: architecture `c8463d2c`, backend `70f06202`, frontend `45cdd30d`, data-model `8f33e516`.

Verified:
- No normative activation, snooze, attempt-budget, `activated_at`, `activation_job_id`, webhook/callback writer, provider-correlation lookup, version rebind, PostgreSQL domain, amendment layer, or "three containers" wording remains in any document outside the data model's labelled historical section. Remaining matches are explicit negations.
- Every cross-document anchor resolves (`data-model.md#tables`, `#edit`, `#publish-retries`; backend admission, durable work, managed video, voting, signup, email change, main feed; frontend saving and recovery).
- The two cross-document findings from the data-model pass are resolved: backend :277 now retires and deletes NULL-uid rows locally with composer slot feedback that does not equate every missing id with expiry; frontend :279 now states that confirmed provider deletion ends serving before token expiry.
- Data model, backend and frontend agree on: always-private Stream assets with click-time signed watch/thumbnail routes, JOSE RS256 one-hour tokens, `private, no-store`; conditional uid-persist guard excluding failed, cleanup-marked and expired rows; worker-only status reconciliation with `checked_at` rotation and a second expiry branch covering every trusted-completed row at `completed_at + 48h`; per-operation lock sets with subject accounts before bulk discovery and no tip lock for non-liveness review edits or review votes; `optimistic_lock` for single-record edits with expected-version check before no-op; server-held session token row reference; hosted-first embedding candidate at the existing gate with per-side preparation and admission-time eligibility; inline registration reclaim, IndexedDB compare-and-set drafts, poster previews and synchronous image baseline preserved.

Findings: none. Consensus stands at two rounds per phase; the design documents now apply it. Implementation and integration verification remain outstanding per each document's acceptance list.

## Document reconciliation after all-phase consensus

The owner requested applying the agreed analysis after consensus across all three phases. Codex revised `software-architecture.md`, `backend-design.md` and `frontend-design.md`; Fable reconciled their canonical `data-model.md` dependency. This work followed, rather than substituted for, the two-round consensus in each phase.

Applied: always-private signed playback and poster redirects; no activation lifecycle; NULL-uid local retirement with guarded endpoint handoff; concrete session-reference admission; operation-specific trigger lock sets; conditional hosted-embedding evaluation at the existing gate; canonical schema without a manual amendment layer; page-owned uploads with a synchronous baseline. Preserved: private drafts, poster previews, native video, counter triggers, submission keys, separate revisions, IndexedDB conflict protection and inline registration reclaim. Unaccepted alternatives remain review history.

Codex cross-checked the revised data model and corrected downstream wording for completed-but-processing expiry, stale edit lock instructions, model-specific embedding preparation, admission-time eligibility, NULL-uid retirement feedback and provider deletion versus token expiry. Static document verification passed: 57 local links/anchors across four documents, balanced code fences, required schema items present, and obsolete activation columns/domains/versioned upload targets absent from the current schema. No application, browser, provider or database integration tests were run; the repository remains design-only and the acceptance sections name the required implementation checks.

Reconciled source hashes:
- `software-architecture.md`: `c8463d2ce940b646f408fbbd2f2eb990600cc92b7e163ca87674010421f3d463`
- `backend-design.md`: `70f06202154219de2704275388099d5a93e00c87aa95dc14144e3407f0255240`
- `frontend-design.md`: `45cdd30d19b07a1db8798d8586ea26846507e1c4795779aa70cd8852c22a2be5`
- `data-model.md`: `8f33e51635554b97ec92ae8cfa80bf41e2dbe7d22efbf24765d8bfec29f4aad8`
