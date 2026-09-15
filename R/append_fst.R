#' Append new columns to an existing fst file
#'
#' Writes only the new columns and replacement metadata. Existing compressed
#' column data stays in place. Rows are matched by position: the caller must
#' ensure the new values have exactly the same row order as the stored data.
#'
#' @param x A data frame containing one or more new columns, with exactly as many
#'   rows as the file. Names must be unique, non-empty, and absent from the file.
#' @param path Path to an existing fst file.
#' @param compress Compression level for the new columns, from 0 to 100.
#' @param uniform_encoding Whether character columns have uniform encoding.
#' @return Invisibly returns `x`.
#' @details
#' This fork uses a format extension for appended files. They require this fork
#' of fstcore; upstream readers reject them with a version error. Ordinary
#' `write_fst()` files retain the upstream format. To export an appended file to
#' an upstream reader, read it with this fork and write it to a different path
#' using `write_fst()`.
#'
#' Existing data.table keys are preserved; keys on `x` are ignored. Appends leave
#' obsolete metadata in the file. Reading and rewriting compacts this metadata.
#'
#' Appenders use a non-blocking cooperative file lock. Other readers and writers
#' must be excluded by the caller for the duration of an append, including on
#' network filesystems where lock support must be verified. The new header is
#' published after flushing the new data, but replacement of the header is not
#' crash-atomic or power-loss durable. Keep recoverable source data or backups.
#' @export
#' @examples
#' path <- tempfile(fileext = ".fst")
#' write_fst(data.frame(lib1 = 1:3), path)
#' append_fst(data.frame(lib2 = c(0L, 4L, 2L)), path)
#' read_fst(path)
#' unlink(path)
append_fst <- function(x, path, compress = 50, uniform_encoding = TRUE) {
  if (!is.character(path) || length(path) != 1L || is.na(path) || !nzchar(path)) {
    stop("Please specify a single, non-empty path.")
  }
  if (!is.data.frame(x) || ncol(x) == 0L) {
    stop("Please supply a data frame with at least one new column.")
  }
  if (!is.numeric(compress) || length(compress) != 1L || is.na(compress) ||
      !is.finite(compress) || compress < 0 || compress > 100) {
    stop("Parameter compress must be a single number between 0 and 100.")
  }
  if (!is.logical(uniform_encoding) || length(uniform_encoding) != 1L || is.na(uniform_encoding)) {
    stop("Parameter uniform_encoding must be TRUE or FALSE.")
  }
  result <- fstappend(normalizePath(path, mustWork = TRUE), x, as.integer(compress), uniform_encoding)
  if (inherits(result, "fst_error")) stop(result)
  invisible(x)
}
