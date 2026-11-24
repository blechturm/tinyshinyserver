# Transport microbenchmark: round trips between two R processes on one
# machine, over
#   mizu        a mizu channel, blocking receive (spin, then park)
#   mizu_async  a mizu channel, received through later as an event loop would
#   websocket   a local WebSocket (websocket client -> httpuv server), the hop
#               that tinyshinyserver's proxy makes to an app for every message
#   http        a local HTTP request (curl -> httpuv), the hop for every request
# for payloads of several sizes. The peer echoes each message back.
#
#   Rscript transport-bench.R OUT.csv [LABEL]
#
# Run it inside the benchmark container with --cpuset-cpus to see the effect
# of the number of CPUs; both processes share them.

args <- commandArgs(trailingOnly = TRUE)
out <- args[[1]]
label <- if (length(args) > 1) args[[2]] else ""
suppressPackageStartupMessages({
  library(mizu)
  library(later)
})
sizes <- c(100, 10e3, 1e6, 10e6)
iterations <- function(size) if (size <= 10e3) 2000L else if (size <= 1e6) 200L else 30L
payload <- function(size) strrep("x", size)
results <- list()
record <- function(transport, size, seconds) {
  results[[length(results) + 1]] <<- data.frame(label = label, transport = transport, bytes = size,
    iteration = seq_along(seconds), rtt_us = seconds * 1e6)
}
time_now <- function() as.numeric(proc.time()[["elapsed"]])
clock <- function() as.numeric(Sys.time())

# mizu, blocking receive
ch <- mizu_channel(quote(repeat {
  x <- mizu_recv(ch)
  if (inherits(x, "mizu_sentinel")) break
  mizu_send(ch, x)
}), arena_size = 64 * 1024^2)
for (size in sizes) {
  x <- payload(size)
  for (i in 1:20) { mizu_send(ch, x); mizu_recv(ch, 10) }
  t <- vapply(seq_len(iterations(size)), function(i) {
    start <- clock(); mizu_send(ch, x); y <- mizu_recv(ch, 10); clock() - start
  }, numeric(1))
  record("mizu", size, t)
}

# mizu, received on the event loop
for (size in sizes) {
  x <- payload(size)
  t <- numeric(iterations(size))
  for (i in seq_along(t)) {
    done <- FALSE
    start <- clock()
    promises::then(mizu_recv_async(ch, 10), function(y) done <<- TRUE)
    mizu_send(ch, x)
    while (!done) run_now(1)
    t[[i]] <- clock() - start
  }
  record("mizu_async", size, t)
}
mizu_close(ch)

# An httpuv echo server in another process, for WebSocket and HTTP
port <- 47000L + sample.int(1000, 1)
server <- callr::r_bg(function(port) {
  httpuv::runServer("127.0.0.1", port, list(
    call = function(req) {
      body <- req$rook.input$read()
      list(status = 200L, headers = list("Content-Type" = "application/octet-stream"), body = body)
    },
    onWSOpen = function(ws) ws$onMessage(function(binary, message) ws$send(message))
  ))
}, args = list(port = port))
deadline <- Sys.time() + 20
repeat {
  ok <- tryCatch({ curl::curl_fetch_memory(sprintf("http://127.0.0.1:%d/", port)); TRUE }, error = function(e) FALSE)
  if (ok || Sys.time() > deadline) break
  Sys.sleep(0.1)
}

ws <- websocket::WebSocket$new(sprintf("ws://127.0.0.1:%d/", port), autoConnect = FALSE,
  maxMessageSize = 64 * 1024^2)
opened <- FALSE
received <- FALSE
ws$onOpen(function(event) opened <<- TRUE)
ws$onMessage(function(event) received <<- TRUE)
ws$connect()
while (!opened) run_now(0.1)
for (size in sizes) {
  x <- payload(size)
  t <- numeric(iterations(size))
  for (i in seq_along(t)) {
    received <- FALSE
    start <- clock()
    ws$send(x)
    while (!received) run_now(1)
    t[[i]] <- clock() - start
  }
  record("websocket", size, t)
}
ws$close()

handle <- curl::new_handle()
for (size in sizes) {
  x <- charToRaw(payload(size))
  t <- vapply(seq_len(iterations(size)), function(i) {
    curl::handle_setopt(handle, post = TRUE, postfields = x)
    start <- clock()
    curl::curl_fetch_memory(sprintf("http://127.0.0.1:%d/", port), handle)
    clock() - start
  }, numeric(1))
  record("http", size, t)
}
server$kill()

all <- do.call(rbind, results)
utils::write.csv(all, out, row.names = FALSE)
summary <- aggregate(rtt_us ~ transport + bytes, all, function(v) round(stats::quantile(v, c(0.5, 0.99))))
print(summary)
