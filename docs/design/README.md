# Design docs

The six files below are the product and technical requirements. Read the sections
your task names, not whole files. `scripts/check_docs.py` fails when a link here
points at a missing heading or a design-doc section has no row here.

| File | Owns |
|---|---|
| [software-architecture.md](software-architecture.md) | System boundaries, contexts, runtime and deployment |
| [backend-design.md](backend-design.md) | Operations, permissions, transactions and integrations |
| [data-model.md](data-model.md) | Tables, indexes, queries and database rules |
| [frontend-design.md](frontend-design.md) | Pages, forms, navigation and browser behaviour |
| [glossary.md](glossary.md) | Product terms and copy |
| [product-validation.md](product-validation.md) | Hypothesis, first audience and success signals |

## Read when

Cross-cutting sections. Read the row whose trigger matches your task.

| Read when | Sections |
|---|---|
| Choosing between designs | [Decision](software-architecture.md#decision), [Purpose and scope](software-architecture.md#purpose-and-scope), [Design approach](software-architecture.md#design-approach), [MVP design constraints](software-architecture.md#mvp-design-constraints), [Business requirements](backend-design.md#business-requirements), [Scope](backend-design.md#scope) and [Scope](frontend-design.md#scope) |
| Adding a module or choosing which context owns an operation | [System structure](software-architecture.md#system-structure), [Code boundaries](software-architecture.md#code-boundaries), [Agreed context boundaries](backend-design.md#agreed-context-boundaries), [Implementation foundation](backend-design.md#implementation-foundation) |
| Any operation that takes a viewer, scope or session | [Caller identity and access](software-architecture.md#caller-identity-and-access), [Business operations and transactions](backend-design.md#business-operations-and-transactions), [Admission, locking, and returned data](backend-design.md#admission-locking-and-returned-data) |
| Any write, or any read that touches deletion, hiding or bans | [Rules](data-model.md#rules), [Visibility and transaction boundaries](data-model.md#visibility-and-transaction-boundaries), [Defenses](data-model.md#defenses) |
| Any LiveView, controller or HEEx component | [Web experience](software-architecture.md#web-experience), [Foundation](frontend-design.md#foundation), [Boundary with the backend](frontend-design.md#boundary-with-the-backend), [Pages to design](frontend-design.md#pages-to-design), [Interaction and recovery](frontend-design.md#interaction-and-recovery): inbox, vote, placeholder, ban and sign-in form rules |
| Adding a pattern, dependency or capability | [Patterns used](data-model.md#patterns-used), [Other decisions](data-model.md#other-decisions), [Deferred features](data-model.md#deferred-features), [Future MCP access (v2)](backend-design.md#future-mcp-access-v2), [V2 direction: MCP access](software-architecture.md#v2-direction-mcp-access) |
| Writing acceptance scenarios for a brief | [Implementation acceptance](backend-design.md#implementation-acceptance), [Implementation acceptance](data-model.md#implementation-acceptance) with [Cross-layer acceptance](data-model.md#cross-layer-acceptance), [Implementation acceptance](frontend-design.md#implementation-acceptance) with [Cross-layer acceptance](frontend-design.md#cross-layer-acceptance) |
| User-facing copy | [Language](glossary.md#language), [Text columns and how they are displayed](data-model.md#text-columns-and-how-they-are-displayed) |
| Deciding what to build first or how to judge it | [Hypothesis](product-validation.md#hypothesis), [First audience](product-validation.md#first-audience), [First scenario](product-validation.md#first-scenario), [Success signals](product-validation.md#success-signals), [Seed content and recruiting](product-validation.md#seed-content-and-recruiting) |
| Migrations, extensions, CI databases or deployment | [Database implementation](backend-design.md#database-implementation), [Runtime and integration checks](backend-design.md#runtime-and-integration-checks), [Tables](data-model.md#tables), [Indexes](data-model.md#indexes), [Runtime and reliability](software-architecture.md#runtime-and-reliability), [Development feedback](software-architecture.md#development-feedback), [Deployment](software-architecture.md#deployment) |
| Sources the docs cite | [References](backend-design.md#references), [References](frontend-design.md#references) |

## By feature

| Feature | Backend | Data model | Frontend |
|---|---|---|---|
| Browse, search and filters | [Task-first discovery](backend-design.md#task-first-discovery), [Main feed and clickable filters](backend-design.md#main-feed-and-clickable-filters), [Bounded search pagination](backend-design.md#bounded-search-pagination) | [Pagination](data-model.md#pagination), [Read groups per page](data-model.md#read-groups-per-page), [Queries](data-model.md#queries), [Browse](data-model.md#browse), [Search](data-model.md#search) | [Navigation and content](frontend-design.md#navigation-and-content), [Paged reading lists](frontend-design.md#paged-reading-lists), [Search retrieval and list state](frontend-design.md#search-retrieval-and-list-state) |
| Tip and review pages | [Individual review links](backend-design.md#individual-review-links), [Proposed context contract](backend-design.md#proposed-context-contract) | [Tip page](data-model.md#tip-page) | [Interaction and recovery](frontend-design.md#interaction-and-recovery) |
| Publishing and drafts | [Publishing and draft recovery](backend-design.md#publishing-and-draft-recovery), [Review content and evidence](backend-design.md#review-content-and-evidence), [Browser drafts](backend-design.md#browser-drafts), [Publishing and retry contract](backend-design.md#publishing-and-retry-contract) | [Publish retries](data-model.md#publish-retries), [Publish a tip or review](data-model.md#publish-a-tip-or-review) | [Result composer](frontend-design.md#result-composer), [Saving and recovery](frontend-design.md#saving-and-recovery), [Publication-to-edit handoff](frontend-design.md#publication-to-edit-handoff) |
| Images and GIFs | [Image/GIF upload integration](backend-design.md#imagegif-upload-integration) | [Upload](data-model.md#upload), [Image/GIF attempts](data-model.md#imagegif-attempts) | [Result composer](frontend-design.md#result-composer) |
| Video | [Managed video](backend-design.md#managed-video), [Video upload before publication](backend-design.md#video-upload-before-publication) | [Upload](data-model.md#upload), [Video states and deadlines](data-model.md#video-states-and-deadlines), [Playback and cleanup](data-model.md#playback-and-cleanup) | [Result composer](frontend-design.md#result-composer) |
| Markdown and embeds | [Markdown, embeds and secure headers](backend-design.md#markdown-embeds-and-secure-headers) | [Text columns and how they are displayed](data-model.md#text-columns-and-how-they-are-displayed) | |
| Editing | [Editing and conflicts](backend-design.md#editing-and-conflicts) | [Edit](data-model.md#edit) | [Publication-to-edit handoff](frontend-design.md#publication-to-edit-handoff) |
| Voting | [Voting](backend-design.md#voting) | [Vote](data-model.md#vote), [Counter repair](data-model.md#counter-repair) | |
| Author deletion | [Author deletion confirmation](backend-design.md#author-deletion-confirmation), [Author-deleted tip pages](backend-design.md#author-deleted-tip-pages) | [Delete, by the author](data-model.md#delete-by-the-author) | [Author deletion](frontend-design.md#author-deletion) |
| Reports and moderation | [Reports and moderation](backend-design.md#reports-and-moderation), [Bans and lifting a ban](backend-design.md#bans-and-lifting-a-ban), [Dismissing reviewed reports](backend-design.md#dismissing-reviewed-reports), [Permanent removal of selected media](backend-design.md#permanent-removal-of-selected-media) | [Moderate](data-model.md#moderate) | [Reporting interaction](frontend-design.md#reporting-interaction), [Moderation queue](frontend-design.md#moderation-queue), [Dismissing reviewed reports](frontend-design.md#dismissing-reviewed-reports), [Permanent removal of selected media](frontend-design.md#permanent-removal-of-selected-media), [Lifting a ban](frontend-design.md#lifting-a-ban) |
| Sign-in, signup and sessions | [Authentication](backend-design.md#authentication), [First-time signup](backend-design.md#first-time-signup), [Sessions and authentication foundation](backend-design.md#sessions-and-authentication-foundation), [Session renewal and logout](backend-design.md#session-renewal-and-logout), [Authentication email delivery](backend-design.md#authentication-email-delivery), [Changing the sign-in email](backend-design.md#changing-the-sign-in-email), [Lost mailbox access](backend-design.md#lost-mailbox-access) | [Other decisions](data-model.md#other-decisions) | |
| Account deletion and full bans | [Full bans and deletion](backend-design.md#full-bans-and-deletion), [Account-deletion confirmation](backend-design.md#account-deletion-confirmation) | [Account deletion](data-model.md#account-deletion) | [Account deletion](frontend-design.md#account-deletion) |
| Profiles | [Profile reads](backend-design.md#profile-reads) | [Profile](data-model.md#profile) | [Navigation and content](frontend-design.md#navigation-and-content) |
| Notifications | | [Notifications](data-model.md#notifications) | [Paged reading lists](frontend-design.md#paged-reading-lists) |
| Background jobs and health | [Durable background work](backend-design.md#durable-background-work), [Independent background-progress checks](backend-design.md#independent-background-progress-checks) | [Durable jobs and search pages](data-model.md#durable-jobs-and-search-pages) | |
