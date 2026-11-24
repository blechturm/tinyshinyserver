# Engineering spike: session-aware load balancing in tinyshinyserver

Branch `spike/session-load-balancing`, from upstream `0f0a76d` (0.3.0).
This is an experiment, not a proposal ready for merging. It asks whether
tinyshinyserver's existing architecture can run several R processes for one
logical Shiny app, with each session pinned to one of them, and when that
helps. A second part evaluates [mizu](https://github.com/shikokuchuo/mizu)
shared-memory channels as an optional control plane between the server and
those processes.

## Summary

- **It fits the architecture.** A `replicas: N` setting on an app starts N
  ordinary app processes; the app's address redirects each new visitor to
  one of them (least connections or round robin), and the replica's own
  address keeps every later request, WebSocket, upload and download of
  that session on its process. Supervision, restarts and shutdown are
  upstream's, unchanged. About 280 lines of R plus tests; no new
  dependencies; configurations without `replicas` behave as before
  (upstream's 3503 tests pass unmodified).
- **It helps whenever one process makes users wait for each other**
  (section 5). With 8 replicas on a single vCPU, the share of light
  interactions slower than 250 ms falls from 56% to 3% when a fifth of 20
  users run 0.5 s computations, and from 92% to 4% when they wait on
  blocking I/O; blocking calls completed per second rise from 1.7 to 8.1 at
  80 users. On 2 vCPUs, replicas use the second core: 1.8× the throughput
  of CPU-bound work, which one R process cannot do.
- **It cannot create CPU.** When every user computes (scenario D), 1 vCPU
  completes the same work with or without replicas, and on 1 vCPU the heavy
  computations themselves get 10–30% slower while light users get their
  answers.
- **Costs**: about 110–150 MB of memory per replica (an R process with
  shiny), and slower session start-up under extreme CPU starvation (1 vCPU,
  80 users, 8 replicas: p95 34 s against 9 s), caused by the fixed 5 s
  handshake timeout of the `websocket` package used by the existing relay.
- **Follow-ups.** Replicas combined with async offloading (`ExtendedTask`
  and mirai) give the best responsiveness measured: 0.3% of light
  interactions over 250 ms on 1 vCPU at 40 users, against 25% with
  replicas alone and 70% with async alone. For apps with large data,
  memory limits the replica count; mori shares the data only until
  ordinary filtering code makes each process copy the columns it touches,
  while a read-only DuckDB file kept memory lowest at the price of slower
  queries.
- **mizu** (shared-memory channels) works as an optional per-replica
  telemetry channel for a workload-aware scheduler, but only through
  internal functions; see the mizu evaluation.
- Estimated effort to a mergeable contribution: about 3 weeks, mostly
  failover, on-demand edge cases, dashboard and tests.

## 1. Upstream architecture, as far as it matters here

- **One R session runs the server.** It holds an httpuv server for the proxy
  port, and another for the management port. Everything runs on that
  session's single event loop (httpuv plus `later`): request routing, HTTP
  forwarding (async libcurl via `curl::multi`), WebSocket relaying (the
  `websocket` package), health checks and restarts.
- **Each app is one `callr::r_bg()` process** listening on `127.0.0.1` at
  its own port (`R/process_manager.R`, `start_app()`). The process runs
  `shiny::runApp()`, or `rmarkdown::run()` for documents, after carefully
  reproducing the R startup an app would have on its own (`.Renviron`,
  `.Rprofile`, renv, library paths).
- **The proxy is path-based**: `/proxy/{name}/rest` goes to the app named
  `{name}`, with `/rest` passed on verbatim (`parse_proxy_path()`,
  `handle_proxy_request()`). WebSocket handshakes are routed the same way
  (`handle_websocket_connection()`). Cookies set by an app are rewritten to
  the app's path.
- **All runtime state is keyed by app name**: processes, ports, startup
  state, start failures and back-off, open WebSocket sessions
  (`app_sessions`, whose size is the connection count), in-flight HTTP
  requests, idle checks, log files.
- **Lifecycle**: resident apps start with the server; a health check every
  `health_check_interval` seconds (default 10) finds exited processes,
  closes their sessions and restarts resident apps after `restart_delay`
  (default 5). Restarts from the management API, configuration reload and
  shutdown iterate over app names.

Nothing in this design assumes that two apps have different paths. The
upstream README already notes that one directory may be served by two apps,
except Quarto and prerendered R Markdown documents, whose renders would
collide.

## 2. The change: replica groups behind a redirect

### Configuration

```json
{ "name": "demo", "path": "./apps/demo", "resident": true,
  "replicas": 4, "scheduler": "least_connections" }
```

`read_config()` expands such an entry into four ordinary apps, `demo-1` to
`demo-4`, each carrying `replica_of = "demo"` (an internal field that a user
cannot set). Validation reserves the logical name and every replica name,
case-insensitively, checks their length, counts every replica in the port
range check, and accepts `replicas` from 1 to 64 and `scheduler` only
together with `replicas`. Entries without `replicas` are read exactly as
before; the upstream test that pins the set of app fields is unchanged.

### Routing

Each replica is an app like any other, so `/proxy/demo-2/...` is proxied by
the unchanged code: HTTP, WebSocket, uploads, downloads, cookies, starting
pages, restarts, logs, the management dashboard. Only the logical name is
new: `handle_proxy_request()` finds no app called `demo`, finds a group
instead, and answers

```
307 Temporary Redirect
Location: {base_path}/proxy/demo-2/{rest}?{query}
Cache-Control: no-store
```

The browser then loads the page from the replica's address, and Shiny's
client opens its WebSocket, fetches its assets, posts uploads and requests
downloads relative to that address. **The URL is the session's affinity**;
no cookie, header or table is needed, and no proxy code had to change. A
WebSocket handshake at the logical address is refused, as for any unknown
app.

### Scheduling

`choose_replica()` (`R/replicas.R`) considers only *available* replicas: a
running process that has finished starting, or, for on-demand groups, a
stopped replica that may start now (not in back-off after a failure, and with
a servable directory). Liveness is read from the process handle at the
moment of the choice, so a crashed replica stops receiving visitors at once,
without waiting for the health check.

- `round_robin`: the next available replica in rotation.
- `least_connections` (default): the available replica with the smallest
  load, where load = open WebSocket sessions + *pending assignments*. Ties
  go to the next replica in rotation, and to a running replica over one that
  would have to start.

**What is counted.** The connection count is the proxy's own set of open
client WebSocket sessions per app (`app_sessions`). For an ordinary Shiny
app, each browser tab holds exactly one such socket for the life of its
Shiny session, so the count equals the number of live Shiny sessions on
that process, *as seen by the proxy*. It does not count sessions that the
app has not yet initialised, disconnected tabs whose Shiny session is still
being torn down, or work: one session computing for ten seconds counts the
same as an idle one. Shiny's dev-mode autoreload socket would be counted
too.

**Pending assignments.** Between the redirect and the opening of the
page's WebSocket there is a gap (the page load, typically tens to hundreds
of milliseconds, seconds on slow networks). Visitors arriving together would
all see the same idle replica. Each recorded choice therefore adds a
timestamped pending entry to the chosen replica, which counts toward its
load until the next WebSocket opens there (`take_pending_assignment()`,
hooked into `add_ws_connection()`) or until 30 s pass. Only GET requests
record a choice: a request with a body is answered once from its headers
as well, and HEAD requests open no session.

### Landing page and management

The public landing page and `/api/apps` show one tile per group under its
logical name (status: running if any replica runs; connections: the sum).
The management dashboard and API list every replica, each with its own
restart button, PID, memory and connection count.

### Size of the change

| | Lines |
|---|---|
| `R/replicas.R` (new) | ~230 |
| `R/config.R` | +38 / -9 |
| `R/handlers.R`, `R/template_manager.R` | +7 / -2 |
| `tests/testthat/test-replicas.R` (new) | ~400 |

The optional mizu experiment adds `R/replica_telemetry.R` (~220 lines) and
touches `R/process_manager.R` (+25), `R/replicas.R` (+6),
`R/management_api.R` (+5) and `DESCRIPTION` (Suggests).

### Alternatives considered

- **Cookie-based affinity behind one URL.** The proxy would set a cookie
  naming the replica and route `/proxy/demo/...` by it. This keeps one
  public URL, but every tab of a browser shares the cookie, so all of a
  user's tabs land on one replica; cookies are already rewritten per app
  path, so the existing cookie handling would need changes; and the
  WebSocket and HTTP routing would both have to consult the cookie. More
  code, more ways to split a session, for a feature the brief does not
  require.
- **Routing by Shiny session token.** The proxy cannot learn the token
  before the page has loaded, and Shiny's own URLs (`session/<token>/...`)
  appear only for uploads and downloads.
- **A separate load balancer in front** (nginx, HAProxy, Traefik with
  sticky sessions). Works today without code, but needs a second server to
  deploy and configure, and duplicates process supervision.

The redirect needs no new routing code at all, which is what makes the
change small.

## 3. Verification

### Tests

The upstream suite ran before and after every change:

| | Passed | Failed | Skipped |
|---|---|---|---|
| Upstream `0f0a76d` | 3503 | 0 | 1 (no Quarto CLI) |
| Spike, final (`101aff5`, mizu 0.1.1 installed) | 3630 | 0 | 1 (no Quarto CLI) |

Of the 3630, 86 are in `test-replicas.R` and 41 in
`test-replica-telemetry.R`; the rest are upstream's, unchanged. The one
warning, in an upstream example test, is that the installed shiny was
built under R 4.6.2.

`tests/testthat/test-replicas.R` covers backward compatibility, expansion,
validation (including prefix-matched fields such as `replicas_note`, found
by review), round robin, least connections, pending assignments arriving
together, their expiry and consumption, unavailable replicas (dead,
starting, in back-off), the redirect (path, query, `base_path`), the
landing page and API, and one real integration test. That test runs a
server with two replicas in a background R process and drives it over HTTP
and WebSocket: affinity of a WebSocket to the replica's process, a SIGKILL
of one replica, no visitors sent to it while down, its restart and return
to rotation, and shutdown stopping every replica process.

`tests/testthat/test-replica-telemetry.R` covers the mizu experiment
(skipped without mizu): workload-aware scheduling with fake telemetry,
overdue heartbeats counting as busy, busyness measured on the replica's
clock, and a real replica process reporting heartbeats and its death over
a channel.

### Protocol-level checks

`bench/affinity-check.mjs` is a Shiny client in Node.js that speaks the
WebSocket protocol as `shiny.js` does, including the upload RPC
(`uploadInit`, POST, `uploadEnd`) and downloads. Against a running group it
opens several sessions at once through the logical address and checks, for
each one, that the page, every reactive operation, its session state, a
100 KB upload (size and MD5) and a session download are served by the one
process the redirect chose; that the sessions were spread; that a
reconnection at the replica's address returns to the same process; and that
the logical address refuses WebSockets. All 35 checks pass.

`bench/browser-check.cjs` does the same in headless Chromium through
Playwright: two visitors and a second tab, real button clicks, a file
upload through the file input and a download through the download button,
then a SIGKILL of one replica. All 17 checks pass: each page's clicks,
state, upload and download are served by its own replica process; the pages
on the killed replica show Shiny's disconnected overlay within about 40 ms;
the page on the other replica keeps working; and a new visitor is sent
elsewhere.

`bench/failure-check.mjs` is scenario E: sessions on every replica send
operations continuously, one replica's process is killed, and it records
errors on the other replicas, where new visitors go, and when the replica is
back.

### Independent review

A separate reviewer read the routing and lifecycle code without being told
the expected answers. It found no way to split a session across replicas,
and two bugs, both fixed in `19569bb`: unknown fields such as
`replicas_note` were read as `replicas` through R's partial matching of
`$`, making a previously valid configuration fail; and a POST to the
logical address was scheduled twice (once from its headers), skewing the
rotation and leaving a phantom pending entry. Its further points are listed
under limitations.

## 4. Benchmark method

**Machine.** One Windows 11 workstation (Intel i9-12900K, 8 performance
and 8 efficiency cores, 64 GB), Docker 29.6 in WSL2 (Linux 5.15, cgroup
v1). The image (`bench/docker/Dockerfile`) is R 4.6.1 with shiny 1.14.0,
httpuv 1.6.17, websocket 1.4.4 and later 1.4.8, BLAS and OpenMP limited to
one thread. It contains three servers built from git: unmodified upstream
`0f0a76d`, the spike, and plain `shiny::runApp()` ("direct", no proxy).

**Isolation.** The server container is pinned with `--cpuset-cpus` to 1 or
2 vCPUs; that confines the proxy and every app process. The load generator
runs in its own container on four other vCPUs. WSL2 vCPUs are scheduled by
Windows onto physical cores, so "1 vCPU" here is closer to a cloud vCPU
than to a dedicated core. To detect drift, every run first times a fixed
CPU loop in the server container (`docker/calibrate.R`): 8,511–9,132
iterations per ms over all 336 runs (±3.5%), stored with each run.
Configurations and runs within a configuration are shuffled.

**Load.** `bench/loadgen.mjs` is a Shiny client at protocol level (no
browser): each virtual user loads the page through the logical address,
follows the redirect, opens the WebSocket, sends Shiny's init message,
then sends input changes and waits for the output that answers each one.
Every answer names its process and session, so latency is measured per
operation and placement is known. Think times are exponential (light
users: mean 0.5 s). Users arrive over 2 s; a run lasts 32 s; operations
count from the end of the 8 s warm-up or 2 s after the last session opened,
whichever is later. Two or three repetitions per cell; the tables show the
quantiles of all repetitions pooled.

**Scenarios** (benchmark app `bench/app/app.R`):

| | Users | What the others do |
|---|---|---|
| A | 80% light (cheap reactive), 20% stateful (session counter) | — |
| B | 80% light | 20% heavy: 0.5 s of CPU, mean 2 s think time |
| C | 80% light | 20% blocking I/O: `Sys.sleep(0.5)`, mean 1 s think time |
| D | all saturate: 0.25 s of CPU, mean 0.25 s think time | — |

Configurations: direct Shiny, unmodified upstream, the spike with one
process ("spike, 1"), and the spike with 2, 4 or 8 replicas (r2, r4, r8,
least connections). 336 runs: B with every configuration at 5, 10, 20, 40
and 80 users (3 repetitions); A, C and D at 5, 20 and 80 users (2
repetitions; A without r2, C and D without direct and spike, 1, which
equalled upstream in B). The 4 vCPU phase and replica counts beyond 8 were not run.

**Metrics.** Per operation: p50/p95/p99, the share over 100 and 250 ms,
throughput. Per run: per-process CPU (from `/proc`, before, during and
after), RSS, the container's cgroup memory, session start-up time, the
distribution of sessions over replicas. Everything is in
`bench/results/analysis/` (`runs.csv` per run, `ops_summary.csv` and
`runs_summary.csv` per cell, plots in `plots/`), computed by
`bench/analyze.R` from the raw files in `bench/results/matrix/raw/`.
`bench/run-all.sh` reproduces the matrix.

## 5. Results

### No overhead from the change itself

With one process, the spike is indistinguishable from upstream in every
scenario (B, 1 vCPU, 20 users: light p95 1.0 s vs. 1.3 s, CPU jobs 755 vs.
855 ms; differences of this size go either way between cells). Upstream's
proxy costs about 2.5 ms of CPU per relayed operation and adds 2–8 ms of
median latency compared with direct Shiny; that is the existing proxy, and
replicas do not change it.

### Scenario B: heavy computations block other users (H1, H2)

Share of light operations (one cheap reactive calculation) slower than
250 ms:

| Users | 1 vCPU: upstream | r2 | r4 | r8 | 2 vCPUs: upstream | r2 | r4 | r8 |
|---|---|---|---|---|---|---|---|---|
| 5 | 9% | 3% | 1% | 0% | 11% | 4% | 1% | 0% |
| 10 | 23% | 10% | 5% | 1% | 18% | 9% | 3% | 1% |
| 20 | 56% | 28% | 11% | 3% | 44% | 15% | 9% | 3% |
| 40 | 99% | 84% | 32% | 10% | 95% | 54% | 25% | 12% |
| 80 | 100% | 100% | 93% | 25% | 100% | 99% | 80% | 26% |

Median and p95 of light operations, ms:

| Users | 1 vCPU: upstream | r8 | 2 vCPUs: upstream | r2 | r8 |
|---|---|---|---|---|---|
| 10 | 13 / 558 | 7 / 54 | 6 / 475 | 7 / 407 | 6 / 53 |
| 20 | 352 / 1,300 | 7 / 58 | 149 / 876 | 12 / 458 | 7 / 61 |
| 40 | 2,600 / 3,600 | 7 / 2,600 | 2,000 / 2,800 | 329 / 1,300 | 8 / 746 |
| 80 | 7,500 / 8,900 | 50 / 8,800 | 6,300 / 7,700 | 2,300 / 3,800 | 12 / 3,100 |

In one process, a light operation waits for every heavy computation queued
before it. In separate processes, the operating system's scheduler
interleaves them, so the light operation gets a time slice within
milliseconds even on one vCPU. The p95 of r8 at 40 and 80 users is set by
the users who share a replica with a heavy user (with 8 replicas and 8–16
heavy users, two to four land on the busiest replica).

The heavy computations themselves (median, jobs per second):

| Users | 1 vCPU: upstream | r8 | 2 vCPUs: upstream | r2 | r8 |
|---|---|---|---|---|---|
| 20 | 855 ms, 1.33 | 1.1 s, 1.12 | 578 ms, 1.25 | 526 ms, 1.38 | 549 ms, 1.46 |
| 40 | 2.9 s, 1.64 | 3.2 s, 1.34 | 2.4 s, 1.96 | 885 ms, 2.83 | 901 ms, 2.46 |
| 80 | 7.6 s, 1.67 | 8.6 s, 1.38 | 6.5 s, 1.80 | 2.8 s, 3.37 | 3.0 s, 2.71 |

On 1 vCPU, the CPU is shared rather than created: light users get their
answers, and heavy users pay for it: with r8, computations take 10–30%
longer and about 17% fewer complete at 20–80 users. On 2 vCPUs, one process can use
only one core (0.99 cores at saturation), while r2 uses 1.75 and completes
44–87% more jobs in less than half the time.

Plots: `B_fast_over250_vs_users.png`, `B_fast_p95_vs_users.png`,
`B_cpu_p50_vs_users.png`, `B_throughput_vs_users.png`,
`vcpu_comparison.png`.

### Scenario C: blocking I/O (H3)

20% of users call `Sys.sleep(0.5)`, which stands for a slow database or
web API called synchronously.

| Users | | upstream | r2 | r4 | r8 |
|---|---|---|---|---|---|
| 20 | light, median / p95 (1 vCPU) | 958 / 1,590 ms | 19 / 937 | 11 / 452 | 8 / 153 |
| 20 | blocking calls per second (1 vCPU) | 1.7 | 2.2 | 2.4 | 2.5 |
| 80 | light, median / p95 (1 vCPU) | 7.7 / 8.5 s | 3.3 / 4.3 s | 957 / 2,011 ms | 122 / 972 ms |
| 80 | light, median / p95 (2 vCPUs) | 7.2 / 7.8 s | 2.9 / 3.9 s | 582 / 1,811 ms | 31 / 855 ms |
| 80 | blocking calls per second (1 vCPU) | 1.7 | 3.5 | 6.3 | 8.1 |
| 80 | all operations per second (1 vCPU) | 9.7 | 21 | 49 | 88 |

One process can wait for only one call at a time, so upstream completes at
most two blocking calls per second however many users wait; replicas wait
in parallel. The CPU is mostly idle (0.3–0.9 cores), so 1 and 2 vCPUs give
nearly the same result. This is the largest effect measured. With 16
blocking users on 8 replicas, r8 at 80 users still leaves 37% of light
operations over 250 ms: more replicas, or asynchronous calls inside the
app, would be needed there.

Plots: `C_fast_p95_vs_users.png`, `C_io_throughput_vs_users.png`.

### Scenario D: CPU saturation, where replicas cannot help

Every user runs 0.25 s computations with short pauses; the demand is 2.5 to
40 cores.

| | 1 vCPU: upstream | r2 | r4 | r8 | 2 vCPUs: upstream | r2 | r4 | r8 |
|---|---|---|---|---|---|---|---|---|
| 5 users: jobs/s | 3.71 | 3.54 | 3.52 | 3.54 | 3.90 | 6.85 | 6.94 | 6.81 |
| 5 users: median | 1.1 s | 1.1 s | 1.0 s | 1.2 s | 1.0 s | 471 ms | 450 ms | 482 ms |
| 20 users: jobs/s | 3.71 | 3.66 | 3.66 | 3.63 | 4.08 | 7.27 | 7.10 | 6.88 |
| 20 users: median | 5.3 s | 5.4 s | 5.4 s | 4.8 s | 4.8 s | 2.5 s | 2.6 s | 2.5 s |

On 1 vCPU every configuration completes the same 3.6–3.7 jobs per second
(the CPU's capacity) with the same latency: replicas redistribute waiting,
they do not remove it. On 2 vCPUs, replicas use the second core: 1.75–1.8×
the throughput at half the latency, already with two replicas; four and
eight add nothing and r8 has a longer tail (p95 3.5 s vs. 2.7 s at 20
users). At 80 users, session start-up took longer than the run, so the
throughput of that cell is not reliable and is left out here (it is in the
CSV, marked `late_sessions`).

Plot: `D_cpu_throughput_vs_users.png`.

### Scenario A: light load

On 2 vCPUs, direct Shiny, upstream, the spike and r4/r8 are within a few
milliseconds of each other at 5, 20 and 80 users (80 users: p95 50–64 ms,
120 operations/s). On 1 vCPU, 80 users saturate the vCPU:

| 1 vCPU, 80 users | direct | upstream | spike, 1 | r4 | r8 |
|---|---|---|---|---|---|
| Operations/s | 136 | 98 | 97 | 109 | 128 |
| Light, median / p95 | 60 / 150 ms | 301 / 392 ms | 301 / 446 ms | 197 / 416 ms | 84 / 244 ms |
| CPU, proxy / app processes (cores) | – / 0.88 | 0.23 / 0.69 | 0.23 / 0.71 | 0.30 / 0.58 | 0.32 / 0.57 |

Here the proxy's CPU becomes visible: upstream completes 28% fewer
operations than direct Shiny. Unexpectedly, r8 recovers most of it: its
app processes need 4.4 ms of CPU per operation against 7.1 ms for one
process holding all 80 sessions (similar at 20 users: 5.5 vs. 8.1 ms).
**Hypothesis, not tested:** Shiny's work per operation grows with the
number of sessions in the process (each flush cycle visits every session),
so splitting sessions makes each operation cheaper. A profile of one
process at 10 and 80 sessions would settle it.

### Memory (H4)

| | upstream | r2 | r4 | r8 |
|---|---|---|---|---|
| Idle, whole container (cgroup) | 240 MB | 349 MB | 570 MB | 1,010–1,150 MB |
| B, 20 users, cgroup RSS | 330–360 MB | 500–540 MB | 810–820 MB | 1,330–1,360 MB |

Each replica of the benchmark app costs about 110–130 MB idle and 140–150 MB
under load: an R process with shiny loaded. An app holding data in memory
adds its data per replica; the shared-data follow-up measures how much of
that can be saved.

### Session start-up under starvation: a negative result (H4)

p95 / maximum time from requesting the page to the first message on the
WebSocket, scenario B:

| | upstream | r2 | r4 | r8 |
|---|---|---|---|---|
| 1 vCPU, 40 users | 4.4 / 4.4 s | 5.9 / 6.0 s | 7.3 / 7.5 s | 5.1 / 7.5 s |
| 1 vCPU, 80 users | 8.7 / 9.5 s | 10.6 / 10.7 s | 16.3 / 36.4 s | 34.4 / 34.6 s |
| 2 vCPUs, 80 users | 10.4 / 10.7 s | 4.9 / 5.1 s | 5.3 / 5.5 s | 6.8 / 12.3 s |

On 2 vCPUs replicas start sessions faster, but on 1 vCPU with 80 users
start-up with r4 and r8 is up to four times slower than upstream. The
cause is upstream's existing WebSocket relay: the proxy opens its backend
WebSocket with the `websocket` package, whose handshake timeout is fixed at
5 s. When 8 CPU-starved replicas cannot answer a handshake within 5 s, the
proxy gives up and the client retries; one reproduced run retried 20
times. With fewer processes competing for the vCPU, handshakes are
answered sooner. This cannot be fixed inside
tinyshinyserver without a change to `websocket` (a configurable timeout)
or to the relay; until then, fewer replicas per vCPU under heavy CPU load
avoid it. In scenario A at 80 users on 1 vCPU the same effect is milder
(p95 6.1 s upstream, 7.5 s r8).

### Fault isolation (H5)

The protocol and browser checks (section 3) kill one replica with SIGKILL
while sessions on every replica are active: the sessions on other replicas
continue without error, the victim's pages show Shiny's disconnected
overlay within about 40 ms, no new visitor is sent to the dead replica, and
it rejoins the rotation after `restart_delay`. This was verified as a
check, not measured under load at scale.

### Hypotheses

| | Verdict | Evidence |
|---|---|---|
| H1: several processes on one vCPU reduce tail latency of light interactions under heterogeneous load | **Confirmed** | B and C on 1 vCPU: light operations over 250 ms fall from 56% to 3% (B, 20 users) and from 92% to 4% (C, 20 users) with 8 replicas. The cost: heavy computations 10–25% slower (B). |
| H2: several processes on several vCPUs raise CPU-bound throughput | **Confirmed** | D on 2 vCPUs: 1.75–1.8× jobs per second; B on 2 vCPUs: 44–87% more heavy jobs at 40–80 users. Needs only as many replicas as vCPUs. |
| H3: several processes raise throughput of synchronous blocking I/O, also on one vCPU | **Confirmed, strongest effect** | C: blocking calls per second 1.7 → 8.1, all operations 9.7 → 88 per second (1 vCPU, 80 users, r8). |
| H4: the best replica count can exceed the vCPU count for heterogeneous or I/O-heavy load; too many replicas hurt | **Confirmed, with limits** | B and C improve up to 8 replicas on 1 vCPU. Harm appears as memory (≈140 MB per replica), as session start-ups up to 4× slower under CPU starvation (handshake timeout), and as a longer tail in D. No throughput loss beyond the CPU's capacity was measured. |
| H5: a failed process does not disrupt sessions on other replicas | **Confirmed by checks** | Section 3; not measured as a benchmark scenario. |

### Limitations of the measurements

- One workstation, WSL2 vCPUs on a hybrid CPU; absolute numbers will differ
  on cloud vCPUs, ratios should be similar. No 4 vCPU runs.
- A synthetic app whose operations are pure CPU loops or `Sys.sleep()`;
  real apps mix both and allocate memory.
- A protocol-level client, not browsers; it does not load static assets
  after the first page, so browser start-up is somewhat heavier.
- Two or three repetitions per cell; the bars in the plots show the range.
  Cells where sessions were still opening near the end are marked
  `late_sessions` and their throughput excluded from conclusions.
- Session churn was not part of the matrix: every user keeps one session
  for the whole run, so placement is decided once (least connections with
  pending assignments distributes evenly: the busiest of 8 replicas held
  12.5–20% of sessions).

## Known limitations and open problems

**Of the design**

- **The URL pins the session, so there is no failover.** Bookmarks, shared
  links, reloads and Shiny reconnections stay on `/proxy/demo-N/`. While
  that replica is down or restarting, its visitors see the starting page
  although other replicas are free. Visiting the logical address again
  chooses anew. A reload after a configuration change that lowers
  `replicas` answers HTTP 404 for the removed replica's address.
- **Replica addresses are public and can be chosen by hand**, bypassing the
  scheduler. That grants no access that the logical address does not, but
  a client can concentrate load on one replica. Path-based access rules in
  a reverse proxy in front must cover `/proxy/demo-*/` too.
- **App cookies are per replica.** Cookie paths are rewritten to the
  replica's address, so a preference or login cookie set by one replica is
  not sent to another on the next visit.
- **Quarto and prerendered R Markdown documents cannot have replicas**:
  the existing check against two apps rendering one document rejects the
  configuration, with a message naming `demo-1` and `demo-2`.
- **Every replica is a full R process** with its own copy of the app's data
  and packages; memory grows linearly (see the results).
- **Session counts are a proxy for load, not a measure of it.** One session
  in a ten-second computation counts as much as an idle one. Pending
  entries drift: a monitor or link preview that GETs the logical address
  adds one for 30 s, and any WebSocket opening on a replica (a reload at
  its own address, a reconnect) consumes one.

- **Slow session start-up when replicas are starved of CPU.** The
  existing WebSocket relay opens its backend connection with the
  `websocket` package, whose handshake timeout is fixed at 5 s and cannot
  be set from R. Replicas that cannot answer within 5 s make the proxy
  give up and the browser retry (section 5). Fixing it needs a timeout
  option in `websocket` or a different relay.

**Of the implementation**

- On-demand groups: least connections may start a stopped replica for a
  second visitor rather than share a warm one, by design (to spread load);
  and the redirect does not cancel the chosen replica's pending idle check,
  so a replica can in rare cases stop between the redirect and the
  browser's next request.
- No configuration of the pending window (30 s) or the logging throttle.
- Replica state (`replica_state`) is not cleared on reload; entries for
  removed replicas are harmless and expire.

**Found in passing, not caused by this change**

- **Our Node.js client did not always notice a closed session.** When an
  app process is SIGKILLed, the server closes every client WebSocket of that
  app at once (its log shows each close within milliseconds). In Node's
  built-in `WebSocket` (undici), `onclose` then fired for only about half of
  the sessions, and the others waited until our timeout; the same happens
  with unmodified upstream `0f0a76d` in the Linux container. Chromium does
  not have the problem: `bench/browser-check.cjs` sees Shiny's disconnected
  overlay in every page of the killed replica within about 40 ms. It is
  therefore an artifact of that client's handling of the close handshake,
  not a user-visible bug, and the failure scenario's numbers for the
  victim's own sessions use the server's log rather than the client.

## Follow-up: shared data with mori and DuckDB

Run because scenario B showed that replicas help: a bounded
experiment on sharing an app's data between replicas next, although the
original brief excluded shared memory. Each replica is a full R process
with its own copy of everything the app loads, so memory, not CPU, may
limit how many replicas a small machine can run.

Preliminary scenario B measurements (1 vCPU) put the base cost at about
150 MB of private memory per replica for an app with essentially no data:
container memory was 1.31 GB with 8 replicas against 0.34 GB upstream, and
summed process RSS (1.49 GB) was close to it, so little is shared today.
That base is R's heap and the loaded packages, which no data-sharing
technique removes; only starting replicas by forking one pre-loaded
process could share it copy-on-write, with known catches (R's garbage
collector un-shares pages as it marks objects; no fork on Windows; callr
does not fork). What can be shared is the app's data, compared in three
arms:

- **Per replica in memory** (today): every replica loads its own copy.
- **mori**: one copy of the R objects in shared memory, mapped by every
  replica without copying.
- **DuckDB, read-only**: the data in a DuckDB (or Parquet) file that every
  replica opens with `read_only = TRUE`, querying only what it needs; the
  operating system's page cache holds the file's hot pages once for all
  processes. Each connection needs explicit limits, `threads` (DuckDB is
  multithreaded by default, which would oversubscribe a 1-vCPU machine
  several times over with eight replicas) and `memory_limit` (by default
  80% of RAM, per process, with a buffer pool that is not shared). DuckDB
  allows many read-only processes or one writer, so it suits apps that
  read; apps that write need one writer, SQLite in WAL mode or a database
  server.

Scope:

- Give the benchmark app a large dataset (a few hundred MB) and
  operations that filter and aggregate it, in each of the three arms.
- Measure, for 1, 2, 4 and 8 replicas on 1 and 2 vCPUs: container memory
  (cgroup, shared pages once) and its peak, replica startup time, and the
  latency of the data operations under scenario B's load.
- Read mori's API and source, as was done for mizu: which process should
  own the shared region when replicas restart independently, what happens
  to replicas when the owner dies, and whether apps must change how they
  load data. For DuckDB, record the settings each replica needs.

### Results

Setup: `bench/app-data/`, a data frame of 10 million rows (an integer
category 1–100 and three numeric columns; 229 MB in R, 178 MB as a DuckDB
file). Half of 20 users run queries (filter one random category, count it
and aggregate two columns), the other half cheap operations; mean think
time 0.5 s. One process ("spike, 1") or 2, 4 or 8 replicas, on 1 and 2
vCPUs, two repetitions each (48 runs, no errors). For mori, a separate owner
process (`share-data.R`) shares the data and stays alive, since a region can
be mapped only while its owner holds it; in a production version the
server process would be the owner. DuckDB connections use `threads = 1`
and `memory_limit = 128MB`. All arms get 1 GB of `/dev/shm`; Docker's
default 64 MB cannot hold the shared region. Results:
`bench/results/followup-analysis/`, raw data in `bench/results/followup/`.

Container memory (cgroup, every page counted once):

| | 1 process | r2 | r4 | r8 | per added replica |
|---|---|---|---|---|---|
| Idle, memory (own copy) | 451 MB | 773 MB | 1,419 MB | 2,721 MB | ≈ 325 MB |
| Idle, mori | 497 MB | 593 MB | 786 MB | 1,177 MB | ≈ 97 MB |
| Idle, DuckDB | 290 MB | 402 MB | 714 MB | 1,260 MB | ≈ 139 MB |
| Under load, memory | 566 MB | 988 MB | 1,721 MB | 3,303 MB | |
| Under load, mori | 777 MB | 1,203 MB | 1,845 MB | 3,331 MB | |
| Under load, DuckDB | 490 MB | 719 MB | 1,156 MB | 2,128 MB | |

(1 vCPU; 2 vCPUs within 6%.)

Query latency, median / p95, and all operations per second:

| | 1 process | r2 | r4 | r8 |
|---|---|---|---|---|
| 1 vCPU, memory | 92 / 181 ms, 33 | 105 / 290 ms, 33 | 111 / 278 ms, 34 | 143 / 325 ms, 33 |
| 1 vCPU, mori | 103 / 244 ms, 34 | 111 / 275 ms, 33 | 135 / 373 ms, 33 | 170 / 448 ms, 33 |
| 1 vCPU, DuckDB | 637 / 876 ms, 18 | 674 / 1,382 ms, 20 | 692 / 1,185 ms, 24 | 633 / 1,223 ms, 24 |
| 2 vCPUs, memory | 35 / 83 ms, 37 | 38 / 79 ms, 37 | 38 / 77 ms, 37 | 38 / 76 ms, 38 |
| 2 vCPUs, mori | 41 / 100 ms, 37 | 42 / 87 ms, 36 | 45 / 94 ms, 37 | 44 / 98 ms, 36 |
| 2 vCPUs, DuckDB | 440 / 813 ms, 21 | 166 / 393 ms, 31 | 157 / 307 ms, 34 | 155 / 354 ms, 33 |

Findings:

- **mori saves memory only while the data is not touched.** Idle, a mori
  replica costs less than a third of a replica with its own copy (97 vs. 325 MB),
  as expected. Under the query load, the saving disappears: with 8
  replicas, 3.33 GB with mori against 3.30 GB with private copies. The
  cause, measured in one process: after `data$category == 5`, the process's
  private (anonymous) memory grew by about twice the column's size (the
  result and a copy of the column), and after `data$x[rows]` and
  `data$y[rows]` by the size of those columns; the copies stayed after
  `gc()`, while `sum(data$x)` read the shared pages without copying. mori's
  source explains it: when R asks a mori vector for a *writable* data
  pointer, mori copies the vector into private memory and keeps the copy
  for the life of the object (`mori_vec_Dataptr()` in `src/altrep.c`,
  "COW: materialize"). Which base R functions ask for a writable pointer
  on read-only use is an R internals question; in R 4.6.1, comparison and
  logical subsetting do, and those are what typical filtering code uses.
  After a few queries, each replica therefore holds a private copy of
  every column it filtered on or extracted.
- **DuckDB uses the least memory under load** (2.13 GB with 8 replicas,
  36% less than private copies), because each process's buffer pool is
  capped and the file's pages sit once in the page cache. But its queries
  are slower and use more CPU: in one process without load, 82 ms per
  query at a 128 MB limit and 56 ms at 1 GB, against 23 ms for R's
  vectorised filter on the in-memory copy (the category is unsorted, so
  every query scans the column; sorting or partitioning by category would
  change this). On 1 vCPU that CPU cost lowers total throughput by a third to a half. Several
  replicas help DuckDB on 2 vCPUs (median 440 → 155 ms), since one
  `threads = 1` connection cannot use the second core.
- **With private copies, memory, not CPU, limits replicas**: 325 MB each
  for a 229 MB dataset. For apps with large read-only data, the
  practical options today are a database file with a bounded buffer pool
  (DuckDB, SQLite) or code that keeps mori's data on read-only paths.
  mori's README documents the copy on modification, but not that ordinary
  read operations can trigger it; that is worth raising with its author,
  with this reproduction, before relying on it.
- Not measured: replica start-up time per data mode (the run's ready time
  measures the first replica), and how mori behaves when the owner process
  dies while replicas are mapped.

## Follow-up: replicas combined with async offloading

Run on the same condition as the shared-data follow-up: test replicas together with in-session
async offloading through `shiny::ExtendedTask` and mirai, although the
original brief excluded mirai.

The two address different blocking. Replicas keep other users'
computations from blocking a session, without app changes; async
offloading keeps a session's own long computation from freezing it, and
everyone in the same process, but needs the app to wrap that code. A
well-built app on a replicated server could stay responsive both ways.

Scope:

- A variant of the benchmark app that runs the CPU job in an
  `ExtendedTask` backed by mirai daemons.
- Scenario B on 1 and 2 vCPUs, for: one process synchronous (upstream),
  replicas synchronous, one process with async, and replicas with async.
  Measure the latency of lightweight operations, including those of the
  user whose job is running, the jobs' own latency, throughput, and memory.
- Questions to answer:
  - async creates no CPU: on 1 vCPU the jobs compete with everything else
    for the same core, so how much does responsiveness gain, and what does
    job throughput lose?
  - process count multiplies (replicas times daemons, each with its own
    copy of the app's data), which ties this to the mori follow-up;
  - whether each replica should run its own daemons or all replicas
    should share one pool that the server manages and bounds.

### Results

Setup: `bench/app-async/app.R` is the benchmark app with its CPU job in an
`ExtendedTask` that runs it with `mirai::mirai()` on local mirai daemons;
everything else is unchanged. Scenario B (20% of users run 0.5 s
computations) at 10, 20 and 40 users, 1 and 2 vCPUs, two repetitions (48
runs, no errors), four arms with comparable process counts:

- **sync, 1 process**: the ordinary app, as upstream runs it today;
- **async, 1 process**: the async app with 4 daemons;
- **sync, 4 replicas**;
- **async, 4 replicas**, each with 1 daemon (8 R processes in all).

Light operations, median / p95 and the share over 250 ms, at 40 users:

| | sync, 1 process | async, 1 process | sync, 4 replicas | async, 4 replicas |
|---|---|---|---|---|
| 1 vCPU | 2.2 / 2.9 s, 100% | 349 / 676 ms, 70% | 8 ms / 2.5 s, 25% | 13 / 110 ms, 0.3% |
| 2 vCPUs | 1.9 / 2.7 s, 95% | 26 / 132 ms, 0% | 10 / 851 ms, 21% | 8 / 61 ms, 0% |

Heavy computations (median, jobs per second), all operations per second,
and container memory (cgroup RSS), 40 users:

| | sync, 1 process | async, 1 process | sync, 4 replicas | async, 4 replicas |
|---|---|---|---|---|
| 1 vCPU: heavy | 2.4 s, 1.65 | 4.6 s, 1.11 | 2.7 s, 1.43 | 6.2 s, 0.98 |
| 1 vCPU: all ops/s | 14 | 38 | 32 | 60 |
| 2 vCPUs: heavy | 2.2 s, 1.81 | 1.4 s, 2.48 | 795 ms, 2.56 | 1.1 s, 2.65 |
| 2 vCPUs: all ops/s | 16 | 61 | 51 | 64 |
| Memory | 310–320 MB | 740–770 MB | 760 MB | 1,140–1,170 MB |

Findings:

- **The combination gives the best responsiveness by far**, on 1 vCPU as
  well: 0.3% of light operations over 250 ms, against 25% with replicas
  alone and 70% with async alone. The two remove different waiting:
  replicas keep other users' work from blocking a session without app
  changes; async keeps the computation out of the process that serves
  sessions, so the users who share a replica with a heavy user are no
  longer blocked either (the p95 of replicas alone, 2.5 s, comes from
  them).
- **Async alone on 1 vCPU leaves every user moderately slow.** The single
  session process competes for the one vCPU with up to 4 busy daemons and
  can get as little as a fifth of it while all 32 light users wait on it: median
  349 ms. Replicas alone have the opposite shape: most users at 8 ms, the
  few behind a heavy user at seconds.
- **Neither creates CPU.** On 1 vCPU, light users who no longer wait send
  more operations (60 instead of 14 per second in total, since every user
  waits for an answer before the next request), and that CPU is taken
  from the heavy computations: 6.2 s instead of 2.4 s, 40% fewer per
  second. On 2 vCPUs, every arm but the single synchronous process uses
  the second core: 2.5–2.65 heavy jobs per second against 1.8.
- **Each daemon is another R process** (about 100–110 MB here, plus any data
  the job needs), so replicas × daemons multiplies memory, and with it
  the data question of the previous follow-up. Whether each replica
  should run its own daemons, or all replicas share one pool that the
  server bounds, was not tested; with per-replica daemons, a busy replica
  cannot borrow an idle replica's daemon.
- Not measured: the responsiveness of the heavy user's own session while
  its job runs (the load generator's heavy users send only heavy
  operations). With `ExtendedTask` that session stays interactive; with
  sync code it is frozen whatever the server does.

## Effort for a production-quality contribution

The core change is small because it reuses everything; most of the work
would be in the edges that upstream's standard of care demands (its NEWS
for 0.3.0 shows how thoroughly each behaviour is specified, documented and
tested). Rough estimates for one developer familiar with the code base:

| Work | Estimate |
|---|---|
| Agree the configuration API with the maintainer (`replicas` on an app vs. a group entry; scheduler names; whether `least_connections` is the only one) | discussion |
| Harden routing: failover of a replica's own address to the group when the replica is down (redirect back to the logical address instead of the starting page); answer the removed replicas' addresses after a reload | 2–3 days |
| On-demand groups: cancel the idle check of the chosen replica on redirect; decide whether a cold replica should ever be preferred to a warm one | 1–2 days |
| Make pending-assignment accounting robust (count only page loads that can open a session; configurable window) | 1 day |
| Management dashboard: show groups with their replicas; a "restart group" action (rolling restart) | 2–3 days |
| Clear error for Quarto/prerendered documents with replicas; README and `help("config-format")`; NEWS | 1–2 days |
| Session start-up under CPU starvation: propose a handshake-timeout option to `websocket`, or document a replicas-per-vCPU guideline | 1–2 days, plus upstream's time |
| Tests to upstream's level (reload with changed replica counts, base_path, Windows and macOS, browser tests in `tests/browser/`) | 3–4 days |
| **Total, without telemetry** | **11–17 working days, about 3 weeks** |

The mizu telemetry is not part of this estimate. Its cost is mostly
outside tinyshinyserver: it needs a supported mizu API for a peer that
mizu does not spawn and for non-blocking channel creation (see the mizu
evaluation), and a decision on whether its measured benefit justifies a
second inter-process mechanism next to HTTP and WebSockets.

## mizu evaluation

mizu 0.1.1 (CRAN; the 0.1.0 announcement was 2026-11-05) provides
lock-free single-producer, single-consumer shared-memory channels between R
processes, with event-driven receive through `later`, zero-copy transfer of
large vectors, and peer-death detection through a kernel-released lock.
The question was not whether mizu is fast (its own benchmarks show that)
but whether it makes this server simpler, more responsive or cheaper to run.

### What the installed package actually does

Every assumption was checked against the 0.1.1 source
(`R/channel.R`, `R/promise.R`, `src/notify_r.c`, `src/vendor/libmizu/`):

| API | Finding |
|---|---|
| `mizu_channel(expr, launcher=)` | Creates the region, **spawns the peer itself** through `launcher(token)`, then **blocks** in `mizu_channel_ready_wait()` until the peer attaches (default `startup_timeout = 30`). The peer runs `mizu:::peer_main(token)`, which evaluates the host's quoted `expr` with `ch` bound and then calls `quit()`. |
| `mizu_send()` | Never blocks: a full ring returns the `mizu_full` sentinel. |
| `mizu_recv()` | Blocking with timeout; spins up to an adaptive 1–64 µs (16 µs initially) before parking. |
| `mizu_recv_handler()`, `mizu_recv_async()` | A listener thread signals `later`'s `execLaterNative2`; the drain runs on the main thread, bounded to 2048 messages or ~1 ms per turn. No spinning. Close and peer death are delivered to the handler as classed conditions. Mutually exclusive per channel. |
| `mizu_alive()` | Reads the peer's liveness lock (~1 µs). |
| `mizu_close(ch, timeout)` | Waits up to `timeout` for the peer to confirm; instant if the peer is dead. On timeout, warns and leaves release to the finalizer. |
| `mizu_prune()` | Removes regions orphaned when *every* participant died at once (`/dev/shm` on Linux); a no-op on Windows, where orphans cannot exist. |

Two side effects matter for a server:

- **Shared-memory sizing.** The defaults (`capacity = 16384`,
  `slot_size = 256`, `arena_size = 4 MB` per direction) reserve about
  16 MB per channel. Docker gives a container 64 MB of `/dev/shm` by
  default, so the defaults would fail at about four replicas. The telemetry
  channels here use 64 slots of 128 bytes and no arena: about 16 KB each.
- **The peer's allocator is retuned.** `peer_main()` calls
  `child_prologue()`, which on glibc sets `M_MMAP_THRESHOLD` to 32 MB and
  `M_TRIM_THRESHOLD` to 128 MB in the peer, the Shiny app process here,
  unless `GLIBC_TUNABLES` mentions `glibc.malloc`. Each such process could
  then keep up to 128 MB of freed heap instead of returning it to the
  system. The prototype starts telemetry replicas with
  `GLIBC_TUNABLES=glibc.malloc.check=0` (the default value, which only
  serves to switch mizu's tuning off) unless the variable is already set.
- **The peer attaches mizu to the search path** (`attachNamespace("mizu")`)
  and loads `later` through it, inside the app's process.

### Integration with the existing process lifecycle

The goal was one supervisor, not two. The prototype keeps callr's
`r_bg()` as the launcher and owner of every process: logs, environment,
working directory, profile handling, `supervise = TRUE`, `kill_tree()` and
the health check are unchanged.

- `start_app()` creates the channel's region first (mizu's internal
  `mizu_channel_create`, `mizu_channel_suffix`) and passes the join token
  to the callr function as one more argument.
- The callr function sets up the app's environment, library paths and
  profile exactly as before. Only then, given a token, does it call
  `mizu:::peer_main(token)`, so that mizu and `later` load from the app's
  own library (a renv app that pins other versions of `later`, `Rcpp` or
  `rlang` would otherwise get the server's; a first version attached before
  the profile ran, which review caught). The staged expression starts the
  heartbeat and a command handler, then runs the app through the same code
  as without telemetry. When the app returns or fails, `peer_main()` closes
  the channel and quits with the app's status (0, or 1 on error), so the
  health check still tells a crash from a clean exit. A process that cannot
  attach, for example because the server gave up waiting or the app's
  library lacks mizu, logs this and runs the app without telemetry.
- The server never calls the blocking `mizu_channel()`. It polls
  `mizu_channel_ready_wait(ch, 0)` from a `later` callback every 20 ms
  until the peer attaches (typically 0.1–0.3 s, the child's R startup),
  then installs `mizu_recv_handler()`. With `mizu_channel()` itself, each
  replica start or restart would freeze every session of every app for the
  child's R startup.
- A terminal condition on the channel (`mizu_peer_gone` for a killed
  process, `mizu_closed` or a remote error when the app ended) runs the
  existing health check at once, which closes the replica's sessions and
  schedules its restart as usual. The scheduler does not rely on it: it
  reads process liveness at each choice anyway.
- Every telemetry callback on the server runs inside its own error
  handler. The server's main loop treats an uncaught error as fatal and
  shuts down, and the app's own code shares the process that holds the
  channel: a first version could be crashed by an app that sent a
  malformed message on it. Messages that are not a heartbeat are ignored.
- At its first channel, the server calls `mizu_prune()` to remove regions
  that a previous server left in `/dev/shm` when it was killed together
  with all its replicas.

This works with callr and without a second supervisor, but only through
mizu internals (`:::`): `mizu_channel_create`, `mizu_channel_suffix`,
`mizu_channel_ready_wait`, `mizu_channel_destroy` and `peer_main`. A
supported integration would need from mizu either a non-blocking
`mizu_channel()` (returning before the peer attaches, with readiness as a
promise or an event) or an exported way for a process that mizu did not
spawn to attach as a peer and return, rather than evaluate an expression
and quit. These are the first open questions for the mizu author.

**Three properties stay distinct.** *Process liveness* comes from callr's
handle and, with telemetry, from the channel's liveness lock. *Application
readiness* still comes from the existing HTTP probe of the app's port
(`check_app_ready()`): attaching to the channel happens before the app
listens. *Event-loop responsiveness* is what only the heartbeat measures:
how late the replica's 100 ms timer fires, and whether heartbeats arrive at
all.

### Telemetry and the workload-aware scheduler

Each replica sends six numbers every 100 ms over its channel: sequence
number, event-loop lag, CPU seconds used, open Shiny sessions (from Shiny's
internal `appsByToken`, so the app needs no change), its wall clock (for
the delivery delay) and its elapsed time.
A full ring drops the heartbeat. A busy replica cannot send at all, so
**missing heartbeats are the signal**: a replica whose last heartbeat is
older than 300 ms counts as fully busy, never as idle. Its recent busy
fraction is a moving average, with a 2 s time constant, of the larger of
its CPU share and its lag share. Both are measured on the replica's own
elapsed time, so that heartbeats that queue up while the server is busy do
not distort them, and each sample is weighted by the time it covers, so
that a 3 s computation, reported by a single late heartbeat, counts for
3 s (a first version weighted per heartbeat; review caught it). A running
replica without telemetry counts as 0.5 busy, and a stopped one that a
visitor would have to start counts as fully busy.

`workload_aware` = `least_connections` + 2 × busy fraction. It is
deliberately simple: one more term in the existing load, not a model.
Without telemetry it chooses exactly as `least_connections`.

A structural limit applies to any scheduler here: **only a session's first
request is placed**. After the redirect, the session belongs to its replica
for life, however busy that replica becomes. Better placement can only
help new sessions, so its effect depends on how often sessions start. The
control-plane benchmark therefore uses session churn: each simulated user
leaves after five operations and a new visitor arrives.

### Commands

The peer also installs a handler for commands from the server; `"stop"`
calls `shiny::stopApp()`, after which `peer_main()` closes the channel and
the process exits cleanly (`replica_stop_command()`). It is not used by the
server's own stop path, which kills the process tree as before: a graceful
stop is only as prompt as the app's event loop, which is exactly what is
unavailable when a replica is stuck.

<!-- MIZU-RESULTS -->
