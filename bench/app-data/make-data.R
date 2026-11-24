# Write the shared-data benchmark's dataset in both forms:
#   Rscript make-data.R DIR [ROWS]
# DIR/data.rds     a data frame: category (integer, 1-100), x, y (double),
#                  z (integer); about 270 MB in memory with the default rows.
#                  Only numeric columns: mori maps them without copying,
#                  whereas character columns are materialised in each process
#                  that reads them.
# DIR/data.duckdb  the same table, named data

args <- commandArgs(trailingOnly = TRUE)
dir <- args[[1]]
rows <- if (length(args) > 1) as.numeric(args[[2]]) else 1e7
dir.create(dir, showWarnings = FALSE, recursive = TRUE)
set.seed(1)
data <- data.frame(
  category = sample.int(100, rows, replace = TRUE),
  x = rnorm(rows),
  y = runif(rows),
  z = sample.int(1e6, rows, replace = TRUE)
)
cat(sprintf("%.0f rows, %.0f MB in memory\n", rows, as.numeric(object.size(data)) / 1024^2))
saveRDS(data, file.path(dir, "data.rds"), compress = FALSE)
con <- DBI::dbConnect(duckdb::duckdb(), file.path(dir, "data.duckdb"))
DBI::dbWriteTable(con, "data", data, overwrite = TRUE)
DBI::dbDisconnect(con, shutdown = TRUE)
cat("written to", dir, "\n")
