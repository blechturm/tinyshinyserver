# Engineering spike: session-aware load balancing in tinyshinyserver

Branch `spike/session-load-balancing`, from upstream `0f0a76d` (0.3.0).
This is an experiment, not a proposal ready for merging. It asks whether
tinyshinyserver's existing architecture can run several R processes for one
logical Shiny app, with each session pinned to one of them, and when that
helps. A second part evaluates [mizu](https://github.com/shikokuchuo/mizu)
shared-memory channels as an optional control plane between the server and
those processes.

<!-- RESULTS-SUMMARY -->

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
| Spike, final | see below | 0 | 1 |

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

<!-- RESULTS -->

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

## Effort for a production-quality contribution

<!-- EFFORT -->

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
  unless `GLIBC_TUNABLES` mentions `glibc.malloc`. Each such process may
  then keep up to 128 MB of freed heap instead of returning it to the
  system: an unrequested change of memory behaviour in the app.

### Integration with the existing process lifecycle

The goal was one supervisor, not two. The prototype keeps callr's
`r_bg()` as the launcher and owner of every process: logs, environment,
working directory, profile handling, `supervise = TRUE`, `kill_tree()` and
the health check are unchanged.

- `start_app()` creates the channel's region first (mizu's internal
  `mizu_channel_create`, `mizu_channel_suffix`) and passes the join token
  to the callr function as one more argument.
- The callr function's first act, when given a token, is to store its own
  arguments and itself in the global environment and call
  `mizu:::peer_main(token)`. The staged expression starts the heartbeat and
  a command handler, then calls the same function again without the token,
  which runs the app exactly as before. When the app returns or fails,
  `peer_main()` closes the channel and quits with the app's status, so the
  health check still tells a crash from a clean exit.
- The server never calls the blocking `mizu_channel()`. It polls
  `mizu_channel_ready_wait(ch, 0)` from a `later` callback every 20 ms
  until the peer attaches (typically 0.1–0.3 s, the child's R startup),
  then installs `mizu_recv_handler()`. With `mizu_channel()` itself, each
  replica start or restart would freeze every session of every app for the
  child's R startup.
- A `mizu_peer_gone` condition runs the existing health check at once,
  which closes the replica's sessions and schedules its restart as usual.
  The scheduler does not rely on it: it reads process liveness at each
  choice anyway.

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

Each replica sends five numbers every 100 ms over its channel: sequence
number, event-loop lag, CPU seconds used, open Shiny sessions (from Shiny's
internal `appsByToken`, so the app needs no change), and its wall clock.
A full ring drops the heartbeat. A busy replica cannot send at all, so
**missing heartbeats are the signal**: a replica whose last heartbeat is
older than 300 ms counts as fully busy, never as idle. Its recent busy
fraction is a moving average (about 2 s) of the larger of its CPU share and
its lag share, measured on the replica's own clock so that heartbeats that
queue up while the server is busy do not distort it.

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
