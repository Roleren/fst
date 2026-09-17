#' Append rows to an existing fst file
#'
#' Writes new row segments and replacement metadata while preserving existing
#' compressed data. No old partial compression blocks are recompressed.
#'
#' @param x A data frame or named list of equal-length atomic columns. Names and
#'   their order, storage types, factor levels, timezones, and time units must
#'   match the file. A restricted `data.table_long` is also accepted.
#' @param path Path to an existing fst file.
#' @param compress Compression level for new rows, from 0 to 100.
#' @param uniform_encoding Whether each new character column has uniform encoding.
#' @return Invisibly returns `x`. An empty batch validates the schema and makes
#'   no changes to the file.
#' @details
#' Row-appended files require this fork's version 3 reader. Original fst files
#' and files produced by column append can be used directly. Row and column
#' appends can be alternated; each new column must cover the entire current row
#' count. Ordinary `write_fst()` still exports the upstream format.
#'
#' A non-empty row append drops stored keys because it does not verify that new
#' rows preserve sort order. Factor levels must be identical, including order;
#' implicit type coercion or factor-level merging is not performed. Batches
#' retain independent compressed payloads, so large batches are more efficient
#' than many tiny appends. Obsolete metadata can be removed by reading and
#' rewriting to another file.
#'
#' A cooperative lock excludes other appenders. Callers must also exclude other
#' readers and writers for the duration of the operation. The root header is
#' published after flushing new data, but publication is not crash-atomic or
#' power-loss durable. Keep recoverable input data or backups. Transactions do
#' not span multiple files. Network locking must be verified on the server.
#' @export
#' @examples
#' path <- tempfile(fileext = ".fst")
#' write_fst(data.frame(a = 1:3, b = letters[1:3]), path)
#' append_rows_fst(data.frame(a = 4:6, b = letters[4:6]), path)
#' read_fst(path, from = 3, to = 5)
#' unlink(path)
append_rows_fst <- function(x, path, compress = 50, uniform_encoding = TRUE) {
  if (!is.character(path) || length(path) != 1L || is.na(path) || !nzchar(path)) {
    stop("Please specify a single, non-empty path.")
  }
  if (!is.list(x) || length(x) == 0L) {
    stop("Please supply a non-empty data frame or named list of columns.")
  }
  if (!is.numeric(compress) || length(compress) != 1L || !is.finite(compress) || compress < 0 || compress > 100) {
    stop("Parameter compress must be a single number between 0 and 100.")
  }
  if (!is.logical(uniform_encoding) || length(uniform_encoding) != 1L || is.na(uniform_encoding)) {
    stop("Parameter uniform_encoding must be TRUE or FALSE.")
  }
  result <- fstappendrows(normalizePath(path, mustWork = TRUE), x, as.integer(compress), uniform_encoding)
  if (inherits(result, "fst_error")) stop(result)
  invisible(x)
}
