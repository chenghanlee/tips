# Chavruta: features for an AI-tips website

Date: 2026-09-18
Participants: Claude (Fable 5.1, Herdr pane wJ:p1) and Codex (gpt-6-astra, Herdr pane wJ:p2)
Premise from the user: "Urban Dictionary, but people submit tips for getting better output from Claude, ChatGPT, and other LLMs." Example tip: saying "I have ADHD" makes Opus more direct and less mannered.

Format: each partner states a position, the other challenges it, both refine. The goal is a feature list with reasons, plus a record of where we still disagree.

---

## Round 0: opening positions (independently written before the dialogue)

### Claude's opening

Key claim: slang definitions don't expire, LLM tips do. That one fact shapes most of the design.

- Core loop: short tip (title, exact phrase, effect), copy button, votes split into "works" vs "didn't work" rather than vibe votes, comments as variants clustered under a canonical tip.
- Freshness: model and version tags, dated "still works?" check-ins, stale badge after ~60 days without confirmation, retired tips kept as a graveyard.
- Evidence: before/after prompt-and-output pairs; ambitious version is scheduled automated verification with an LLM judge.
- Discovery: browse by task (writing, coding, summarizing), trending/new/top, tip of the day.
- Distribution: browser extension inside the ChatGPT/Claude compose box; an MCP server or Claude Code skill so an agent can look up tips about itself.
- Policy: where is the line between tip and jailbreak; whether to tag "persona claims" like "I have ADHD"; whether vendor employees get a special role.
- Open question: power users vs newcomers; irreverent vs authoritative.

### Codex's opening

Frames the unit as "a small reusable discovery: when the model does this annoying thing, try that."

1. Tips organized around frustrations ("Claude is too wordy", "ChatGPT keeps agreeing with me") as browsable problem pages collecting competing remedies.
2. A simple tip format: title, phrase/technique, intended effect, model used; optional before/after. Techniques beyond phrases too (examples, context structure, task splitting).
3. Multiple ranked answers per problem, so the community can learn whether the useful ingredient is the phrase or the behavior it implies.
4. "Worked for me" feedback separate from upvotes: worked / partly / didn't, with model version.
5. Model and version awareness: provider, model, date tested, surface (chat app, coding agent, API); "last confirmed working" date.
6. Discovery by outcome and by activity; natural-language search ("how do I stop it sounding like LinkedIn?"); delightful browsing (weird, simple, underrated).
7. Examples as first-class content; eventually a comparison view of several tips on the same task.
8. Remixes and counterexamples with lineage links.
9. Personal collections and reusable bundles that compile into an instruction block.
10. Culture with room for play and rigor: "interesting hypothesis" vs "repeatedly confirmed".
11. Community experiments: weekly challenge with blind voting on outputs.
12. Contributor recognition for verifying and improving, not just inventing.

Named tensions: folklore vs dependable advice; individual tips vs problem pages as the center. Codex's instinct: problem pages for lasting value, individual tips for personality.

---
## Protocol from round 1 onward

Both partners read this file and append to it directly. Each round has a `### Claude` section and a `### Codex` section. Append only, never rewrite the other partner's text. End each turn with one direct challenge or question for the other partner. Keep turns under about 450 words.

**Constraint from the user (2026-09-18):** the site's primary goal is to be useful. Gamification (reputation, badges, leaderboards, weekly challenges, contributor recognition) is out of scope. Judge every feature by whether it helps a reader get better output from a model today.

## Round 1

### Claude

Three challenges to Codex's opening:

1. Problem pages as the organizing unit is an editorial structure that costs curation. Urban Dictionary won because submission was frictionless and structure was emergent. Position: the tip is the atom; problem pages are tags that get promoted to pages once enough tips share them.
2. The moat is not community but freshness: the site re-tests tips against current models on a schedule with an LLM judge and shows "last verified 2026-09-12 on Opus 5" as a machine-produced fact. Codex listed model awareness only as human-reported. Is machine verification worth its cost, and what goes wrong?
3. Collections, bundles, and weekly experiments look like feature creep for version one. Which of the twelve survive if only five can ship?

### Codex

I concede the tip should be the submission atom. I don't concede that emergent tags alone make good discovery. "Too verbose," "long answers," and "won't get to the point" fragment the same intent. Let people submit freely, then consolidate synonymous problems behind the scenes. Problem pages are a retrieval surface we can introduce when content warrants them; they needn't be an editorial prerequisite.

On freshness, you're conflating a defensible activity record with a defensible effectiveness claim. "Executed on this model on this date" is a machine-produced fact. "Verified to work" requires defining work.

Take the ADHD phrase. Are we measuring fewer words, clearer structure, preserved information, or a reader's preference? A judge could reward brevity while missing a crucial omission. A tip might improve one prompt and damage another. Testing through an API also leaves open whether the result transfers to the chat environment where someone discovered it.

My proposed standard: publish the test's scope alongside its result. "Preferred in 7 of 10 comparisons on these tasks" is inspectable. A green "verified" badge conceals the important qualifications.

I would also challenge your moat claim. Scheduled model calls are something competitors can reproduce. The potentially defensible asset is a growing corpus of realistic problems, comparison cases, and human assessments. Community could supply precisely what makes the testing valuable.

Is machine testing worth its cost? As a bounded experiment, yes. As the foundation of version one, I'm unconvinced. Start with a small set of popular tips with observable outcomes, comparing each against both an untreated baseline and a plain instruction requesting the same behavior. That second control matters: otherwise we might celebrate elaborate rituals that add nothing.

My five for version one:

1. Submit and view a tip: technique, intended outcome, optional example.
2. Applicability metadata: model, environment, date tried.
3. Search and discovery: text search, lightweight problem tags, model filters.
4. Outcome feedback: worked, partly worked, failed, with context when supplied.
5. Discussion: adaptations, counterexamples, and explanations.

I'd cut bundles, public collections, challenges, elaborate reputation, and automated verification badges. Testing can be a manual research exercise before becoming a product subsystem.

Challenge to Claude: What would your machine verifier need to observe before it could responsibly label the ADHD tip "works," and what result would make it label that same tip "fails"?

## Round 2

### Claude

First, the user's constraint: gamification is out. That removes Codex's items 11 and 12 and my "tip of the day" habit hook. Good. It also sharpens the question for every remaining feature: does it help a reader get a better answer from a model today?

Answering the challenge directly. The ADHD tip makes a claim about style, not content: more direct, fewer mannered phrases. So the verifier must judge on the claimed dimension only, and guard the rest.

- **Inputs**: a fixed panel of 10 to 20 diverse task prompts. Three arms per prompt: untreated baseline, the tip, and a plain-instruction control ("be direct, skip the hedging"). Same model, same settings, several samples each.
- **Judgment**: pairwise blind preference on the claimed dimension, with a rubric naming the mannerisms (hedging, throat-clearing, "great question", closing restatements). Separately, a content-coverage check so brevity that drops facts counts against the tip.
- **"Works"**: tip beats baseline on the claimed dimension in a clear majority of pairs, with no coverage loss.
- **"Fails"**: no difference from baseline, or coverage loss.
- **"Ritual"**: tip works but the plain-instruction control does as well or better. I concede this is the most useful result the site could publish. It separates folklore from mechanism, and it is the difference between a useful site and a superstition archive.

So I retract the green badge. Every machine result is a scoped sentence: "Preferred over baseline on directness in 14 of 20 tasks on Opus 5 via API, 2026-09-12. Plain instruction matched it." I also concede the moat point: the corpus of task prompts and human judgments is the asset; machine testing consumes it.

I keep one thing. A human "worked for me" vote without a date and model is noise. Date and model must be required on every vote, not optional context. That is cheap, and it seeds the corpus you want.

Two new fronts, both about usefulness.

**Policy.** The ADHD tip works by asserting something the user may not have. The site will fill with tips of this shape: fake credentials, fake deadlines, fake disabilities. My draft: allow persona claims, tag them so readers can filter them out, and disallow anything whose stated purpose is to defeat a refusal. Is a tag enough, or does the site need a stance?

**Data model.** Is a tip one object with many per-model reports, or is "ADHD on Opus 5" a different tip from "ADHD on GPT-5"? One object keeps the idea in one place but makes votes incomparable across models. Per-model objects fragment discussion. Pick one and defend it.

Challenge to Codex: give me the exact submission form, field by field, marking which fields are required. If it takes more than two minutes to fill in, you have lost the Urban Dictionary property you praised.

### Codex

Accepted: reputation, recognition, leaderboards, and weekly challenges are out of scope, not deferred roadmap items. Usefulness means a reader can find an applicable technique, understand it, try it, and assess the result. Copyable instructions and visible limitations deserve more attention than engagement features.

Your experiment is stronger now, but “fails” still conflates insufficient evidence with evidence of no benefit. Likewise, matching the plain instruction does not reveal mechanism. Report “no clear improvement detected” or “no added benefit over direct instruction in this test.” Keep the comparison available without making readers understand experimental design before trying a tip.

**One tip, many reports.** The technique is the shared object. Reports carry model, environment, date tried, and outcome. Discussion stays together; outcome summaries are filtered by setup and show their denominators. An unchanged technique tried on another model gets another report, not another tip. A materially different technique can be a linked alternative.

I reject mandatory exact model identification. Someone using automatic model selection can still describe a useful experience. Support “unknown / automatic,” and exclude those reports from named-model aggregates. Record submission time automatically, but distinguish it from when the person tried the technique. Never silently turn an old recollection into fresh evidence. A model and date alone also do not create a reproducible test case.

**Exact submission form:**

1. **Title / problem solved — required.** Example: “Get more direct answers.”
2. **What to try — required.** Copyable text or short steps, with any essential conditions included.
3. **Expected result — optional.** Extra detail beyond the title.
4. **App or tool — optional.** Such as a chat app, coding agent, or API.
5. **Model — optional.** Picker with “unknown / automatic.”
6. **When tried — optional.** Today, approximate date, or not tried yet.
7. **Example — optional.** Task and before/after outputs.

Only the first two fields are expanded initially; the rest sit under “Add context.” No required account setup or taxonomy assignment in the submission flow. Publication does not itself count as a success report.

**Policy:** allow benign persona framing, label it neutrally, and make direct alternatives easy to find. Prohibit tips facilitating harmful conduct; assess examples and context, not just the author's stated intent. A blanket ban on defeating refusals would also catch attempts to correct a mistaken refusal of a benign request. A persona tag describes the method; it cannot decide acceptability.

My challenge: what exact moderation rule permits correcting a mistaken refusal on a benign task while excluding harmful bypass advice?

## Round 3

### Claude

Conceded: one tip, many reports. Conceded: "unknown / automatic" model is allowed, excluded from named-model aggregates, with tried-date distinct from submitted-date. Conceded: "no clear improvement detected" and "no added benefit over direct instruction in this test" replace "fails" and "ritual." Your form is good. I would add one optional field, "plain-language equivalent," and I'll argue for it below.

**The moderation rule you asked for.** Judge the request, not the technique. A tip is allowed if the underlying request it helps with is one the model's provider would fulfill when asked plainly and honestly. Call it the honest-ask test.

- A tip for getting a benign request reconsidered after a mistaken refusal passes, because the plain honest ask is one the provider intends to answer. The tip is helping the model do its job.
- A tip whose example request would be refused when asked plainly fails, no matter how it is phrased or whether it mentions refusals at all.
- Operational consequence: every tip in the "refusals" area must include the example request it was used for. Moderators evaluate that request. A tip without an example in this area is held, not published.
- Persona claims ("I have ADHD," "I'm a doctor") pass the honest-ask test when the request is benign, and get a neutral "framing" label. The label's purpose is not judgment. It is so the tip page can show the plain-instruction alternative next to it.

**The plain-language alternative as a first-class field.** This is where your "no added benefit over direct instruction" result stops being a research note and becomes the most useful thing on the page. If a reader sees "I have ADHD" and, directly beneath it, "Plain version: 'Answer directly, no preamble, no hedging' has the same effect in reports so far," they can choose the honest phrasing. Submitters can fill it in; commenters can propose it; a test can confirm or deny it. It costs one optional field.

**Tip page anatomy, first screen.** Usefulness is decided here, not in the form.

1. Title and a copy box with the exact text. Copy is the primary action.
2. A small "works on" table: rows are model and surface, columns are reports (worked / partly / didn't) and last tried date. Empty rows are shown as "no reports" rather than hidden.
3. Plain-language alternative, if any.
4. Known limitations and counterexamples, pulled up from discussion by a "this is a limitation" flag on comments.
5. One before/after example, collapsed.
Discussion is below the fold.

**Staleness without a verifier.** The site keeps a model release calendar. When a new model version ships, every tip's "works on" row for that family shows "no reports since Opus 5.2 released." That is machine-produced, cheap, honest, and it tells readers exactly what to re-check. It also gives contributors a queue of useful work without any gamification.

**Search.** Readers arrive with a frustration, not a term. Search must handle "stop sounding like LinkedIn." Proposal: semantic search over titles, problem statements, and the "what to try" text; problem synonyms consolidated behind the scenes as you suggested in round 1. Model and surface filters are the only facets.

Challenge to Codex: draw the first screen of a tip page in your own order, and say which item of mine you would push below the fold and why. Then, in round 4, let us each write a final prioritized feature list so round 5 can reconcile them.


### Codex

Agreed on final feature lists in Round 4. Here is my first screen; the evidence below is an illustrative layout, not an actual result:

```text
Get more direct answers
For: Claude chat · Model: [choose / unknown]

TRY THIS
“[Exact submitted instruction]”             [Copy]
Where to put it: start of your message

Reported effect: shorter, more direct answers.
Watch for: important qualifications being omitted.

For your setup: no reports yet.
[See reports for other setups]

DIRECT ALTERNATIVE                         [Copy]
“Be concise. Skip introductory filler.
Keep necessary qualifications.”
Suggested alternative · not compared yet

[See before / after]       [Report your result]
```

**Move the full model table below the fold.** Most readers need their setup first. A matrix of every model and surface spends their attention on irrelevant combinations. Keep a compact evidence summary above the fold, including outcome counts when available. Call the section “Experience reports,” not “works on”: the latter implies compatibility has been established. Display the technique's essential applicability conditions even before a setup is selected.

I would also include “where to put it” in the instructions. A copy button alone leaves readers guessing whether this belongs in a message, persistent instructions, or a fresh conversation. That missing step can make an otherwise useful tip unusable.

The alternative earns its space, but **“equivalent” is a finding, not a field name**. Start with “suggested direct alternative.” Only attach comparison claims to actual evidence. “No hedging” also risks conflating unnecessary verbal cushioning with warranted uncertainty; our suggested alternative should preserve the latter. One optional text field is cheap; maintaining authoritative equivalence claims is not.

Your release calendar adds maintenance without establishing obsolescence. A new model does not invalidate reports about an older model that remains selectable. Show evidence for the selected version and “no reports for this version” where appropriate. Postpone the calendar. Likewise, the latest failure report must not make a tip look freshly confirmed: distinguish “last tried” from “last reported helpful.”

The honest-ask test delegates our policy to providers whose decisions may differ, and using an actual refusal as the test recreates the mistaken-refusal problem. Requiring a concrete example is useful. The site still needs its own short, published rules for harmful assistance; provider intent cannot substitute for them.

Semantic search is a candidate implementation. The product requirement is finding relevant tips from natural descriptions; test that on representative queries before selecting the machinery.

My challenge: when reports are sparse or conflict, what should determine which tip a reader sees first, without treating popularity as proof of usefulness?

## Round 4: subtraction

**Guiding principle from the user (2026-09-18):** "Perfection is achieved, not when there is nothing more to add, but when there is nothing left to take away." Think from first principles, apply Occam's razor, and apply Pareto: find the few features that carry most of the usefulness.

### Claude

Rounds 1 to 3 were addition. This round is subtraction.

**First principles.** A reader has a frustration with a model. The irreducible job is: find a phrase, paste it, and know whether it worked for other people on the same model. Three verbs: find, copy, trust. Anything that does not serve one of those three is a candidate for removal.

**Concessions from round 3 that survive the razor.** "Where to put it" is part of copy, so it stays. "Last tried" vs "last helpful" is part of trust, so it stays, but as two dates, not a system. The release calendar, the remembered setup selector, comment flags, the five-key ranking: all cut. They were answers to problems we don't yet have.

**The whole site, version one.**

1. **A tip** is four fields. Title. The exact text to paste. Where to paste it (message, system prompt, or new conversation). Model it was tried on, with "unknown" allowed. Nothing else is required and nothing else is offered on the form. Before/after examples, direct alternatives, and limitations go in comments until demand proves they need a field.
2. **A report** is one click: worked or didn't, plus the model. Date is automatic. No "partly." If the reader wants to say more, that is a comment.
3. **Search** is full text over title and tip text, with one filter: model. No taxonomy, no problem pages, no synonym consolidation until search logs show people failing to find things.
4. **Comments**, plain. Variants, counterexamples, and "the plain version works too" all live here as prose. The best comment rises by simple votes.
5. **Ranking** on a tip list: within the chosen model filter, worked minus didn't, ties broken by most recent helpful report. With no filter, the same over all reports. Show the counts, not a score.
6. **One rule**, published in one paragraph: no tips for getting a model to help with something harmful. Moderated by hand. Persona tips like "I have ADHD" are allowed with no label; a commenter saying "just ask it to be direct" does the label's job better.

That is the eighty percent. Six things, and a person can build it in a weekend.

**What I cut and why.**

- Direct alternative as a field: it is a comment until it is not.
- Machine comparison: a research activity someone runs and posts as a comment, not a subsystem.
- Problem pages: tags are search terms; pages are what you build when search fails.
- Remembered setup, staleness flags, limitation flags, comment kinds: each one is a UI for a problem we have not observed.
- MCP server, extension, API: distribution comes after there is something worth distributing.

**What I would not cut.** The model field on the report. Without it, "worked" means nothing, and trust collapses. That is the one piece of structure that is load-bearing.

Challenge to Codex: apply the same razor to your own list. Then name one thing I cut that you believe is load-bearing for find, copy, or trust, and one thing I kept that you would remove.


### Codex

I accept the subtraction. My earlier list turned useful distinctions into dedicated features too readily. Remove structured alternatives, examples, limitation flags, remembered preferences, advanced ranking, and automated testing. Plain comments can carry the nuance initially.

One first-principles correction: the job is to find and apply an actionable technique. “Find a phrase” unnecessarily excludes useful steps such as providing an example or splitting a task. Keep one instruction box that accepts either text to copy or short directions.

**My reduced site:**

1. **Submit and read tips.** Title, instructions including where to apply them, and where they were tried. A copy button for the instruction text. No separate fields for alternatives, examples, or limitations.
2. **Find tips.** Full-text search ordered by relevance, with a model filter. Browse recent submissions when there is no query. Show report counts beside results.
3. **Report and discuss.** Worked / didn't, with model and environment; plain comments for qualifications, examples, and corrections. These are readers' experiences, not a verified effectiveness score.
4. **Basic moderation.** A short harmful-assistance rule, manual review, and a way to flag a submission. No reputation or rewards.

**One thing you cut that is load-bearing: environment.** “Same model” is insufficient context when one person changes an API system prompt and another pastes text into a consumer chat. Restore one short “Where used?” value on tips and reports: chat app, API, coding tool, or unknown, with the tool named when known. This is applicability information, not another preference system.

**One thing you kept that I would remove: worked-minus-didn't ranking.** It reintroduces popularity through arithmetic. A tip with 100 worked and 90 didn't would outrank one with 9 worked and none against. Neither count pattern alone tells us which fits the reader's problem. Use relevance for search, recency for browsing, and visible counts for judgment. We do not yet need to declare a winner.

One correction costs no feature: automatic timestamps mean “reported on,” not “tried on.” Label them accurately and drop claims about last tried unless we actually collect that date. Convenience should not manufacture freshness.

My challenge: will you keep environment as essential context and remove effectiveness ranking until we have evidence that it improves the reader's choice?

## Round 5: reconciliation

### Claude

Both of Codex's moves survive the razor, so I take them.

- **Environment stays.** Chat app, API, coding tool, or unknown, on both the tip and the report. It is part of trust: "worked on Opus 5" without saying whether that was claude.ai or a system prompt over the API is a half-fact. One enum, no free text beyond an optional tool name.
- **Effectiveness ranking goes.** Search sorts by relevance, browse sorts by recency, and the counts sit beside every result for the reader to judge. A winner is declared only when evidence shows readers need one.
- **"Instructions," not "phrase."** The box accepts pasteable text or short directions. Copy button either way.
- **"Reported on," not "tried on."** We label what we actually collect.

### Reconciled feature list, version one

The irreducible job: a reader with a frustration finds an actionable technique, applies it, and knows whether it worked for others on the same model and environment.

1. **Tip.** Title. Instructions, with where to apply them (message, system prompt, new conversation) stated inside. Model, "unknown" allowed. Environment: chat app, API, coding tool, or unknown, tool name optional. Copy button on the instructions. No other fields.
2. **Report.** Worked or didn't. Model and environment. Timestamp shown as "reported on." One click plus two selectors.
3. **Find.** Full-text search over title and instructions, sorted by relevance. One filter: model. Optional second filter: environment. Browse recent when there is no query. Report counts beside every result, never a score.
4. **Discuss.** Plain comments with simple votes. Examples, direct alternatives, limitations, variants, and any hand-run comparisons live here as prose until demand proves a field is needed.
5. **Moderate.** One published paragraph: no tips for getting a model to help with something harmful. A flag link on every tip. Manual review. Persona tips are allowed without labels.

Five things. Everything else in rounds 0 through 3 is recorded above as the deferred list, with the condition that would justify each addition.

### Deferred, with the trigger that would justify it

| Feature | Build it when |
|---|---|
| Problem pages and synonym consolidation | Search logs show readers failing to find tips that exist |
| Direct-alternative field | Comments saying "the plain version works too" are common enough to be worth structuring |
| Before/after example field | Submitters keep pasting transcripts into comments |
| Effectiveness ranking | Readers demonstrably pick worse tips from unranked lists |
| Machine comparison (baseline, tip, direct alternative, scoped sentences) | A handful of tips have enough traffic that the cost is justified and a human has run the comparison by hand first |
| Staleness signal per model version | A model release causes a visible wave of "didn't work" reports on old tips |
| Read API and MCP server | Someone outside the site asks for it |

### Recorded disagreements

None that block version one. Open questions we did not resolve and are leaving to evidence: whether "partly worked" is needed as a third report value, and whether the honest-ask test is a good rule for the mistaken-refusal category or whether the single harmful-assistance paragraph covers it.

Codex, please sign off below, or record any dissent in one paragraph.


### Codex

Signed off on the five-part version one. It preserves the useful loop without requiring the evidence and discovery systems we initially imagined. One implementation clarification: label report counts by model and environment, and scope them to the selected setup when applicable. An unlabeled total must not imply that reports from other setups establish usefulness for this reader. Unknown reports remain visible without entering named-setup counts.

Corrections to the deferred table:

- “Everything else” is too broad: gamification, reputation, recognition, leaderboards, and weekly challenges are explicitly out of scope, not deferred.
- Machine comparison needs an agreed outcome and a credible evaluation method as well as traffic and a prior manual trial; popularity alone cannot make a comparison informative.
- A staleness signal should require evidence about the affected model and environment. A successor's release does not invalidate reports for an older version that remains available.

No blocking dissent. The deferred table records hypotheses to revisit, not a commitment to build them.

## Closing summary (both partners agreed)

**Version one is five things:** tip, report, find, discuss, moderate. Details in Round 5. Two amendments from Codex's sign-off are accepted:

- Report counts are always labeled by model and environment and scoped to the selected setup. An unlabeled total is never shown. Unknown-setup reports are visible but never enter named-setup counts.
- Deferred-table corrections: machine comparison also requires an agreed outcome measure and a credible evaluation method; a staleness signal requires evidence about the affected model and environment, since a successor's release does not invalidate reports on a version that is still available.

**Out of scope, not deferred:** gamification, reputation, recognition, leaderboards, weekly challenges, bundles, public collections.

**What the dialogue changed.** We began with twelve and eight features respectively, including machine verification badges, problem pages, collections, and a five-key ranking. Subtraction under the user's principle removed everything that answered a problem not yet observed. The two things that turned out to be load-bearing and nearly got cut were the environment field (chat, API, coding tool) and honest labeling of dates ("reported on," not "tried on").

## Round 6: examples, by analogy to photos on Google Maps reviews

**Prompt from the user (2026-09-18):** Google Maps lets reviewers attach photos. That works because a picture is worth a thousand words, and because phones make taking and attaching a photo nearly free. What is our equivalent of "attaching a picture" to a tip, and what mechanism lets users upload examples with little or no friction?

### Claude

**Map the analogy exactly.** Restaurant is the tip. Review is the report. Photo is the example. So examples attach to reports, not to tips. That single decision does most of the work: the person who just tried the tip is the one holding the evidence, at the moment they are most willing to share it.

**What is our photo?** The model's actual output with the tip visible in it. Not a description of the output, the output. It does three jobs a photo does on Maps: shows what you get, proves the reviewer was there, and lets readers judge for themselves without trusting the reviewer's adjectives.

**What is our camera roll?** People already have the photo. Two forms exist today with zero new tooling:

1. **Share links.** ChatGPT and Claude both produce a public share URL for a conversation. The user pastes the link. The site fetches the conversation, snapshots it, and renders it with the tip's phrase highlighted. This is the geotagged photo: it comes from the vendor's domain, it shows the whole context, and it often names the model. The site can prefill model and environment from the URL, which removes two selectors from the report form.
2. **Screenshots.** People already screenshot model outputs to post on social media. Paste or drop an image into the report. This is the ordinary photo: easy, ubiquitous, unverifiable.

**The mobile mechanism.** The exact analog of "take a photo, attach it" is the share sheet. In the ChatGPT or Claude app, tap share, choose our site. A Web Share Target lets a progressive web app receive a URL or image from the OS share sheet. No extension, no store listing. The user never types anything: the tip is chosen from a short "which tip were you trying?" list, one tap for worked or didn't, done.

**Before and after.** Maps photos don't need a "before." Ours mostly don't either: a transcript with "I have ADHD" in the prompt and a direct answer beneath it is self-evident. Demanding a baseline doubles friction. Make "before" optional and rare.

**Display.** A strip of examples on the tip page, like the photo strip on a Maps listing, filtered by the reader's model. Open one and see the full transcript with the tip highlighted.

**Failure modes I see.** Share links rot when the user deletes the conversation, so snapshot at submission. Share links leak personal context, so show a preview and ask "is this fine to publish?" before saving. Vendors may block fetching, so screenshots are the fallback, not the primary. Fakes are possible with screenshots; the share-link origin is the trust signal and should be shown as such.

**The razor.** Version one is: report form gets one optional slot that accepts a URL or an image. Fetch-and-render for known share domains, plain image display otherwise. The share target is version 1.1, since it needs a PWA.

Challenge to Codex: is the share link really the primary, or is the screenshot? And what have I missed about coding-agent environments, where there is no share button?


### Codex

**Screenshot first; share link as an optional source.** Our equivalent of a photo is a small, inspectable example of using the technique: the relevant instruction and resulting output. Attach it to the experience report, as you propose. Let the original submitter add a report too, so new tips need not wait for another reader to supply an example.

I would ship one optional **“Add an example”** area:

- Paste or drop a screenshot; on mobile, choose an existing image.
- Or paste the relevant exchange as text, preserving line breaks.
- Preview it inside the report before publishing; remove or replace it there.

The report already belongs to a tip and carries its setup. That avoids another “which tip?” step. Encourage including the instruction and result, but require neither a paired baseline nor a fresh experiment. The invitation is “Show what happened,” not “prove your claim.”

**Coding agents make plain text essential.** Their useful evidence may be a terminal exchange, a small diff, or test output. Let users paste that excerpt into the same area. No repository integration, transcript exporter, special diff uploader, or full-session import. A screenshot of terminal output also works. This supports the artifact people already have rather than requiring a vendor share feature.

Your link importer hides substantial work inside “fetch and render”: provider-specific extraction, selection of relevant turns, snapshot storage, and publication scope. Cut it initially. Accept a share URL as a link in the existing comment text. Don't promise that it contains complete context: Claude's documentation explicitly says raw MCP tool data is hidden from shared snapshots. [Claude sharing documentation](https://support.claude.com/en/articles/10593882-share-and-unshare-chats).

The share-sheet proposal also has onboarding friction: a web share target requires an installed PWA and has limited browser availability. Treat it as an experiment after observing how contributors attach examples. [MDN share_target](https://developer.mozilla.org/en-US/docs/Web/Progressive_web_apps/Manifest/Reference/share_target).

Two claims need trimming. A screenshot does not prove the reviewer ran the exchange; a vendor-hosted transcript does not establish causation. A direct answer following “I have ADHD” demonstrates an outcome, not improvement over the ordinary prompt. Label these “Examples,” with their associated worked/didn't report. Optional comparisons can remain comments.

Show compact attachments with their reports first; a separate gallery can wait. Remind contributors in the preview to share only the relevant excerpt and omit private information, without building a redaction editor.

My challenge: will you cut automatic transcript importing and snapshotting from version one, and test screenshot/text attachment before investing in a share-sheet workflow?

## Round 7: reconciliation on examples

**Added by the user (2026-09-18):** users work with models on the web, in mobile apps, on the command line, and through APIs. A share link exists for the web and mobile apps only. Any example mechanism must work across all four mediums.

### Claude

The user's point settles the primary. A mechanism that covers one medium out of four cannot be the primary, however elegant. What is common to all four? Text and screenshots. Every medium produces text that can be copied, and every screen can be captured. So Codex is right: screenshot or pasted text is the photo, and the share link is a link in a comment.

**Yes to both of Codex's challenges.** The transcript importer and snapshotting are cut from version one. The share-sheet workflow waits until we have seen how people actually attach examples.

**Medium by medium, what the photo is:**

| Medium | The artifact people already have | How it gets in |
|---|---|---|
| Web chat | Screenshot, or copied text of the exchange | Paste or drop |
| Mobile app | Screenshot from the camera roll | Choose image |
| Command line and coding agents | Terminal excerpt, small diff, test output | Paste as text, line breaks preserved; or a terminal screenshot |
| API | Request and response JSON or a log excerpt | Paste as text |

One input area handles all four: it accepts an image or text. Nothing medium-specific is built.

**Reconciled addition to version one.** The report gets one optional area, "Show what happened." It accepts a dropped or pasted image, or pasted text with line breaks preserved. A preview appears before publishing, with a one-line reminder to include only the relevant excerpt and no private information. The tip's original submitter can file a report too, so a new tip can carry an example from day one. On the tip page, examples display compactly beside their reports, filtered with the reader's model and environment. The section is labeled "Examples," never "proof." That is the whole feature.

**Deferred, with triggers:**

| Feature | Build it when |
|---|---|
| Share-link fetch and snapshot | Many examples are bare share links in comments and readers complain about link rot or clicking out |
| OS share sheet via PWA share target | Mobile reports are common and mostly lack examples |
| Example gallery on the tip page | A tip has more examples than fit beside its reports |
| Before/after pairing | Contributors keep posting baselines in comments unprompted |

**One correction to my own round 6.** I called the share link a trust signal. Codex's point stands: a vendor-hosted transcript shows an outcome, not an improvement over the plain prompt. Neither form of example proves the tip works. Both show what happened, which is what a photo does.

Codex, sign off or dissent in one paragraph.


### Codex

Signed off. “Show what happened” supplies a useful example across web, mobile, command line, and API without requiring provider integrations. Keep the explicit image chooser from the mobile row in the implementation; paste and drop alone do not cover that path. Pasted text should remain readable as an excerpt, and the preview should allow removing or replacing the attachment before publication. One qualification to the deferred table: frequent mobile reports without examples justify investigating the friction, not automatically building a PWA share target. Likewise, numerous share links justify investigating import, not assuming snapshotting is necessary. These are signals to test a proposed improvement. No blocking dissent; the reconciled feature preserves the subtraction principle.

## Round 8: the razor, again

**Restated by the user (2026-09-18):** perfection is achieved not when there is nothing to add but when there is nothing to review. First principles, Occam's razor, Pareto.

### Claude

Round 7 added a feature. The principle says look at it again and take away.

**What Google Maps actually has.** A review is a rating, optional text, optional photos. There is no separate comment system. The user's own analogy contains the cut.

**We have three objects doing one job.** A report is a verdict plus setup. A comment is text. An example is text or an image. Each one exists because we invented it in a different round. From first principles, a person who tried a tip wants to say three things at once: whether it worked, on what, and here is what happened. That is one object.

**Merge them.** A **review** is: worked or didn't, model, environment, optional text, optional image. Nothing else. A "comment" is a review with text and no verdict. An "example" is a review with an image or a pasted excerpt. Displayed as a flat list under the tip, newest first, filtered by the reader's setup, counts of worked and didn't at the top.

**What that removes from round 7.**

- "Show what happened" as a named area with its own preview, remove, and replace controls. A native file input and a text box do this. The browser already lets you re-pick a file.
- A separate "Examples" section and any filtering of examples apart from reviews. Filtering reviews filters examples.
- The rule that the original submitter can file a report. Everyone files reviews; there is no special case.
- Comment votes. In a flat list sorted by recency with setup filters, there is nothing for a vote to reorder yet. Threaded replies and votes return when reviews start quoting each other, which is the signal that discussion needs structure.

**Version one, restated.** Four things.

1. **Tip.** Title, instructions with placement, model, environment. Copy button.
2. **Review.** Worked or didn't, model, environment, optional text, optional image. Line breaks preserved. One line of privacy guidance beside the input.
3. **Find.** Full-text search by relevance, browse by recency, model filter, counts beside results.
4. **Moderate.** One paragraph of rules, a flag link, manual review.

**Pareto check.** Tip and review carry almost all the value. Find is how you reach them. Moderate is the cost of being public. There is nothing left whose removal would not break find, copy, or trust.

**What I am unsure of.** Whether a review with no verdict should be allowed at all, or whether every review must say worked or didn't. Forcing the verdict keeps counts honest; allowing no verdict lets a question or a correction in. My lean is to allow "no verdict" as a third radio button, since the alternative is people picking a verdict they don't mean.

Codex: accept the merge or show what it breaks. And decide the no-verdict question.


### Codex

**Accept the merge. Allow no verdict, and make it the default.** One review can hold an experience, a correction, a question, or an example. Requiring worked/didn't would manufacture evidence from people who only wanted to clarify an instruction.

Use “No verdict / Worked / Didn't work.” No-verdict reviews contribute to neither outcome count. Require at least a verdict, text, or an image so empty submissions cannot publish. Model and environment may be unknown; someone asking a general question need not invent a setup. Count outcome reports only within their stated setup, and keep general corrections accessible when readers filter experiences.

The merge removes separate objects and displays. It does **not** justify removing the useful behavior of the image input. A filename is insufficient for checking whether someone selected the right screenshot or exposed private context. Keep a small thumbnail and an explicit remove action before publishing. This is part of attaching an image, not a separate preview workflow. Replacing a file also does not satisfy “I changed my mind; publish without an image.”

Likewise, keep clipboard image paste alongside the file chooser. Our original requirement was near-zero friction across mediums; making desktop users save a clipboard screenshot to disk before attaching it would trade contributor effort for implementation brevity. Drag-and-drop can wait if it adds work without serving observed usage.

I endorse the four-part site, with these attachment behaviors inside Review. Remove comment votes and the separate Examples section. Threading remains a hypothesis, not an automatic response to someone quoting another review.

My challenge: will you preserve image paste, a thumbnail, and removal as the minimum attachment interaction while accepting no-verdict reviews as ordinary contributions excluded from effectiveness counts?

### Claude (closing round 8)

Accepted in full. Image paste, a thumbnail, and a remove action are the floor of "attach an image," not additions to it; the test is that removing any one of them forces a contributor to do extra work. No-verdict is the default radio button, excluded from counts, and a review must carry at least a verdict, text, or an image.

**Version one, final.**

1. **Tip.** Title, instructions with placement, model, environment. Copy button.
2. **Review.** No verdict / worked / didn't (no verdict default). Model and environment, unknown allowed. Optional text, line breaks preserved. Optional image by paste or file chooser, shown as a thumbnail with a remove action. One line of privacy guidance. Must contain at least one of verdict, text, or image. Flat list under the tip, newest first, filtered by setup, with worked and didn't counts per stated setup.
3. **Find.** Full-text search by relevance, browse by recency, model filter, counts beside results.
4. **Moderate.** One paragraph of rules, a flag link, manual review.

Everything else in this file is a hypothesis with a trigger. Threading, votes, share-link import, share sheet, galleries, before/after pairs, problem pages, ranking, machine comparison: each waits for its signal, and the signal justifies investigating, not building.

## Round 9: how the world shows "here is what this does"

**Prompt from the user (2026-09-18):** how do GitHub READMEs show a preview of how a tool works? What other real-world references or industry standards exist for previewing a tool, library, or piece of software, and which can we adapt? First principles, Occam, Pareto.

### Claude

**The references, and what each one actually is.**

| Reference | The convention | What it reduces to |
|---|---|---|
| GitHub README "Usage" | A code block: the command, then its output | Input/output pair, as text |
| Python doctest | `>>> f(2)` then `4`. The example is also the test | Input/output pair, verifiable |
| Unix man page EXAMPLES | Command, one-line description of what it does | Input plus intended effect |
| Stripe and other API docs | Request on the left, response on the right | Input/output pair, side by side |
| Jupyter notebooks and cookbooks | Cell in, cell out, alternating | Input/output pairs, sequential |
| Compiler Explorer, CodePen, regex101 | Source on the left, live result on the right, shareable link | Input/output pair, re-runnable by the reader |
| Hugging Face model cards | Example inputs and outputs, plus a widget that runs the model in-page | Input/output pair, plus "try it yourself" |
| Google Fonts | Type your own text to preview the font | Reader supplies the input, sees the output |
| asciinema and VHS | Terminal session recorded as text, replayed as a GIF | Input/output pairs, animated, from a plain-text source |
| README GIFs and App Store screenshots | Pictures of the thing running | Input/output pair, lossy, unverifiable, effortless |
| Stack Overflow's minimal reproducible example | The smallest input that shows the behavior | Input/output pair, trimmed |
| git diff | Before and after as one unified view | Change, not output |

**First principles.** Every one of these is the same object: an input and the output it produced, kept small. The successful conventions differ only in whether the reader can re-run the input. Screenshots and GIFs are the lossy form. Doctests, Compiler Explorer, and the Hugging Face widget are the verifiable form.

**Pareto.** A GitHub README gets most of its persuasive value from one Usage block. Not the GIF, not the badges. Readers want to see the exact input and the exact output, once. So the eighty percent for us is one input/output pair per review: the message that contained the tip, then the model's reply.

**Occam.** We do not need a field or a format. Markdown already has the notation. A blockquote is the user's turn; plain text below it is the model's turn. That is what people already do when they quote a message and reply. So the review text box gets a placeholder that shows the convention:

```
> paste the message you sent, including the tip
paste what the model replied
```

Render blockquotes in a "you said" style and the rest in a "model said" style. Zero new syntax, zero new fields, and it works for chat, mobile, CLI, and API, because all four produce text. A screenshot remains the lossy fallback for people who won't paste.

**What I would steal from the strongest reference, and defer.** The Hugging Face widget and Google Fonts share the most powerful idea: the reader supplies their own input and sees the output live. For us that is a "try this tip" button that runs the reader's own message with and without the tip on the chosen model. It turns evidence into experience and removes the need to trust anyone's example. It costs money per click, so it waits for the signal that readers are re-typing tips into their own chats to check them, which is what they will do anyway.

**The doctest idea, deferred too.** A review's input/output pair is a test case. When machine comparison is ever justified, the corpus already exists in the reviews, in a parseable convention. That is why the blockquote convention matters more than it looks.

Challenge to Codex: is there a reference I missed that changes the answer? And is the blockquote convention honest enough, given that a pasted pair is just as unverifiable as a screenshot?


### Codex

**Sign off on encouraging small examples; dissent on assigning speakers from Markdown.** We just merged questions, corrections, and examples into one review text box. Treating every unquoted paragraph as “model said” breaks that decision. A reviewer writing “This omitted an important caveat” would have their own criticism attributed to the model. A model response containing a blockquote creates the inverse error. GitHub documents blockquotes as quoted text, without assigning a speaker. [GitHub formatting documentation](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-syntax/basic-writing-and-formatting-syntax).

**One missing reference: Storybook.** Its arguments configure the component being demonstrated, and changing them changes the rendered result. The lesson I take is that a preview shows behavior under particular conditions; a visible input alone does not capture every relevant condition. For our site, retain model/environment context and let reviewers mention crucial prior instructions. We need no additional fields. [Storybook Args](https://storybook.js.org/docs/writing-stories/args).

The minimum convention is an optional example in ordinary text:

```text
What I sent:
[prompt or relevant instruction]

What I got:
[response excerpt]

My note:
[optional explanation]
```

Use this as helper text or a sample, not required syntax and not a parser contract. Render reviews as user-authored content. Screenshots remain equally valid examples, particularly when layout or interaction is the result being demonstrated.

An input/output pair can illustrate behavior, but it is not automatically a runnable test. It may omit conversation history, tool state, or evaluation criteria. Preserve useful examples now; decide what constitutes a test case if we later build comparisons.

Also, readers retyping tips is our intended success path, so it cannot alone justify an in-site runner. We would need evidence that switching tools prevents useful trials and that our runner represents their actual setup.

My challenge: will you keep the input/output suggestion while dropping automatic speaker attribution and the promise of a parseable test corpus?

### Claude (closing round 9)

Accepted. Automatic speaker attribution from markdown is dropped: a reviewer writing "this omitted a caveat" would be rendered as the model's words, and that is a correctness bug, not a style choice. The parseable-corpus promise is dropped with it. A pasted pair may omit history, tool state, and prior instructions, so it illustrates behavior and is not a test case until someone decides what a test case is.

**What survives, and it is smaller than what I proposed.** The review text box carries a placeholder, not a syntax:

```
What I sent: (the message or instruction, including the tip)
What I got: (the reply, or the relevant excerpt)
My note: (optional)
```

Rendered as ordinary user-authored text. Screenshots are equally valid, and preferred when layout or interaction is the point.

**What the reference survey settled.** Every convention that works, from README Usage blocks to doctests to API docs, is an input/output pair kept small. The eighty percent is one such pair per review, in text. The part that costs nothing is the convention. Everything past that, from speaker styling to live "try it" runners to runnable test corpora, is deferred to a signal, and the Storybook lesson applies to all of them: a preview shows behavior under particular conditions, so model and environment stay attached to every review and nothing else is added.

## Round 10: two criteria

**From the user (2026-09-18):** choose options that (1) minimize the friction of producing the example and (2) maximize how faithfully the example represents how the tool works.

### Claude

**First principle behind criterion 1.** Friction is lowest when the example is a byproduct of using the tool, something the user already has, not something they compose for us. **Behind criterion 2.** Fidelity is highest when the artifact carries its own context: the whole exchange, the model, the surface, the prior turns. A cropped or transcribed artifact loses some of that.

**Scoring the options on both axes.**

| Option | Friction to produce | Fidelity | Mediums |
|---|---|---|---|
| Share link | One tap, already exists | Highest: whole conversation, model named, vendor-hosted | Web chat, mobile app |
| Screenshot | One keystroke or camera roll | Medium: real pixels, but cropped, not copyable, context partial | All four |
| Pasted text pair | Select, copy, paste, label, twice | High for content, low for context; composed, not captured | All four |
| Recording or GIF | High | High for interaction, wasted on text | Web, CLI |
| Written description | Lowest | Lowest | All four |

**The frontier has two points.** Share link wins both criteria outright where it exists. Screenshot is the best all-medium option: lowest friction with acceptable fidelity. Pasted text sits behind both on at least one axis everywhere except the API, where there is nothing to screenshot and the log is already text.

**Pareto by medium.** Most people using these models are in a web or mobile chat, where the share link exists. CLI and API users are the tail, and for them the screenshot or a text paste is already in hand. So the ranking the site should encourage is: share link first, screenshot second, text third.

**This reopens round 7's cut, and the razor answers it differently now.** We cut the share-link *importer*: fetching, extracting, snapshotting. That stays cut. But accepting a share link costs nothing: a URL pasted into the review text is auto-linked, and the reader clicks through to the vendor's page, which is the highest-fidelity artifact possible. The site adds no code beyond auto-linking. Link rot is real and accepted for version one; snapshotting waits for rot to be observed.

**So the whole feature is an ordering, expressed as helper text.** The review box says:

```
Show what happened, easiest first:
1. paste a share link to the conversation
2. attach a screenshot
3. paste what you sent and what you got
```

Nothing is required. The image input and the text box already exist from round 8. The only new behavior is that URLs become links.

**What I concede in advance.** A share link is not verifiable proof of improvement, per round 7. It is the most faithful *example*, which is what the criteria ask for.

Challenge to Codex: does the scoring hold, and is auto-linking a share URL really zero-cost, or does it smuggle the importer back in?


### Codex

**Sign off on URL auto-linking; dissent on the universal ranking.** A clickable URL does not smuggle the importer back in. Keep it an ordinary outbound link: no fetching, preview card, extraction, or snapshot. It is small implementation work, not literally zero work.

The scoring assumes conditions we have not established:

- **Share links are not necessarily existing, one-tap artifacts.** Creating one can require selecting a scope, reviewing it, and copying it. ChatGPT links can represent an individual response rather than the whole conversation. [OpenAI sharing documentation](https://help-lb.openai.com/en/articles/7925741-sharing-conversations-and-scheduled-tasks-in-chatgpt).
- **Vendor hosting does not guarantee complete context.** Claude omits raw MCP tool data from shared snapshots. A share link can be excellent evidence of the visible exchange without being the highest-fidelity record of the tool's operation. [Claude sharing documentation](https://support.claude.com/en/articles/10593882-share-and-unshare-chats).
- **Text need not be composed twice.** A terminal transcript or request/response log may already be one selectable excerpt. Conversely, screenshots can require several captures for a long exchange. Fidelity depends on whether the relevant behavior is exact content, visual layout, or interaction.
- **Our audience distribution is unknown.** Calling CLI/API users the tail cannot settle priorities for this site.

Replace “easiest first” with neutral helper text:

> Show what happened: paste a conversation link or relevant text, or attach a screenshot. Include enough context to understand the result; omit private information.

That preserves every option without teaching an unsupported hierarchy. The best artifact is whichever the contributor already has that captures the relevant behavior faithfully. We can observe choices before recommending a default.

My challenge: will you accept auto-linking while dropping the claim that share links universally dominate screenshots and text?

### Claude (closing round 10)

**Correction from the user (2026-09-18):** share links do not exist for users outside the web and mobile interfaces, so they cannot be listed first.

Accepted, and Codex's dissent says the same thing with evidence: making a share link is not always one tap, a ChatGPT link may cover one response rather than the conversation, a Claude link omits tool data, and our audience split across mediums is unknown. The "easiest first" ranking taught a hierarchy the criteria do not support once all four mediums count.

**Re-scoring under both criteria across all mediums.** The only option that satisfies low friction and acceptable fidelity for every medium is the artifact the contributor already has, whatever form it takes. For web chat that may be a link, for a terminal it is a selectable excerpt, for an API it is the log, for a phone it is a screenshot. The site should not guess which.

**What survives.** URL auto-linking as an ordinary outbound link, no fetching or preview card. Neutral helper text in the review box:

> Show what happened: paste a conversation link or the relevant text, or attach a screenshot. Include enough context to understand the result; omit private information.

Nothing is ranked, nothing is required, and nothing new is built beyond the link. We observe which forms contributors actually choose before recommending any default.

## Round 11: the best medium for the example, given multimodal outputs

**From the user (2026-09-18):** continue until both partners reach consensus on the best medium for the example. Claude, ChatGPT, and Gemini all produce text, image, and video outputs.

### Claude

**First principle.** The example represents the model's output. The output has a native form: text, an image file, a video file. The most faithful example of an output is the output itself, in its native form. Everything else is a copy at a loss: a screenshot of a generated image is a worse image; a description of a video is not a video; a transcription of text is fine because text copies losslessly.

**What that implies for each output type.**

| Output type | Native artifact | Faithful example | Lossy fallback |
|---|---|---|---|
| Text | The text | Pasted text | Screenshot |
| Image | The image file | The file itself | Screenshot of it |
| Video | The video file | The file itself | A frame, or a link |

**So the medium is not one medium.** It is "the artifact, as produced." The site's job is to accept the artifact in its native form and do nothing to it.

**Occam.** The review already has a text box and an image input. Text output goes in the box. Image output goes in the image input, which already accepts screenshots, so generated images cost nothing new. Video is the only real addition, and it is expensive: storage, transcoding, playback, and size limits. Under Pareto, text outputs dominate tip usage today, images are second, and video is rare and heavy.

**Proposal for consensus.**

1. The best medium for an example is the native output artifact. Text as text, image as the image file, video as the video file.
2. Version one accepts text and images by attachment. Video is accepted as a link to wherever it is hosted, since the vendors and video sites already host it. Video upload waits for the signal that video-tip reviews are arriving with links that rot.
3. The input, what the person sent, is always text, because prompts are text even when the output is not. Input images (a photo the user gave the model) are attached the same way as any image.
4. Screenshots remain valid for any type, as the lossy fallback.

**What I am not sure of.** Whether "attach a file" should be one control that accepts image or video from day one, with a size cap, rather than an image-only control plus a link. One control is simpler to explain. Two behaviors is less to build. I lean to one control, image-only in behavior, because the razor prefers less to build over less to explain.

Challenge to Codex: agree that the native artifact is the medium, then decide the video question: one control accepting video with a cap, or link only until observed?


### Codex

**Agreed: prefer the native artifact when it captures the behavior the tip concerns. Video stays link-only in version one.** That gives us a shared decision without declaring one file type universally best.

Three corrections make the principle accurate:

- **An output alone may not demonstrate the technique.** For a tip about the generated result, the original text, image, or video is usually the best example. For a tip about interface behavior, formatting, or a sequence of actions, a screenshot or recording can be the primary evidence. It need not be an inferior fallback.
- **Inputs are not always text.** An example may depend on an image, audio, video, file, or earlier conversation. Ask contributors to include or describe the relevant input and conditions using the review's existing text, image, and link capabilities. Do not pretend an omitted input is preserved.
- **A link is a delivery mechanism, not an inherently lossy medium.** A link to a playable original video can preserve the behavior perfectly well. Accessibility and durability are the tradeoffs; a still frame cannot demonstrate motion.

The version-one control should therefore say **“Attach image,”** accepting generated images and screenshots, alongside the text box with ordinary clickable links. Keep image paste, thumbnail, and removal. Do not advertise unrestricted file upload while rejecting video.

A size cap alone does not justify adding video hosting. Revisit uploads when actual contributors cannot provide accessible, durable video examples through links and that gap materially limits useful tips. Link rot is one possible signal, not the sole trigger. We need no assumption about which output type dominates our eventual audience.

I sign off on this scope: **preserve the relevant artifact with the least contributor effort; text and images inline, video by link.**

### Consensus on the medium for examples (both partners signed)

**Principle.** Preserve the artifact that shows the behavior the tip concerns, with the least contributor effort. Usually that is the native output: text as text, an image as the image file, a video as a link to the playable original. When the tip is about interface behavior, formatting, or a sequence of actions, a screenshot or recording is the primary evidence, not a fallback.

**Version one.** The review has a text box with ordinary clickable links, and one control labeled "Attach image" that accepts generated images and screenshots, by paste or file chooser, with a thumbnail and a remove action. Video is by link only. Nothing else is built, and no file type is declared universally best.

**Inputs.** Prompts are usually text, but an example may depend on an input image, file, or earlier conversation. Contributors are asked to include or describe the relevant input and conditions using the same text, image, and link capabilities. The site does not pretend an omitted input is preserved.

**Video upload is revisited when** contributors demonstrably cannot provide accessible, durable video examples through links and that gap limits useful tips. Link rot is one signal among several, not the trigger.

**Corrections accepted from Codex in this round.** An output alone may not demonstrate the technique. Inputs are not always text. A link is a delivery mechanism, not a lossy medium.

## Round 12: adversarial review of "upload an image or a video"

**From the user (2026-09-18):** what if the review offers one upload for an image or a video? The image is a screenshot of the output or the actual output image. The video is a recording of the interaction or the actual generated video. Adversarially review this idea.

### Claude (prosecution)

**Steelman first.** One control is easier to explain than "image here, video by link." README GIFs prove that short recordings are the best artifact for interface and workflow behavior. Vendor video share links may not exist everywhere, and links rot. A ten-second clip with a hard cap is not expensive with a CDN. So the idea is not foolish. Now the attack.

**1. The word "video" costs one letter in the label and a different system in the build.** Image attach is a file field and an `<img>` tag. Video attach is storage that grows without bound, transcoding or a format whitelist, playback across browsers, upload progress and resumption on mobile, bandwidth on every view, and a moderation queue that must watch content rather than glance at it. The razor says build for the eighty percent. Video is the rare case, and it carries the largest cost.

**2. Screen recordings are the worst medium for the most common tip.** Most tips are about text output. A recording of a text reply forces the reader to scrub video to read words they could have copied. It is higher friction to produce (start, stop, trim, export, upload) and lower fidelity to consume (not searchable, not copyable, not quotable) than a paste. Offering the affordance invites the worse choice.

**3. For generated video, upload duplicates what the vendor already hosts.** The only gain over a link is durability, and durability has not been shown to be a problem yet. We would be paying storage on every review to insure against a rot rate we have not measured.

**4. Exposure is unbounded.** A screenshot leaks what is in the frame. A recording leaks notifications, other tabs, audio, and whatever scrolls past. The one-line privacy reminder that suffices for images does not suffice for recordings, and the site has no redaction tool by design.

**5. Abuse surface.** A site that accepts video uploads from anonymous contributors is a free video host until proven otherwise. Copyright claims, illegal content, and takedown handling arrive with the feature, whether or not any tip needs it.

**6. It undoes a decision we reached on evidence.** Round 11 settled video by link with a stated trigger for revisiting. Adding "or a video" to the control reopens it with no new signal.

**7. The unified control teaches the wrong ranking.** Round 10 removed hierarchy from the helper text so that contributors use what they already have. A control that says "image or video" nudges toward producing a video, which nobody already has for a text tip.

**Narrowest version that might survive.** If interface and workflow tips turn out to need motion, allow a short clip: hard cap on seconds and megabytes, browser-native formats only, no transcoding, no audio, played with a plain video tag. That is "attach a clip," not "video hosting," and it costs a fraction. But it waits for the trigger.

Verdict I am arguing for: reject for version one; video stays a link.

Challenge to Codex: attack the idea harder if I missed something, and attack my prosecution where it overreaches.


### Codex

**The missing attack: one control can conceal a broken contribution path.** If users pick an existing recording and only afterward discover it exceeds the limits, they must trim, compress, or convert it elsewhere. The interface looks simple while exporting work to the contributor. Judge the proposal against files people actually have, not an ideal ten-second sample. A recording can also make readers wait through irrelevant steps; native fidelity alone does not ensure a useful example.

**Your prosecution overreaches in five places.**

1. We have no evidence that video is rare for this site's intended tips. “Eighty percent” is an empirical claim, not permission to assume our preferred workload.
2. Uploading can avoid creating a public vendor link or finding another host. Its benefit is not limited to durability. A generated video or existing recording may already be the easiest artifact to attach.
3. Images also require storage, validation, moderation, and abuse controls. Video increases some costs; it does not invent every operational responsibility. Conversely, calling a capped upload a “clip” does not make it cease to be video hosting.
4. A neutral image/video picker does not inherently encourage people to record text. That contradicts our decision to let contributors choose the artifact they already have.
5. Prior consensus is not evidence against reconsideration. The user explicitly reopened the choice; our earlier decision cannot prosecute the new proposal.

Your narrow version also compromises the stated goal: excluding audio can discard relevant behavior, while short duration and size limits can reject the native artifact. Those restrictions need justification from example needs, not just implementation convenience.

**Verdict: keep video by link for version one, provisionally—not because a unified upload is wrong.** We lack representative examples showing that its contribution benefit warrants the additional work. Before building it, walk through actual generated videos and workflow recordings: what would uploading require, what would linking require, and could readers inspect the relevant behavior easily? If native upload wins materially, accept one image/video control with explicit supported limits. Do not build an artificially narrow clip feature merely to claim video support.

### Joint verdict on "upload an image or a video"

**Decision.** Video stays by link in version one. This is provisional and evidence-based, not a rejection of the idea on principle.

**Points from the prosecution that stand.** Video attach is a different system from image attach: unbounded storage, playback, mobile upload, bandwidth, and moderation that must watch rather than glance. Screen recordings are a poor medium for text-output tips, which are not searchable, copyable, or quotable. Recordings leak more than screenshots and the site has no redaction tool by design.

**Where the prosecution overreached, conceded.** "Video is rare" and "eighty percent are text tips" are empirical claims about an audience we have not met. Uploading has a benefit beyond durability: it avoids creating a public vendor link or finding a host. Images carry storage, validation, and moderation costs too; video enlarges them rather than inventing them. A neutral picker does not by itself nudge people to record text. The round 11 consensus cannot be used as evidence against a proposal the user explicitly reopened.

**Codex's added attack that stands.** A unified control can hide a broken path: a contributor selects a real recording, discovers after the fact that it exceeds limits, and is sent elsewhere to trim or convert. The control looks simple while exporting the work to the contributor. Judge the feature against files people actually have.

**The narrow "clip" compromise is rejected too.** Stripping audio and capping seconds can discard the relevant behavior or reject the native artifact. A restricted version built to claim video support satisfies neither criterion from round 10.

**What would change the decision.** Walk through real generated videos and real workflow recordings: what uploading requires, what linking requires, and whether a reader can inspect the relevant behavior easily either way. If native upload wins materially on friction or fidelity, build one image/video control with explicit, honest limits stated before the file is chosen.

## Round 13: the interaction model, clarified

**From the user (2026-09-18):** clarification. Tips stay text. The output example is a link or an upload of an image or a video. High-level model: a human sends a text prompt to an AI model; the model produces text, an image, or a video.

### Claude

**The model, stated plainly.**

```
prompt (text, contains the tip)  ->  model  ->  output (text | image | video)
```

That is the whole interaction. So an example is a pair: the prompt, and the output. The prompt is always text. The output's medium is decided by the model, not by the contributor. That single fact resolves most of round 12.

**What round 12 was really arguing about.** The prosecution's strongest points were about screen recordings: scrubbing video to read text, unbounded length, leaked notifications and audio. Under the user's model, a recording is not an output. The video slot holds what the model produced. Generated videos are short by construction, because the models produce seconds, not hours. The unbounded-storage and privacy-leak arguments were arguments against recordings, and recordings are out of the model. The remaining cost is hosting bounded, short files, which is the same class of cost as images, only larger.

**Structure of the example, derived rather than designed.**

| Part | Medium | How it gets in |
|---|---|---|
| Prompt | Text, always | Text box |
| Output, if text | Text | Text box, or a screenshot |
| Output, if image | Image file | Upload, or a link |
| Output, if video | Video file | Upload, or a link |

Two slots: what I sent, what I got. The second slot accepts text, an image, or a video, and the contributor picks what matches what the model made. That is not a unified "media picker" nudging anyone toward video. It is the output slot accepting the output's native form.

**The one bound that makes video affordable.** The upload limit is sized to what the models produce, stated before the file is chosen. A generated video that fits within what a model emits fits within the limit by construction. Anything larger is not a model output and is the thing round 12 was right to exclude. Links remain accepted for anyone who prefers them or whose file exceeds the bound.

**What this leaves unchanged.** Tip is text. Review is: verdict, model, environment, prompt text, output in native form, optional note. Screenshots stay valid for text outputs, and for interface tips where the screen is the point.

**Revised position on round 12.** The verdict rejected a control that admitted recordings. With recordings excluded by the interaction model and a limit derived from model output rather than convenience, an image-or-video output slot satisfies both of the user's criteria: lowest friction (the file the model handed you) and highest fidelity (the file itself).

Challenge to Codex: does the interaction model dissolve your round 12 concerns, or does one survive? And is "limit sized to what models produce" a real bound or a rationalization?


### Codex

**Sign off on the two-slot example: prompt text, output in its native form.** Accept text, an image, or a video as output, with links as an alternative. This is a clearer contribution model, and I withdraw my version-one objection to video upload. Keep examples optional within reviews; questions and corrections must not require fabricating a prompt/output pair.

**“Sized to what models produce” is a sizing input, not a bound.** It supplies neither a number nor a stable maximum. File size depends on encoding, resolution, duration, and other choices. A larger file can still be a genuine model output; size cannot establish provenance. The model that produced a file also does not determine how many files people will upload or how often readers will download them.

The surviving concerns are concrete:

- Supported files must upload and play successfully without forcing contributors into unexpected conversion work.
- Individual file limits do not bound total storage, bandwidth, or moderation work.
- Generated content can still contain private or harmful material. Excluding recordings removes incidental screen capture concerns, not all content concerns.
- “Generated output only” describes intended use; an upload control cannot infer that a file came from a model.

Set an explicit byte limit and supported formats, visible before selection and enforced on upload. Choose initial limits from representative artifacts and an affordable operating budget. Keep the link path for unsupported or oversized outputs without declaring those outputs illegitimate. No precise limit can be justified from brainstorming alone.

This clarification settles the product direction, not the operating costs. The strongest argument for upload is that the contributor already has the output file. We do not need the unsupported claim that generated videos are inherently small or that every permitted file will be cheap to host.

### Consensus on the example structure (both partners signed)

**Interaction model.** A human sends a text prompt to an AI model; the model produces text, an image, or a video. The tip is text. An example is the pair.

**The example has two slots.** "What I sent" is text. "What I got" is the output in its native form: text, an image file, or a video file, with a link accepted as the alternative for any of them. Examples are optional within reviews; a question or a correction never has to fabricate a pair.

**Round 12's verdict is superseded.** The concerns that stood were about screen recordings. The interaction model puts the model's own output in the slot, so recordings are outside the design and Codex withdraws its objection to video upload in version one.

**Correction accepted from Codex.** "A limit sized to what models produce" is a sizing input, not a bound. It gives no number, size cannot establish provenance, and a per-file limit bounds neither total storage nor bandwidth nor moderation. Instead: an explicit byte limit and a list of supported formats, visible before the file is chosen and enforced on upload, with initial values picked from representative artifacts and an affordable operating budget. Oversized or unsupported outputs use the link path and are not declared illegitimate.

**Surviving concerns, carried into implementation rather than resolved here.** Supported files must upload and play without conversion work. Generated content can still contain private or harmful material, so moderation covers uploads. The control cannot verify a file came from a model; "generated output only" is intended use, not enforcement.

**Version one review, final.** Verdict (no verdict default, worked, didn't). Model and environment, unknown allowed. Optional example: prompt text, output as text, image, video, or link. Optional note. At least one of verdict, note, or example is required. Image and video inputs by paste or file chooser, thumbnail, remove action, limits stated up front.

## Round 14: UI/UX review of the prototype

**From the user (2026-09-18):** Claude built a clickable prototype of three screens (main page, submit a tip, leave a review) as `docs/brainstorm/try-this-prototype.html`. Codex is asked to review it for UI/UX.

### Claude (design intent, for the reviewer)

Emotions targeted: utility, honesty, trust, quiet generosity. Search is the hero on the main page. Counts are always scoped to the selected model and environment and say so; empty states are visible. The copy box is the one lifted object on every screen. The review form is the round 13 consensus: no-verdict default, model and environment, "what I sent" and "what I got" with attach, link, and limits stated before choosing a file, thumbnail with remove, optional note, privacy line. The submit form is four fields, two optional. Nothing gamified.


## Round 15: two additions from review-site patterns

**Decision by the user (2026-09-18):** after surveying IMDb, Yelp, TripAdvisor, Google Maps, and Steam, two patterns join version one.

1. **Recent versus all-time counts.** Beside every tip's worked and didn't counts, show the same counts for the last 90 days. Steam's "recent reviews / all reviews" pattern. Answers the freshness problem from round 0 without a release calendar. Same data, one date filter.
2. **Filter reviews by verdict.** On a tip page, a toggle to show only worked, only didn't work, or all. Yelp and Amazon's one-star filter. Reading the failures is the fastest way to learn a tip's limits.

Both are scoped to the selected model and environment like everything else. Neither ranks anything.

### Claude

**Version one, updated.**

- **Find** now shows two count pairs per tip for the selected setup: last 90 days and all time. When the recent pair is empty it says "no reports in the last 90 days" rather than hiding.
- **Review list** gains one control: All / Worked / Didn't work. Default is All. No-verdict reviews appear under All only.

Deferred items reviewed in the same survey, with triggers, are recorded in the user-facing summary: vendor responses, suggest-an-edit, helpful votes, pinned top positive and critical, related tips.

Codex: implementation notes only, the decision is made. Anything about the 90-day window, the empty state, or how the verdict filter interacts with setup scoping?


### Codex

- **Window:** use a rolling 90 × 24 hours, calculated from one server timestamp per response. Include reviews with `reported_at >= now − 90 days` and `reported_at <= now`. Store timestamps in UTC; display dates locally. Editing a review must not refresh its original reporting date. Label this “Reported in the last 90 days,” not recently tested or verified.
- **Counts:** compute recent and all-time pairs from the same model/environment scope. Count only worked/didn't verdicts; no-verdict reviews enter neither pair. Recent counts are a subset of all-time counts.
- **Empty states:** distinguish “No outcome reports for this setup” from “No outcome reports in the last 90 days.” Preserve historical counts. If questions or corrections exist, do not imply that there are no reviews.
- **Verdict filter:** intersect All / Worked / Didn't work with the current setup. All includes no-verdict reviews within that scope. Changing verdict filters the list only, leaving both count pairs unchanged. The list remains all-time, newest first; the recent-count display does not silently filter it.
- **No matches:** say “No didn't-work reviews for this setup,” with an action to show All. Label unrestricted scopes explicitly; exclude unknown setups from named-setup counts.

### Claude (closing round 15)

All of Codex's notes accepted. The ones that change wording on the page: the recent label reads "Reported in the last 90 days"; the two empty states are distinct ("no outcome reports for this setup" versus "none in the last 90 days"); the verdict filter changes the list only, never the counts; and the no-match state for a verdict filter offers a one-click return to All.

## Round 16: adversarial review of the data model

**From the user (2026-09-18):** Claude wrote a Postgres data model at `docs/brainstorm/data-model.md`. Codex is asked to review it adversarially as a senior backend engineer with orthogonal expertise and perspective.


### Codex

Static review; no running Postgres was available. Constraint failures follow directly from the SQL; performance concerns require `EXPLAIN (ANALYZE, BUFFERS)` with skewed data.

1. **P1 — Attachment-only reviews cannot publish.** The `reviews` CHECK rejects a row whose verdict/text fields are NULL before the attachment INSERT runs. A transaction does not defer CHECK constraints. Remove this incompatible CHECK and enforce nonempty content through one controlled transactional write path, including attachment removal; alternatively use a deferred constraint trigger. Never insert dummy text to bypass it. [Postgres constraint timing](https://www.postgresql.org/docs/current/sql-createtable.html).

2. **P1 — Public reads expose internal identity and bypass parent moderation.** Query 2 selects `r.*`, including the stable `submitter_key`; use an explicit public column list. It also returns published reviews for a held/removed tip. Require the parent tip to be published for public reviews, counts, and attachment access. Soft-deleting database rows does not revoke public object URLs; define how media access is withdrawn.

3. **P1 — Upload publication has no lifecycle.** A database transaction cannot atomically commit object storage. Query 4 can leave missing files or orphaned uploads. Stage uploads privately, verify existence, actual type and size server-side, then publish; clean abandoned objects. Add positive byte/dimension checks and unique storage keys. “Nothing is ever deleted” is not an adequate retention policy for uploaded private material or accumulated rejected files.

4. **P1 — Counts are cheap only under favorable distributions.** `reviews_counts` still scans every matching historical verdict for each tip; a single viral tip defeats the “millions of reviews” assurance. Query 1's outer LIMIT does not guarantee only 20 lateral executions, especially when search requires sorting. Select the tip page first, then aggregate its counts. Measure one hot tip, mostly historical reviews, and rare setups before deciding on cached counts. `INCLUDE` does not guarantee heap-free access after writes. [Index-only scan conditions](https://www.postgresql.org/docs/18/indexes-index-only-scans.html).

5. **P1 — Anonymous retries and cookie rotation can inflate evidence.** Add submission idempotency and enforce write/upload quotas beyond a resettable cookie. Issue unpredictable edit tokens server-side, hash them, and authorize every edit. Do not treat a cookie as proof of a unique person. Keep accounts deferred.

6. **P2 — Query 2 does excessive work before pagination.** Attachment aggregation precedes LIMIT; page matching reviews first, then attach their media. `reviews_by_tip` cannot narrow model/environment/verdict, so rare-filter requests may scan many rows. Optional OR predicates also need generic/custom-plan testing; do not promise every index will provide a selective range. [Prepared plans](https://www.postgresql.org/docs/current/sql-prepare.html). Add an `id` tiebreaker and keyset pagination for chronological lists; deep OFFSET remains costly.

7. **P2 — Integrity and freshness gaps.** Empty strings satisfy the content CHECK; whitespace-only titles pass length checks. Normalize blanks, cap review/flag text, validate link schemes, and keep timestamps server-controlled and immutable. Use one cutoff, `interval '2160 hours'`, and an upper bound for recent counts: calendar days can differ across DST. [Datetime semantics](https://www.postgresql.org/docs/17/functions-datetime.html). Substantial tip edits must not silently inherit evidence for different instructions; freeze instructions once reviewed or retain revisions. Model IDs likewise need stable version meaning.

**Change before shipping:** fix these boundaries, benchmark the actual queries, and name constraints. For populated tables, stage constraint validation and use concurrent index builds where needed; those builds require migrations outside transaction blocks. [Index deployment](https://www.postgresql.org/docs/current/sql-createindex.html).

**Leave alone:** nullable no-verdict/setup fields, separate attachments, flag-target exclusivity, enums, plain full-text search, free-text tool names, and live counts initially. Do not add partitioning, accounts, or summary tables without measurements.

### Claude (response and revision)

All seven findings accepted. `data-model.md` is rewritten. What changed, by finding:

1. **Attachment-only reviews.** The CHECK is gone. A deferred constraint trigger on reviews and attachments runs at commit, when both rows are visible. The app validates first; the trigger is the backstop.
2. **Exposure and parent moderation.** Every public query lists its columns. `submitter_key`, `edit_token_hash`, and `storage_key` are never selected publicly. Query 2 joins the parent tip on `status = 'published'`. Media is served through short-lived signed URLs minted only when attachment, review, and tip are all published, so soft delete withdraws access when the last URL expires.
3. **Upload lifecycle.** Attachments carry a state: staged, published, purged. Stage with a signed upload URL, verify real size and sniffed type server-side, publish in the same transaction as the review, purge staged objects after 24 hours and removed reviews' objects after 30 days. Unique storage keys and positive byte and dimension checks added.
4. **Counts under skew.** Query 1 materializes the page of 20 tips in a CTE first, then runs the lateral count, so at most 20 count scans per request however search sorts. The summary table now has a measured trigger: p95 over budget with the count scan dominating in `EXPLAIN (ANALYZE, BUFFERS)`.
5. **Anonymous inflation.** `client_request_id` with a unique constraint and `on conflict do nothing` makes every write idempotent. `edit_token_hash` authorizes edits; the cookie never does. IP quotas sit beside the cookie for rate limiting.
6. **Query 2 work before pagination.** Reviews are paged first by keyset on `(reported_at, id)` with `id` as tiebreaker and the index extended to match; attachments are fetched per row of the page. Rare-filter scans are accepted for version one and named.
7. **Integrity and freshness.** All length checks use `btrim`. Links must be http or https and at most 2048 characters. Note, sent, got, and flag reason are capped. The recent window is `interval '2160 hours'` with an upper bound of `now()`. Tips are immutable once published; editing means publishing a new tip, so evidence never migrates to different words. Model rows are never renamed to mean a different model. Every constraint is named. Concurrent index builds and `not valid` then validate for populated tables.

Left alone, as Codex advised: nullable no-verdict and setup fields, separate attachments table, flag target exclusivity, enums, plain full-text search, free-text tool names, live counts, no partitioning, no accounts.
