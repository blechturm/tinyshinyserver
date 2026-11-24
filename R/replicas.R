# Replica groups (experimental)
#
# An app entry with "replicas": N runs as N ordinary apps, named "{name}-1"
# to "{name}-N", that share its path and settings. Each replica is an app like
# any other: it has its own port, process, logs, startup checks, restarts, and
# connection count, so the process manager and proxy need no change.
#
# The name itself becomes a logical endpoint. A request for /proxy/{name}/...
# is redirected to the same path under one replica's own address,
# /proxy/{name}-{i}/..., chosen by the group's scheduler. Everything the page
# does after that, its scripts and styles, its WebSocket, uploads, and
# downloads, uses relative URLs and so reaches the same replica through the
# existing proxy. The URL itself is the session's affinity.

REPLICA_SCHEDULERS <- c("least_connections", "round_robin")
MAX_REPLICAS <- 64

# How long a visitor who was sent to a replica counts toward its load before
# the page's WebSocket opens there; see replica_load()
REPLICA_PENDING_SECONDS <- 30

replica_names <- function(name, replicas) paste0(name, "-", seq_len(replicas))

is_replica_count <- function(value) {
  is.numeric(value) && length(value) == 1 && is.finite(value) && value == round(value) &&
    value >= 1 && value <= MAX_REPLICAS
}

# How many apps an entry of the configuration file runs, for the check that
# enough ports remain; an invalid count is reported by replica_settings_problem()
replica_count <- function(app) {
  if (is.list(app) && is_replica_count(app[["replicas"]])) app[["replicas"]] else 1
}

# NULL, or what is wrong with an app entry's replica settings
replica_settings_problem <- function(app) {
  if ("replicas" %in% names(app) && !is_replica_count(app$replicas)) {
    return(paste("replicas must be a whole number from 1 to", MAX_REPLICAS))
  }
  if ("scheduler" %in% names(app)) {
    if (!"replicas" %in% names(app)) {
      return("scheduler needs replicas")
    }
    if (!is.character(app$scheduler) || length(app$scheduler) != 1 || !app$scheduler %in% REPLICA_SCHEDULERS) {
      return(paste("scheduler must be one of:", paste(REPLICA_SCHEDULERS, collapse = ", ")))
    }
  }
  NULL
}

# The apps that the configured entries run: an entry with replicas becomes
# one app per replica, which records its group in replica_of. A user cannot
# set replica_of, which read_config() drops as an unknown field.
expand_replica_apps <- function(apps) {
  expanded <- list()
  for (app in apps) {
    if (is.null(app$replicas)) {
      expanded <- c(expanded, list(app))
      next
    }
    base <- app
    base$replicas <- NULL
    base$replica_of <- app$name
    base$scheduler <- app$scheduler %||% REPLICA_SCHEDULERS[[1]]
    for (name in replica_names(app$name, app$replicas)) {
      base$name <- name
      expanded <- c(expanded, list(base))
    }
  }
  expanded
}

# The replica group with the given logical name, or NULL
replica_group <- function(config, name) {
  members <- Filter(function(app) identical(app$replica_of, name), config$config$apps)
  if (length(members) == 0) {
    return(NULL)
  }
  list(
    name = name,
    scheduler = members[[1]]$scheduler,
    members = vapply(members, function(app) app$name, character(1))
  )
}

# Whether a replica may receive a new visitor: a running one that has
# finished starting, or an on-demand one that a request may start now
replica_available <- function(config, app_config) {
  name <- app_config$name
  if (is_process_alive(config$get_app_process(name))) {
    return(is.null(config$get_app_startup_state(name)))
  }
  !isTRUE(app_config$resident) && config$start_backoff_seconds(name) <= 0 &&
    is.null(config$cached_start_problem(app_config))
}

# The visitors sent to a replica whose WebSocket has not opened yet, as the
# times they were sent, on the server's own clock
pending_assignments <- function(config, name) {
  pending <- config$replica_state[[paste0("pending:", name)]]
  if (length(pending) == 0) {
    return(numeric())
  }
  fresh <- pending[pending > config$clock_seconds() - REPLICA_PENDING_SECONDS]
  assign(paste0("pending:", name), fresh, envir = config$replica_state)
  fresh
}

# A WebSocket session opened on a replica: the visitor sent there longest ago
# has arrived. A session without one, such as a page reloaded at the replica's
# own address, is counted by the connection count alone.
take_pending_assignment <- function(config, name) {
  pending <- pending_assignments(config, name)
  if (length(pending) > 0) {
    assign(paste0("pending:", name), pending[-1], envir = config$replica_state)
  }
}

# A replica's load for the least_connections scheduler: its open WebSocket
# sessions, plus the visitors sent there in the last REPLICA_PENDING_SECONDS
# whose WebSocket has not opened yet. Without the latter, visitors who arrive
# together would all see the same idle replica.
replica_load <- function(config, name) {
  config$get_app_connection_count(name) + length(pending_assignments(config, name))
}

# The replica that a new visitor of a group goes to, or NULL when none is
# available. Both schedulers go round the group from where the last choice
# left off, so that least_connections spreads visitors among equally loaded
# replicas too.
choose_replica <- function(config, group) {
  members <- group$members
  counter_key <- paste0("next:", group$name)
  start <- (config$replica_state[[counter_key]] %||% 0L) %% length(members)
  order <- members[(seq_along(members) + start - 1L) %% length(members) + 1L]
  order <- Filter(function(name) replica_available(config, config$get_app_config(name)), order)
  if (length(order) == 0) {
    return(NULL)
  }
  chosen <- if (identical(group$scheduler, "round_robin")) {
    order[[1]]
  } else {
    loads <- vapply(order, function(name) replica_load(config, name), numeric(1))
    order[[which.min(loads)]]
  }
  assign(counter_key, match(chosen, members), envir = config$replica_state)
  assign(paste0("pending:", chosen), c(pending_assignments(config, chosen), config$clock_seconds()),
    envir = config$replica_state
  )
  chosen
}

# The answer to a request for a group's logical address: a redirect to the
# same path at a replica's own address, which the browser keeps for the rest
# of the session, or HTTP 503 while no replica can take a visitor
redirect_to_replica <- function(group, route, method, query_string, req, config, template_manager = NULL) {
  replica <- choose_replica(config, group)
  if (is.null(replica)) {
    logger::log_warn("No replica of app {name} is available", name = group$name)
    return(as_starting_page(
      create_503_response(sprintf("No replica of app '%s' is available, please retry", group$name), 2),
      req, method, group$name, template_manager, 2
    ))
  }
  logger::log_debug("Sending a visitor of app {name} to replica {replica}", name = group$name, replica = replica)
  path <- if (route$backend_path == "") "/" else route$backend_path
  response <- create_redirect_response(
    paste0(config$config$base_path %||% "", "/proxy/", replica, path),
    query_string
  )
  # Each visit chooses again; a cached redirect would send every visit of a
  # browser to the same replica, whatever its load
  response$headers[["Cache-Control"]] <- "no-store"
  response
}

# The configured apps as the landing page shows them: one entry per replica
# group, under its logical name, in place of its replicas
public_apps <- function(apps) {
  shown <- list()
  for (app in apps) {
    if (is.null(app$replica_of)) {
      shown <- c(shown, list(app))
    } else if (!app$replica_of %in% vapply(shown, function(a) a$name, character(1))) {
      shown <- c(shown, list(utils::modifyList(app, list(name = app$replica_of))))
    }
  }
  shown
}

# The app statuses of /api/apps as the landing page shows them: a group is
# running if any replica is, and counts the connections of all of them
public_app_statuses <- function(config, statuses) {
  shown <- list()
  for (status in statuses) {
    group <- config$get_app_config(status$name)$replica_of
    if (is.null(group)) {
      shown[[status$name]] <- status
      next
    }
    members <- Filter(function(s) identical(config$get_app_config(s$name)$replica_of, group), statuses)
    member_status <- vapply(members, function(s) s$status, character(1))
    best <- intersect(c("running", "dormant", "stopped", "crashed", "unavailable"), member_status)[[1]]
    shown[[group]] <- list(
      name = group,
      status = best,
      resident = status$resident,
      connections = sum(vapply(members, function(s) s$connections, numeric(1)))
    )
  }
  shown[order(names(shown))]
}
