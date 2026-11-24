# Replica telemetry over mizu channels (experimental, optional)
#
# With the environment variable TSS_REPLICA_TELEMETRY=mizu and the mizu
# package installed, each replica's process gets one persistent shared-memory
# channel to the server. The process stays callr's, with its logs,
# environment, and supervision: the launch function's first act is to attach
# to the channel as mizu's peer, and the expression that the server stages for
# it starts a heartbeat and then runs the app as before. Nothing in the app
# changes.
#
# Every TELEMETRY_INTERVAL seconds the replica sends, without blocking, a
# numeric vector: sequence number, event-loop lag (how late the heartbeat
# timer fired), CPU seconds used so far, open Shiny sessions, and its wall
# clock. A replica that is busy in R, computing or blocked in Sys.sleep(),
# cannot send, and the missing heartbeats are what show it: a replica whose
# last heartbeat is older than TELEMETRY_STALE_SECONDS counts as busy now.
# The server receives on the event loop through later; it never waits on a
# channel. The death of a replica's process arrives as an event at once, and
# runs the health check that restarts it, instead of waiting for the next
# periodic one.
#
# The workload_aware scheduler uses the telemetry: a replica's load is its
# sessions and pending visitors, as for least_connections, plus
# TELEMETRY_BUSY_WEIGHT times its recent busy fraction.

TELEMETRY_INTERVAL <- 0.1
TELEMETRY_STALE_SECONDS <- 0.3
TELEMETRY_BUSY_WEIGHT <- 2
# Weight of the newest busy sample in the moving average: about 2 s of memory
TELEMETRY_EWMA_ALPHA <- 0.05
# Ring geometry: heartbeats are 40 bytes, and a ring that fills while the
# server is busy drops heartbeats rather than blocking. The defaults of
# mizu_channel() would take 16 MB of shared memory per replica, and Docker
# gives containers 64 MB of /dev/shm.
TELEMETRY_CAPACITY <- 64L
TELEMETRY_SLOT_SIZE <- 128L

replica_telemetry_enabled <- function() {
  identical(Sys.getenv("TSS_REPLICA_TELEMETRY"), "mizu") && requireNamespace("mizu", quietly = TRUE) &&
    requireNamespace("later", quietly = TRUE)
}

# The expression that the replica's process evaluates as mizu's peer, with
# `ch` bound to its end of the channel. It captures nothing from the server.
replica_peer_expr <- function(interval = TELEMETRY_INTERVAL) {
  bquote({
    local({
      interval <- .(interval)
      seq <- 0
      sessions <- function() tryCatch(shiny:::appsByToken$size(), error = function(e) NA_real_)
      tick <- function(due) {
        now <- proc.time()
        seq <<- seq + 1
        # A full ring drops the heartbeat; a closed one ends them
        sent <- mizu::mizu_send(ch, c(seq, max(0, now[["elapsed"]] - due),
          now[["user.self"]] + now[["sys.self"]], sessions(), as.numeric(Sys.time())))
        if (!inherits(sent, "mizu_closed")) {
          due <- now[["elapsed"]] + interval
          later::later(function() tick(due), interval)
        }
      }
      due <- proc.time()[["elapsed"]] + interval
      later::later(function() tick(due), interval)
      # A command from the server: "stop" ends the app as shiny::stopApp() does
      mizu::mizu_recv_handler(ch, function(command) {
        if (identical(command, "stop")) shiny::stopApp()
      })
    })
    do.call(.tss_app_main, .tss_app_args)
  })
}

# A channel for a replica that is about to start: the handle, and the token
# that its process attaches with
replica_channel_create <- function() {
  ns <- asNamespace("mizu")
  ch <- .Call(ns$mizu_channel_create, replica_peer_expr(), TELEMETRY_CAPACITY, TELEMETRY_SLOT_SIZE, 0, FALSE)
  list(ch = ch, token = .Call(ns$mizu_channel_suffix, ch))
}

# Wait, without blocking the event loop, for the replica's process to attach;
# then receive its heartbeats. mizu_channel() itself waits in a blocking call
# for the peer, which would stall every app's traffic for the R startup of
# each replica, so its steps are taken here one by one.
replica_channel_watch <- function(config, process_manager, app_name, channel, process, started = Sys.time()) {
  force(started)
  ns <- asNamespace("mizu")
  key <- paste0("telemetry:", app_name)
  if (!identical(config$get_app_process(app_name), process)) {
    .Call(ns$mizu_channel_destroy, channel$ch)
    return(invisible(FALSE))
  }
  if (!isTRUE(.Call(ns$mizu_channel_ready_wait, channel$ch, 0))) {
    if (!is_process_alive(process) || difftime(Sys.time(), started, units = "secs") > config$APP_STARTUP_TIMEOUT_SECONDS) {
      logger::log_warn("Replica {app_name} did not attach to its telemetry channel", app_name = app_name)
      .Call(ns$mizu_channel_destroy, channel$ch)
      return(invisible(FALSE))
    }
    later::later(function() {
      replica_channel_watch(config, process_manager, app_name, channel, process, started)
    }, 0.02)
    return(invisible(FALSE))
  }
  state <- new.env(parent = emptyenv())
  state$ch <- channel$ch
  state$process <- process
  state$attached <- config$clock_seconds()
  state$last_seen <- state$attached
  state$busy <- 0
  state$delays <- numeric()
  assign(key, state, envir = config$replica_state)
  logger::log_info("Replica {app_name} attached to its telemetry channel after {seconds} s",
    app_name = app_name, seconds = round(as.numeric(difftime(Sys.time(), started, units = "secs")), 3)
  )
  mizu::mizu_recv_handler(channel$ch, function(message) {
    if (inherits(message, "condition")) {
      replica_channel_ended(config, process_manager, app_name, state, message)
    } else {
      note_heartbeat(config, state, message)
    }
  })
  invisible(TRUE)
}

note_heartbeat <- function(config, state, beat) {
  now <- config$clock_seconds()
  # The share of the time since the last heartbeat that the replica was busy:
  # its CPU time, or its lag for time spent blocked without using the CPU.
  # Measured on the replica's clock: heartbeats that wait while this event
  # loop is busy arrive together.
  wall <- beat[[5]] - (state$peer_wall %||% beat[[5]])
  state$peer_wall <- beat[[5]]
  if (!is.null(state$cpu) && wall > 0) {
    sample <- min(1, max((beat[[3]] - state$cpu) / wall, beat[[2]] / (TELEMETRY_INTERVAL + beat[[2]])))
    state$busy <- (1 - TELEMETRY_EWMA_ALPHA) * state$busy + TELEMETRY_EWMA_ALPHA * sample
  }
  state$cpu <- beat[[3]]
  state$lag <- beat[[2]]
  state$sessions <- beat[[4]]
  state$last_seen <- now
  state$beats <- (state$beats %||% 0) + 1
  # How long the heartbeat took to reach this event loop, kept for the
  # benchmark: the last 1000
  state$delays <- utils::tail(c(state$delays, as.numeric(Sys.time()) - beat[[5]]), 1000)
}

replica_channel_ended <- function(config, process_manager, app_name, state, condition) {
  key <- paste0("telemetry:", app_name)
  if (identical(config$replica_state[[key]], state)) rm(list = key, envir = config$replica_state)
  # The peer has gone, so closing waits for nothing
  suppressWarnings(tryCatch(mizu::mizu_close(state$ch, timeout = 0), error = function(e) NULL))
  if (!inherits(condition, "mizu_peer_gone")) {
    return(invisible())
  }
  logger::log_warn("Replica {app_name}'s process ended, as its telemetry channel reports", app_name = app_name)
  state$gone_at <- Sys.time()
  # The health check finds the exited process and restarts the replica as
  # usual; run it now rather than at its next turn
  if (!is.null(process_manager) && identical(config$get_app_process(app_name), state$process)) {
    later::later(function() tryCatch(process_manager$health_check(), error = function(e) {
      logger::log_error("Health check after a replica's death failed: {error}", error = conditionMessage(e))
    }), 0)
  }
  invisible()
}

# How busy a replica is, from 0 to 1, for the workload_aware scheduler: its
# recent busy fraction, or 1 while its heartbeats are overdue. NULL without
# telemetry.
replica_busy <- function(config, name) {
  state <- config$replica_state[[paste0("telemetry:", name)]]
  if (is.null(state)) {
    return(NULL)
  }
  if (config$clock_seconds() - state$last_seen > TELEMETRY_STALE_SECONDS) {
    return(1)
  }
  state$busy
}

# Telemetry of every replica, for the management API and the benchmark
replica_telemetry_summary <- function(config) {
  keys <- grep("^telemetry:", ls(config$replica_state), value = TRUE)
  stats::setNames(lapply(keys, function(key) {
    state <- config$replica_state[[key]]
    delays <- state$delays
    list(
      beats = state$beats %||% 0,
      age_seconds = config$clock_seconds() - state$last_seen,
      busy = replica_busy(config, sub("^telemetry:", "", key)),
      lag_seconds = state$lag %||% NA,
      sessions = state$sessions %||% NA,
      delay_ms = if (length(delays)) as.list(1000 * stats::quantile(delays, c(0.5, 0.95, 0.99, 1), names = FALSE)) else NULL
    )
  }), sub("^telemetry:", "", keys))
}

# Ask a replica to stop its app, which then exits. Returns FALSE without a channel.
replica_stop_command <- function(config, name) {
  state <- config$replica_state[[paste0("telemetry:", name)]]
  if (is.null(state)) {
    return(FALSE)
  }
  isTRUE(mizu::mizu_send(state$ch, "stop"))
}
