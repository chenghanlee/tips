# Performance measurement

Read the relevant section when measuring a performance property identified by
[implement-software](../SKILL.md#performance).

## Choose the measurement tool

Tests may drive the workload, but measure the operation and resource being
investigated.

| Suspected cost | Evidence to use |
|---|---|
| Browser rendering or interaction | A [browser performance trace](https://developer.chrome.com/docs/devtools/performance) of the affected flow; inspect main-thread work, frames and paints. |
| Network or external-service delay | A request waterfall and request/server traces; separate round trips, server work and transfer time. |
| Database execution or contention | Query timings/counts, pool and lock statistics; [EXPLAIN ANALYZE with BUFFERS](https://www.postgresql.org/docs/current/using-explain.html) on representative disposable data when execution detail is needed. ANALYZE executes the query. |
| Application CPU or memory | A runtime profiler available in the installed toolchain, such as [mix profile.tprof](https://hexdocs.pm/mix/Mix.Tasks.Profile.Tprof.html); choose its mode for the suspected resource cost. |

When a database performance claim depends on an index or query strategy, inspect
its query plan with representative data instead of assuming the database will use it.

## Compare measurements

Use the profile to locate the bottleneck, then compare the affected operation before
and after under the same workload and conditions. Account for profiler overhead;
one favorable sample is not sufficient evidence of a gain. Test-suite duration mixes
setup and assertions and is not application performance.

Without real-user data, compare before and after under the same representative
device, network, cache and interaction conditions. Exercise the affected flow;
a fast localhost load or an aggregate Lighthouse score alone does not establish
user-perceived performance. Report these as lab results, not field percentiles.

Measure through the required outcome, including network round trips and browser
rendering where they affect completion. Limit claims to the workload actually tested.

## Frontend metrics

For frontend work, select the metrics affected by the change rather than running a
full audit for every UI edit:

- **Visible content:** distinguish [First Paint (FP) from First Contentful Paint
  (FCP)](https://developer.mozilla.org/en-US/docs/Web/API/PerformancePaintTiming).
  First pixels may be only a background; FCP marks the first content. Use Largest
  Contentful Paint (LCP) for when the largest visible content element renders.
  Inspect the critical request and rendering path before adding loading machinery.
- **Interaction and rendering:** use [Interaction to Next Paint
  (INP)](https://web.dev/articles/inp) for responsiveness. For requests or LiveView
  updates, also measure action-to-visible-result time; a quick loading indicator
  does not establish a quick result. Inspect frame times and main-thread work when
  interactions or scrolling stall. [Total Blocking Time (TBT)](https://web.dev/articles/tbt) is a lab
  diagnostic, not a substitute for exercising interactions.
- **Visual stability:** use Cumulative Layout Shift (CLS) to find unexpected movement.
  Reserve space for images and async content when their arrival shifts the interface.
- **Network:** inspect request waterfalls, round trips, payload sizes and cache
  behavior. [Time to First Byte (TTFB)](https://web.dev/articles/ttfb) includes more
  than network latency; use [resource timings](https://developer.mozilla.org/en-US/docs/Web/API/Performance_API/Resource_timing)
  and server timings as needed to distinguish connection, server and transfer costs.
  Remove unnecessary serial requests and critical-path bytes before adding caches
  or prefetching.

Use the task's performance requirements. [Core Web Vitals](https://web.dev/articles/vitals)
reference values are LCP <= 2.5 s, INP <= 200 ms and CLS <= 0.1 at the 75th percentile
of real visits, assessed separately for mobile and desktop; these are reference
values, not additional acceptance gates.
