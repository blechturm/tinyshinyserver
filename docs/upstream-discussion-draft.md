<!--
DRAFT, NOT SUBMITTED. To be posted only after human review and approval.
Intended as a GitHub discussion or issue on lab1702/tinyshinyserver, before
any pull request. REPORT_URL and BRANCH_URL are filled in once the branch
is pushed.
-->

# Idea: several R processes per app ("replicas"), with each session pinned to one

Hi, and thanks for tinyshinyserver. Its small, readable code made the
following experiment possible. Before turning it into a pull request, I'd
like to ask whether you would want this feature at all, and if so, in what
form.

To be upfront: I did this spike with Claude Code (Anthropic's AI coding
assistant). It wrote the code, the benchmarks and the write-up under my
direction; I reviewed the design and the results.

## The problem

Each app runs as one R process, so all of its users share one R thread.
When one user starts a computation that takes a few seconds, or a
synchronous database call waits, every other user of that app waits too,
even for trivial interactions. On a machine with more than one core, an
app also cannot use more than one.

## The idea

An optional `replicas` field on an app:

```json
{ "name": "demo", "path": "./apps/demo", "resident": true, "replicas": 4 }
```

- At configuration time, the entry is expanded into four ordinary apps,
  `demo-1` to `demo-4`, which the existing code starts, supervises,
  restarts and stops as it does any app.
- A visit to `/proxy/demo/...` answers with a `307` redirect to
  `/proxy/demo-k/...`, chosen by least connections (the default) or round
  robin, among replicas that are running or allowed to start.
- From then on, the browser talks to the replica's address. Its page,
  assets, WebSocket, uploads and downloads stay on one process without any
  change to the proxy code, because the URL *is* the affinity.
- Entries without `replicas` behave exactly as before. No new dependencies.

The core is about 280 lines of R (`R/replicas.R` plus small hooks in
config reading, the proxy handler and the landing page), with about 400
lines of tests. All 3503 existing tests pass unmodified.

## What it does in a benchmark

I measured with a protocol-level Shiny load generator, in Docker on 1 and 2
pinned vCPUs. The app mixes cheap reactive operations with one of: 0.5 s
CPU computations (20% of users), 0.5 s blocking `Sys.sleep()` calls (20%
of users), or only CPU work. Times are for cheap operations unless stated.

| Situation | One process (today) | 8 replicas |
|---|---|---|
| 1 vCPU, 20 users, 20% run 0.5 s computations: cheap operations over 250 ms | 56% | 3% |
| 1 vCPU, 40 users, same: median | 2.6 s | 7 ms |
| 1 vCPU, 20 users, 20% wait on blocking I/O: cheap operations over 250 ms | 92% | 4% |
| 1 vCPU, 80 users, blocking I/O: blocking calls completed per second | 1.7 | 8.1 |
| 2 vCPUs, only CPU work: jobs per second | 3.9 | 6.8 (already with 2 replicas) |

Where it does **not** help, or costs:

- When every user computes, one vCPU does the same amount of work with or
  without replicas; replicas only share out the waiting.
- Each replica is a full R process: about 110–150 MB for a minimal app,
  plus whatever data the app loads.
- Under extreme CPU starvation (1 vCPU, 80 users, 8 replicas), new
  sessions start much more slowly (p95 34 s vs. 9 s). This comes from the
  existing WebSocket relay: the `websocket` package's handshake timeout is
  fixed at 5 s, so a starved replica's handshake times out and the client
  retries.
- With one process, the change costs nothing measurable.

Replicas also combine well with async code in the app. With the heavy
computation in a `shiny::ExtendedTask` on mirai daemons, plus 4 replicas,
only 0.3% of cheap operations took over 250 ms on 1 vCPU at 40 users,
against 25% with replicas alone and 70% with async alone: replicas stop
users from blocking each other without app changes, async keeps a
session's own computation out of the process that serves everyone else.

Full method, results and limitations: [REPORT_URL]. The branch also has
the raw data, the benchmark harness to rerun everything (`bench/README.md`)
and the code: [BRANCH_URL].

## Questions for you

1. **Is this in scope for tinyshinyserver at all?** I'd understand if you
   prefer to keep one process per app and point people to a load balancer
   in front.
2. **Configuration**: `replicas` (and `scheduler`) on an app entry, as
   above, or a separate group entry? Is a choice of scheduler worth having,
   or only least connections?
3. **Visible replica URLs**: the redirect makes `/proxy/demo-2/` visible in
   the address bar, bookmarks and shared links. That is what keeps the
   design so small, but it means a bookmark goes to a specific replica (and
   gets the starting page while that replica restarts). Would you accept
   that, perhaps with replica addresses redirecting back to the group when
   their replica is down?
4. **Dashboard**: list replicas individually (as now, for free), or grouped
   with a "restart group" action?

If you're interested, I'd prepare a pull request at your standard: docs,
NEWS, tests on all platforms, and the edge cases listed in the write-up
(failover of replica addresses, on-demand groups, reloads that change the
replica count). If not, no problem at all, and thanks for reading.
