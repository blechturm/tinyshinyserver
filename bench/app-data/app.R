# Shared-data benchmark app: the same large dataset held in one of three ways,
# chosen by the environment variable BENCH_DATA_MODE:
#
#   memory  every process reads its own copy from an RDS file (today's default)
#   mori    every process maps one copy in shared memory, whose name a data
#           owner process wrote to BENCH_MORI_NAME_FILE (see share-data.R)
#   duckdb  every process opens one DuckDB file read-only, with one thread
#           and a small memory limit, and queries only what it needs
#
# Operations, answered as in bench/app/app.R ("<id>|<pid>|<token>|..."):
#   fast   cheap reactive calculation
#   query  filter one category and aggregate: touches a slice of the data

library(shiny)

mode <- Sys.getenv("BENCH_DATA_MODE", "memory")
data_dir <- Sys.getenv("BENCH_DATA_DIR", "/data")
started <- proc.time()[["elapsed"]]

if (mode == "memory") {
  data <- readRDS(file.path(data_dir, "data.rds"))
} else if (mode == "mori") {
  name_file <- Sys.getenv("BENCH_MORI_NAME_FILE", file.path(data_dir, "mori-name"))
  data <- mori::map_shared(readLines(name_file, n = 1))
} else if (mode == "duckdb") {
  con <- DBI::dbConnect(duckdb::duckdb(), file.path(data_dir, "data.duckdb"), read_only = TRUE,
    config = list(threads = "1", memory_limit = Sys.getenv("BENCH_DUCKDB_MEMORY", "128MB")))
  onStop(function() DBI::dbDisconnect(con, shutdown = TRUE))
}
load_seconds <- proc.time()[["elapsed"]] - started
message(sprintf("data mode %s loaded in %.2f s", mode, load_seconds))

query <- function(category) {
  if (mode == "duckdb") {
    r <- DBI::dbGetQuery(con, "SELECT count(*) AS n, avg(x) AS mx, sum(y) AS sy FROM data WHERE category = ?",
      params = list(category))
    c(r$n, r$mx, r$sy)
  } else {
    rows <- data$category == category
    c(sum(rows), mean(data$x[rows]), sum(data$y[rows]))
  }
}

answer <- function(id, session, ...) paste(c(id, Sys.getpid(), session$token, ...), collapse = "|")

ui <- fluidPage(
  tags$h3("Shared-data benchmark app"),
  tags$p("Process ", tags$code(Sys.getpid()), ", data mode ", tags$code(mode),
    ", session ", textOutput("session_id", inline = TRUE)),
  textOutput("fast_out"), textOutput("query_out")
)

server <- function(input, output, session) {
  output$session_id <- renderText(session$token)
  output$fast_out <- renderText({
    req(input$fast)
    answer(input$fast, session, sum(seq_len(1000)))
  })
  output$query_out <- renderText({
    req(input$query)
    parts <- strsplit(input$query, ":", fixed = TRUE)[[1]]
    answer(parts[[1]], session, paste(round(query(as.integer(parts[[2]])), 3), collapse = ","))
  })
  for (id in c("session_id", "fast_out", "query_out")) outputOptions(output, id, suspendWhenHidden = FALSE)
}

shinyApp(ui, server)
