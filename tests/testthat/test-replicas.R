# Tests for replica groups (experimental session load balancing)

# The configuration that read_config() returns for these apps. Not
# read_test_config(), whose modifyList() keeps its own list of apps.
read_apps_config <- function(apps, ...) {
  path <- tempfile(fileext = ".json")
  on.exit(unlink(path), add = TRUE)
  writeLines(jsonlite::toJSON(list(apps = apps, log_dir = tempdir(), starting_port = 3001, ...), auto_unbox = TRUE), path)
  ShinyServerConfig$new()$read_config(path)
}

replica_config <- function(..., apps = NULL) {
  apps <- apps %||% list(list(name = "demo", path = unused_app_path(), resident = TRUE, replicas = 3, ...))
  config <- ShinyServerConfig$new()
  config$config <- read_apps_config(apps)
  config
}

# A process that the scheduler takes for a running replica
live_process <- function() list(is_alive = function() TRUE, get_pid = function() Sys.getpid())

start_all <- function(config, names = replica_group(config, "demo")$members) {
  for (name in names) config$add_app_process(name, live_process())
}

test_that("an app without replicas is read as before", {
  loaded <- read_apps_config(list(list(name = "app", path = unused_app_path())))
  expect_length(loaded$apps, 1)
  expect_setequal(names(loaded$apps[[1]]), KNOWN_APP_FIELDS)
})

test_that("an app with replicas runs as one app per replica", {
  loaded <- read_apps_config(list(
    list(name = "demo", path = unused_app_path(), resident = TRUE, replicas = 3, scheduler = "round_robin", appstart_timeout = 7),
    list(name = "other", path = unused_app_path())
  ))
  names <- vapply(loaded$apps, function(app) app$name, character(1))
  expect_equal(names, c("demo-1", "demo-2", "demo-3", "other"))
  for (app in loaded$apps[1:3]) {
    expect_equal(app$replica_of, "demo")
    expect_equal(app$scheduler, "round_robin")
    expect_true(app$resident)
    expect_equal(app$appstart_timeout, 7)
    expect_null(app$replicas)
  }
  expect_null(loaded$apps[[4]]$replica_of)
})

test_that("each replica gets its own port", {
  config <- ShinyServerConfig$new()
  path <- tempfile(fileext = ".json")
  on.exit(unlink(path), add = TRUE)
  writeLines(jsonlite::toJSON(list(
    apps = list(list(name = "demo", path = unused_app_path(), replicas = 4)),
    log_dir = tempdir(), starting_port = 46001
  ), auto_unbox = TRUE), path)
  config$load_config(path)
  ports <- vapply(config$config$apps, function(app) app$port, numeric(1))
  expect_length(unique(ports), 4)
})

test_that("the scheduler defaults to least_connections", {
  loaded <- read_apps_config(list(list(name = "demo", path = unused_app_path(), replicas = 2)))
  expect_equal(loaded$apps[[1]]$scheduler, "least_connections")
})

test_that("invalid replica settings are rejected", {
  invalid <- function(app, pattern, ...) {
    expect_error(read_apps_config(list(app, ...)), pattern)
  }
  path <- unused_app_path()
  invalid(list(name = "demo", path = path, replicas = 0), "replicas must be a whole number")
  invalid(list(name = "demo", path = path, replicas = 2.5), "replicas must be a whole number")
  invalid(list(name = "demo", path = path, replicas = MAX_REPLICAS + 1), "replicas must be a whole number")
  invalid(list(name = "demo", path = path, replicas = "2"), "replicas must be a whole number")
  invalid(list(name = "demo", path = path, scheduler = "round_robin"), "scheduler needs replicas")
  invalid(list(name = "demo", path = path, replicas = 2, scheduler = "random"), "scheduler must be one of")
  # A replica's name may not be another app's, in any letter case
  invalid(list(name = "demo", path = path, replicas = 2), "Duplicate app name: Demo-2", list(name = "Demo-2", path = path))
  invalid(list(name = "demo-1", path = path), "Duplicate app name: demo-1", list(name = "demo", path = path, replicas = 2))
  # Nor may it exceed the length of an app name
  invalid(list(name = strrep("a", 49), path = path, replicas = 2), "replica")
})

test_that("replica fields are recognized, and a user cannot set replica_of", {
  config <- ShinyServerConfig$new()
  path <- tempfile(fileext = ".json")
  on.exit(unlink(path), add = TRUE)
  writeLines(jsonlite::toJSON(list(
    apps = list(list(name = "demo", path = unused_app_path(), replicas = 2, scheduler = "round_robin", replica_of = "x")),
    log_dir = tempdir(), starting_port = 3001
  ), auto_unbox = TRUE), path)
  loaded <- config$read_config(path)
  expect_equal(config$ignored_fields, "\"replica_of\" in app \"demo\"")
  expect_equal(loaded$apps[[1]]$replica_of, "demo")
})

test_that("the port range check counts every replica", {
  result <- ShinyServerConfig$new()$validate_config(list(
    apps = list(list(name = "demo", path = "/tmp/a", replicas = 10)), log_dir = "/tmp/logs",
    starting_port = 65530, proxy_port = 80, management_port = 81
  ))
  expect_false(result$valid)
  expect_match(result$error, "Not enough port range")
})

test_that("round_robin sends visitors to each replica in turn", {
  config <- replica_config(scheduler = "round_robin")
  start_all(config)
  group <- replica_group(config, "demo")
  picks <- replicate(6, choose_replica(config, group))
  expect_equal(picks, rep(c("demo-1", "demo-2", "demo-3"), 2))
})

test_that("least_connections prefers the replica with fewest open sessions", {
  config <- replica_config()
  start_all(config)
  for (id in c("a", "b")) config$add_ws_connection(id, list(app_name = "demo-1"))
  config$add_ws_connection("c", list(app_name = "demo-2"))
  expect_equal(choose_replica(config, replica_group(config, "demo")), "demo-3")
})

test_that("visitors arriving together are spread before their WebSockets open", {
  config <- replica_config()
  start_all(config)
  group <- replica_group(config, "demo")
  picks <- replicate(9, choose_replica(config, group))
  expect_equal(as.vector(table(picks)), c(3, 3, 3))
  expect_equal(unname(vapply(group$members, function(n) replica_load(config, n), numeric(1))), c(3, 3, 3))
})

test_that("an opened WebSocket takes the place of its pending assignment", {
  config <- replica_config()
  start_all(config)
  group <- replica_group(config, "demo")
  expect_equal(choose_replica(config, group), "demo-1")
  expect_equal(replica_load(config, "demo-1"), 1)
  config$add_ws_connection("s1", list(app_name = "demo-1"))
  expect_equal(length(pending_assignments(config, "demo-1")), 0)
  expect_equal(replica_load(config, "demo-1"), 1)
  # A session without an assignment, such as a reload at the replica's own
  # address, adds to the count
  config$add_ws_connection("s2", list(app_name = "demo-1"))
  expect_equal(replica_load(config, "demo-1"), 2)
  config$remove_ws_connection("s1")
  config$remove_ws_connection("s2")
  expect_equal(replica_load(config, "demo-1"), 0)
})

test_that("an assignment whose WebSocket never opens stops counting", {
  config <- replica_config()
  start_all(config)
  elapsed <- 1000
  local_mocked_bindings(raw_elapsed_seconds = function() elapsed)
  config$clock_seconds()
  choose_replica(config, replica_group(config, "demo"))
  expect_equal(replica_load(config, "demo-1"), 1)
  elapsed <- elapsed + REPLICA_PENDING_SECONDS + 1
  expect_equal(replica_load(config, "demo-1"), 0)
})

test_that("replicas that are not running or still starting receive no visitors", {
  config <- replica_config()
  config$add_app_process("demo-1", list(is_alive = function() FALSE))
  config$add_app_process("demo-2", live_process())
  config$set_app_starting("demo-2")
  config$add_app_process("demo-3", live_process())
  group <- replica_group(config, "demo")
  expect_equal(unique(replicate(4, choose_replica(config, group))), "demo-3")

  # Once ready, it takes visitors until it is as loaded as demo-3, which has
  # the four above pending
  config$set_app_ready("demo-2")
  expect_equal(replicate(5, choose_replica(config, group)), c(rep("demo-2", 4), "demo-3"))
})

test_that("a request for a group with no available replica is answered with HTTP 503", {
  config <- replica_config()
  response <- handle_proxy_request("/proxy/demo/", "GET", "", httpuv_request(list(accept = "application/json")), config)
  expect_equal(response$status, 503)
  expect_equal(response$headers[["Retry-After"]], "2")
})

test_that("dormant on-demand replicas may be chosen, but not those waiting after a failure", {
  dir <- make_test_app_dir()
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  config <- replica_config(apps = list(list(name = "demo", path = dir, resident = FALSE, replicas = 2)))
  group <- replica_group(config, "demo")
  expect_equal(choose_replica(config, group), "demo-1")
  config$config$restart_delay <- 60
  config$note_start_failure("demo-2")
  expect_equal(unique(replicate(3, choose_replica(config, group))), "demo-1")
})

test_that("the logical address redirects to a replica's address, keeping path and query", {
  config <- replica_config()
  start_all(config)
  response <- handle_proxy_request("/proxy/demo/page/x", "GET", "?a=1", httpuv_request(list(accept = "application/json")), config)
  expect_equal(response$status, 307L)
  expect_equal(response$headers$Location, "/proxy/demo-1/page/x?a=1")
  expect_equal(response$headers[["Cache-Control"]], "no-store")

  # The name without a trailing slash goes to the replica's root
  response <- handle_proxy_request("/proxy/demo", "GET", "", httpuv_request(list(accept = "application/json")), config)
  expect_equal(response$headers$Location, "/proxy/demo-2/")

  config$config$base_path <- "/shiny"
  response <- handle_proxy_request("/proxy/demo/", "GET", "", httpuv_request(list(accept = "application/json")), config)
  expect_equal(response$headers$Location, "/shiny/proxy/demo-3/")
})

test_that("a replica's own address is proxied as any app's", {
  config <- replica_config()
  start_all(config)
  local_mocked_bindings(forward_request = function(method, target_url, ...) list(status = 200L, body = target_url))
  config$config$apps[[2]]$port <- 4567
  response <- handle_proxy_request("/proxy/demo-2/x", "GET", "", httpuv_request(list(accept = "application/json")), config)
  expect_equal(response$body, "http://127.0.0.1:4567/x")
})

test_that("unknown apps are still not found", {
  config <- replica_config()
  response <- handle_proxy_request("/proxy/demox/", "GET", "", httpuv_request(list(accept = "application/json")), config)
  expect_equal(response$status, 404)
})

test_that("the landing page shows a group under its logical name", {
  config <- replica_config(apps = list(
    list(name = "demo", path = unused_app_path(), resident = TRUE, replicas = 2),
    list(name = "plain", path = unused_app_path(), resident = TRUE)
  ))
  expect_equal(vapply(public_apps(config$config$apps), function(a) a$name, character(1)), c("demo", "plain"))

  config$add_app_process("demo-2", live_process())
  config$add_ws_connection("a", list(app_name = "demo-1"))
  config$add_ws_connection("b", list(app_name = "demo-2"))
  config$add_ws_connection("c", list(app_name = "demo-2"))
  apps <- jsonlite::fromJSON(handle_apps_api(config)$body, simplifyVector = FALSE)
  expect_equal(names(apps), c("demo", "plain"))
  expect_equal(apps$demo$status, "running")
  expect_equal(apps$demo$connections, 3)
  expect_equal(apps$plain$status, "stopped")

  # The management API lists each replica
  statuses <- create_process_manager(config)$get_all_app_status()
  expect_equal(names(statuses), c("demo-1", "demo-2", "plain"))
})

# A real server with two replicas of a small app, driven over HTTP and
# WebSockets from this process: affinity, a replica's crash, and shutdown
test_that("a replica group serves, survives a crash, and stops with the server", {
  skip_on_cran()
  skip_if_not_installed("websocket")
  root <- normalizePath(test_path("..", ".."), mustWork = FALSE)
  skip_if_not(file.exists(file.path(root, "DESCRIPTION")), "Needs the package source")

  app_dir <- tempfile("tss-replica-app")
  dir.create(app_dir)
  writeLines(c(
    "library(shiny)",
    "server <- function(input, output, session) {",
    "  output$pid <- renderText(Sys.getpid())",
    "  outputOptions(output, 'pid', suspendWhenHidden = FALSE)",
    "}",
    "shinyApp(fluidPage(textOutput('pid')), server)"
  ), file.path(app_dir, "app.R"))
  ports <- sample(30000:40000, 1) + c(0, 1, 10)
  log_dir <- tempfile("tss-replica-logs")
  config_file <- tempfile(fileext = ".json")
  writeLines(jsonlite::toJSON(list(
    apps = list(list(name = "demo", path = app_dir, resident = TRUE, replicas = 2)),
    starting_port = ports[[3]], proxy_port = ports[[1]], management_port = ports[[2]],
    log_dir = log_dir, restart_delay = 4, health_check_interval = 1
  ), auto_unbox = TRUE), config_file)
  server <- callr::r_bg(function(root, config_file) {
    pkgload::load_all(root, quiet = TRUE)
    start_tss(config_file)
  }, args = list(root = root, config_file = config_file))
  on.exit({
    server$kill_tree()
    unlink(c(app_dir, log_dir, config_file), recursive = TRUE)
  }, add = TRUE)

  proxy <- paste0("http://127.0.0.1:", ports[[1]])
  manage <- paste0("http://127.0.0.1:", ports[[2]])
  get <- function(url) {
    handle <- curl::new_handle(followlocation = FALSE)
    tryCatch(curl::curl_fetch_memory(url, handle), error = function(e) NULL)
  }
  apps <- function() {
    response <- get(paste0(manage, "/api/apps"))
    if (is.null(response) || response$status_code != 200) return(NULL)
    jsonlite::fromJSON(rawToChar(response$content), simplifyVector = FALSE)
  }
  wait_until <- function(condition, seconds = 60) {
    deadline <- Sys.time() + seconds
    while (Sys.time() < deadline) {
      if (isTRUE(tryCatch(condition(), error = function(e) FALSE))) return(TRUE)
      Sys.sleep(0.2)
    }
    FALSE
  }
  ready <- function(name) {
    response <- get(paste0(proxy, "/proxy/", name, "/"))
    !is.null(response) && response$status_code == 200
  }
  expect_true(wait_until(function() ready("demo-1") && ready("demo-2")))
  pids <- vapply(apps()[c("demo-1", "demo-2")], function(app) as.numeric(app$pid), numeric(1))

  # The logical address sends visitors to each replica
  locations <- vapply(1:4, function(i) {
    curl::parse_headers_list(get(paste0(proxy, "/proxy/demo/"))$headers)$location
  }, character(1))
  expect_setequal(locations, c("/proxy/demo-1/", "/proxy/demo-2/"))

  # A WebSocket at a replica's address reaches that replica's process
  session_pid <- function(name) {
    received <- NULL
    ws <- websocket::WebSocket$new(sprintf("ws://127.0.0.1:%d/proxy/%s/websocket/", ports[[1]], name))
    ws$onOpen(function(event) ws$send('{"method":"init","data":{}}'))
    ws$onMessage(function(event) {
      message <- jsonlite::fromJSON(event$data, simplifyVector = FALSE)
      if (!is.null(message$values$pid)) received <<- as.numeric(message$values$pid)
    })
    deadline <- Sys.time() + 20
    while (is.null(received) && Sys.time() < deadline) later::run_now(0.05)
    ws$close()
    received
  }
  expect_equal(session_pid("demo-1"), pids[["demo-1"]])
  expect_equal(session_pid("demo-2"), pids[["demo-2"]])

  # A crashed replica receives no visitors until it is back
  victim <- ps::ps_handle(as.integer(pids[["demo-1"]]))
  ps::ps_kill(victim)
  expect_true(wait_until(function() !ps::ps_is_running(victim), 3))
  locations <- vapply(1:4, function(i) {
    curl::parse_headers_list(get(paste0(proxy, "/proxy/demo/"))$headers)$location
  }, character(1))
  expect_equal(unique(locations), "/proxy/demo-2/")
  expect_equal(session_pid("demo-2"), pids[["demo-2"]])

  expect_true(wait_until(function() {
    app <- apps()[["demo-1"]]
    identical(app$status, "running") && as.numeric(app$pid) != pids[["demo-1"]] && ready("demo-1")
  }))
  locations <- vapply(1:4, function(i) {
    curl::parse_headers_list(get(paste0(proxy, "/proxy/demo/"))$headers)$location
  }, character(1))
  expect_true("/proxy/demo-1/" %in% locations)

  # Shutdown stops every replica
  running <- lapply(apps()[c("demo-1", "demo-2")], function(app) ps::ps_handle(as.integer(app$pid)))
  handle <- curl::new_handle(customrequest = "POST")
  curl::handle_setheaders(handle, "X-TinyShinyServer-Request" = "management")
  curl::curl_fetch_memory(paste0(manage, "/api/shutdown"), handle)
  expect_true(wait_until(function() !server$is_alive(), 30))
  expect_true(wait_until(function() !any(vapply(running, ps::ps_is_running, logical(1))), 10))
})
