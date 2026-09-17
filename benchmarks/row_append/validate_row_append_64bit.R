.libPaths(c(file.path(normalizePath("."), "R-library"), .libPaths()))
library(fst)
threads_fst(4)
path <- tempfile(tmpdir = "benchmarks", fileext = ".fst")
tryCatch({
  n <- 2^29
  batch <- list(value = raw(n))
  batch$value[1] <- as.raw(11); batch$value[n] <- as.raw(22)
  write_fst(as.data.frame(batch), path)
  for (i in 1:3) append_rows_fst(batch, path)
  tail <- list(value = as.raw(1:16))
  append_rows_fst(tail, path)
  stopifnot(metadata_fst(path)$nrOfRows == 2^31 + 16)
  stopifnot(identical(read_fst(path, from = 2^31, to = 2^31 + 16)$value,
    c(as.raw(22), tail$value)))
  stopifnot(identical(read_fst(path, from = 2^31 - 1, to = 2^31 + 1)$value,
    as.raw(c(0, 22, 1))))
  cat("64-bit segment offsets and reads crossing 2^31: PASS\n")
  rm(batch); gc(FALSE)
  full <- read_fst(path)
  stopifnot(inherits(full, "data.table_long"), length(full$value) == 2^31 + 16,
    identical(tail$value, tail(full$value, 16)))
  cat("Full", length(full$value), "row read into data.table_long: PASS\n")
  cat("File bytes:", file.info(path)$size, "\n")
}, finally = unlink(path))
