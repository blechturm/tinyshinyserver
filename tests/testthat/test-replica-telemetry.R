# Tests for replica telemetry over mizu channels (experimental, optional)

telemetry_config <- function(scheduler = "workload_aware") {
  path <- tempfile(fileext = ".json")
  on.exit(unlink(path), add = TRUE)
  writeLines(jsonlite::toJSON(list(
    apps = list(list(name = "demo", path = unused_app_path(), resident = TRUE, replicas = 3, scheduler = scheduler)),
    log_dir = tempdir(), starting_port = 3001
  ), auto_unbox = TRUE), path)
  config <- ShinyServerConfig$new()
  config$config <- config$read_config(path)
  for (name in replica_group(config, "demo")$members) {
    config$add_app_process(name, list(is_alive = function() TRUE, get_pid = function() Sys.getpid()))
  }
  config
}

# Set TSS_REPLICA_TELEMETRY for the calling test
local_telemetry_setting <- function(value, frame = parent.frame()) {
  old <- Sys.getenv("TSS_REPLICA_TELEMETRY", unset = NA)
  if (is.na(value)) Sys.unsetenv("TSS_REPLICA_TELEMETRY") else Sys.setenv(TSS_REPLICA_TELEMETRY = value)
  do.call(on.exit, list(quote(
    if (is.na(old)) Sys.unsetenv("TSS_REPLICA_TELEMETRY") else Sys.setenv(TSS_REPLICA_TELEMETRY = old)
  ), add = TRUE), envir = frame)
  # the expression above reads `old` in the test's frame
  assign("old", old, envir = frame)
}

# Telemetry as note_heartbeat() leaves it, without a channel
fake_telemetry <- function(config, name, busy, age = 0) {
  state <- new.env(parent = emptyenv())
  state$busy <- busy
  state$last_seen <- config$clock_seconds() - age
  state$delays <- numeric()
  assign(paste0("telemetry:", name), state, envir = config$replica_state)
  state
}

test_that("telemetry is off unless asked for", {
  local_telemetry_setting(NA)
  expect_false(replica_telemetry_enabled())
  local_telemetry_setting("other")
  expect_false(replica_telemetry_enabled())
})

test_that("workload_aware without telemetry chooses as least_connections does", {
  config <- telemetry_config()
  config$add_ws_connection("a", list(app_name = "demo-1"))
  group <- replica_group(config, "demo")
  # then all three have one session or pending visitor, and the rotation goes on
  expect_equal(replicate(4, choose_replica(config, group)), c("demo-2", "demo-3", "demo-1", "demo-2"))
})

test_that("workload_aware avoids a busy replica that least_connections would choose", {
  for (scheduler in c("least_connections", "workload_aware")) {
    config <- telemetry_config(scheduler)
    config$add_ws_connection("a", list(app_name = "demo-1"))
    config$add_ws_connection("b", list(app_name = "demo-2"))
    config$add_ws_connection("c", list(app_name = "demo-3"))
    config$add_ws_connection("d", list(app_name = "demo-3"))
    fake_telemetry(config, "demo-1", busy = 0.9)
    fake_telemetry(config, "demo-2", busy = 0)
    fake_telemetry(config, "demo-3", busy = 0)
    chosen <- choose_replica(config, replica_group(config, "demo"), record = FALSE)
    expect_equal(chosen, if (scheduler == "workload_aware") "demo-2" else "demo-1")
  }
})

test_that("overdue heartbeats make a replica count as busy, not idle", {
  config <- telemetry_config()
  fake_telemetry(config, "demo-1", busy = 0, age = TELEMETRY_STALE_SECONDS + 0.5)
  fake_telemetry(config, "demo-2", busy = 0.2)
  expect_equal(replica_busy(config, "demo-1"), 1)
  expect_equal(replica_busy(config, "demo-2"), 0.2)
  expect_null(replica_busy(config, "demo-3"))
})

test_that("heartbeats measure busyness on the replica's clock", {
  config <- telemetry_config()
  state <- fake_telemetry(config, "demo-1", busy = 0)
  # seq, lag, cpu seconds, sessions, wall clock
  note_heartbeat(config, state, c(1, 0, 10, 2, 1000))
  expect_equal(state$busy, 0)
  # The next one arrives with it, as after a busy turn of the server's
  # event loop, but 0.1 s later on the replica, which used 0.1 s of CPU
  note_heartbeat(config, state, c(2, 0, 10.1, 2, 1000.1))
  expect_equal(state$busy, TELEMETRY_EWMA_ALPHA)
  # A lag counts as busy time, as for a replica blocked in Sys.sleep()
  note_heartbeat(config, state, c(3, 1, 10.1, 2, 1001.2))
  expect_gt(state$busy, TELEMETRY_EWMA_ALPHA)
  expect_equal(state$sessions, 2)
  expect_length(state$delays, 3)
})

test_that("a replica's process reports heartbeats and its death over mizu", {
  skip_on_cran()
  skip_if_not_installed("mizu", "0.1.1")
  local_telemetry_setting("mizu")
  app_dir <- tempfile("tss-telemetry-app")
  dir.create(app_dir)
  writeLines("shiny::shinyApp(shiny::fluidPage(), function(input, output) {})", file.path(app_dir, "app.R"))
  log_dir <- tempfile("tss-telemetry-logs")
  on.exit(unlink(c(app_dir, log_dir), recursive = TRUE), add = TRUE)
  config <- ShinyServerConfig$new()
  config$config <- list(
    apps = list(list(name = "demo-1", path = app_dir, resident = TRUE, replica_of = "demo",
      scheduler = "workload_aware", port = sample(40000:45000, 1))),
    log_dir = log_dir, restart_delay = 60, health_check_interval = 10
  )
  manager <- create_process_manager(config)
  expect_true(manager$start_app(config$config$apps[[1]]))
  on.exit({
    manager$cancel_pending_restarts()
    stop_test_app_processes(config)
  }, add = TRUE)
  wait <- function(condition, seconds = 30) {
    deadline <- Sys.time() + seconds
    while (!isTRUE(condition()) && Sys.time() < deadline) later::run_now(0.05)
    isTRUE(condition())
  }
  expect_true(wait(function() (config$replica_state[["telemetry:demo-1"]]$beats %||% 0) >= 5))
  expect_lt(replica_busy(config, "demo-1"), 0.5)
  process <- config$get_app_process("demo-1")
  expect_equal(process$get_pid(), mizu::mizu_channel_info(config$replica_state[["telemetry:demo-1"]]$ch)$peer_pid)

  # No periodic health check runs here: the channel's report of the death
  # runs one, which takes the dead process away
  process$kill()
  expect_true(wait(function() is.null(config$replica_state[["telemetry:demo-1"]]), 5))
  expect_true(wait(function() is.null(config$get_app_process("demo-1")), 5))

  # A replica asked to stop ends its app and exits cleanly, not as a failure
  manager$cancel_pending_restarts()
  expect_true(manager$start_app(config$config$apps[[1]]))
  expect_true(wait(function() (config$replica_state[["telemetry:demo-1"]]$beats %||% 0) >= 2))
  process <- config$get_app_process("demo-1")
  expect_true(replica_stop_command(config, "demo-1"))
  expect_true(wait(function() !process$is_alive(), 10))
  expect_equal(process$get_exit_status(), 0)
  expect_false(process_failed(process))
})
