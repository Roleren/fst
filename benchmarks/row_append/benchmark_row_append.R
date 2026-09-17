# From the report directory: Rscript benchmarks/benchmark_row_append.R rows cols new_rows type reps [append-only]
args <- commandArgs(TRUE)
rows <- as.integer(args[1]); columns <- as.integer(args[2]); added <- as.integer(args[3])
kind <- args[4]; repetitions <- as.integer(args[5]); mode <- if (length(args) > 5) args[6] else "compare"
root <- normalizePath(".")
.libPaths(c(file.path(root, "R-library"), .libPaths()))
library(fst)
threads_fst(4)
set.seed(20260916)
tag <- paste("rows", rows, columns, added, kind, mode, sep = "-")
work <- file.path(root, "benchmarks", paste0("data-", tag))
dir.create(work, recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(root, "results-row"), showWarnings = FALSE)
make_column <- function(n) {
  x <- if (kind == "integer") integer(n) else numeric(n)
  at <- sample.int(n, max(1L, as.integer(n * 0.01)))
  x[at] <- if (kind == "integer") sample.int(100L, length(at), TRUE) else runif(length(at), 0, 100)
  x
}
base <- file.path(work, "base.fst")
for (start in seq.int(1L, columns, by = 64L)) {
  ids <- start:min(start + 63L, columns)
  batch <- as.data.frame(setNames(lapply(ids, function(i) make_column(rows)), paste0("lib", ids)))
  if (start == 1L) write_fst(batch, base) else append_columns_fst(batch, base)
  rm(batch); gc(FALSE)
  if (start == 1L || max(ids) %% 512L == 0L || max(ids) == columns) {
    cat("Built", max(ids), "of", columns, "columns\n"); flush.console()
  }
}
new <- as.data.frame(setNames(lapply(seq_len(columns), function(i) make_column(added)), paste0("lib", seq_len(columns))))
base_size <- file.info(base)$size
records <- list()
for (rep in seq_len(repetitions)) {
  fast <- file.path(work, "append.fst"); old <- file.path(work, "rewrite.fst")
  stopifnot(file.copy(base, fast, overwrite = TRUE))
  methods <- if (mode == "append-only") "append" else if (rep %% 2L) c("rewrite", "append") else c("append", "rewrite")
  times <- numeric()
  for (method in methods) {
    gc(FALSE)
    if (method == "append") {
      elapsed <- system.time(append_rows_fst(new, fast))[["elapsed"]]
    } else {
      elapsed <- system.time({
        loaded <- read_fst(base)
        combined <- rbind(loaded, new)
        write_fst(combined, old)
      })[["elapsed"]]
      rm(loaded, combined)
    }
    times[method] <- elapsed
    cat(tag, "rep", rep, method, elapsed, "seconds\n"); flush.console()
  }
  stopifnot(metadata_fst(fast)$nrOfRows == rows + added)
  # Compare all values, bounding verification memory to 32 columns.
  for (start in seq.int(1L, columns, by = 32L)) {
    selected <- paste0("lib", start:min(start + 31L, columns))
    if (mode == "append-only") {
      stopifnot(identical(read_fst(fast, selected, to = rows), read_fst(base, selected)))
      stopifnot(identical(read_fst(fast, selected, from = rows + 1), new[selected]))
    } else stopifnot(identical(read_fst(fast, selected), read_fst(old, selected)))
  }
  # Warm reads of the same complete column subset: segmented versus compact.
  selected <- paste0("lib", seq_len(min(32L, columns)))
  gc(FALSE)
  read_segmented <- system.time(invisible(read_fst(fast, selected)))[["elapsed"]]
  gc(FALSE)
  read_compact <- if (mode == "append-only") NA_real_ else system.time(invisible(read_fst(old, selected)))[["elapsed"]]
  records[[rep]] <- data.frame(rows, columns, added_rows = added, kind, mode, repetition = rep,
    threads = threads_fst(), compression = 50, nonzero_fraction = 0.01,
    base_bytes = base_size, added_bytes = file.info(fast)$size - base_size,
    rewrite_bytes = if (mode == "append-only") NA_real_ else file.info(old)$size,
    rewrite_seconds = if (mode == "append-only") NA_real_ else times[["rewrite"]],
    append_seconds = times[["append"]],
    read_segmented_seconds = read_segmented, read_compact_seconds = read_compact,
    all_values_verified = TRUE)
  write.csv(do.call(rbind, records), file.path(root, "results-row", paste0(tag, ".csv")), row.names = FALSE)
  unlink(c(fast, old)); gc(FALSE)
}
writeLines(c(capture.output(sessionInfo()), paste("threads:", threads_fst())),
  file.path(root, "results-row", paste0(tag, "-session.txt")))
unlink(work, recursive = TRUE)
