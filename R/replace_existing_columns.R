#' Replace existing fst columns by name
#'
#' Writes replacement column payloads at the end of an existing fst file and
#' publishes updated metadata. Other column payloads are reused unchanged.
#'
#' @param path Path to an existing fst file.
#' @param x A data frame, data.table, or named list of atomic columns to replace.
#'   A restricted `data.table_long` is also accepted. Every name must already
#'   exist in the file, and every column must have exactly the file's row count.
#' @param compress Compression level for replacement payloads, from 0 to 100.
#' @param uniform_encoding Whether each replacement character column has uniform
#'   encoding.
#' @return Invisibly returns `x`.
#' @details
#' Column names are matched exactly (with encoding-aware comparison), without
#' partial matching. Names must be unique and non-empty in both the input and
#' the file. Input order may differ from file order; the file's column order and
#' row count do not change. Missing columns, extra rows, shorter columns, arrays,
#' and storage-type changes are errors. No recycling or coercion is performed:
#' integer and double columns are distinct, and neither can replace character.
#' Stored attributes must match, including factor levels and their order,
#' ordered-factor status, timestamp timezones, and time units.
#'
#' All supplied columns are validated before any bytes are written. Replacing
#' columns in a zero-row file is a schema-validating no-op. If any replaced
#' column belongs to the stored key, the entire key is dropped because sortedness
#' is not verified. Otherwise existing keys are preserved.
#'
#' Replacement works with original, column-appended, and row-appended files,
#' and can be followed by further row or column appends. Each replacement covers
#' all rows, replacing any previous row segments for that column. Files use this
#' fork's format 2, or remain format 3 when already segmented. Upstream fst cannot
#' read these formats. Old payloads remain as unreachable bytes, so repeated
#' replacement grows the file. A read/write export to a new file compacts it when
#' the table fits that export path's memory and row limits.
#'
#' A cooperative exclusive lock excludes other replacements and appenders using
#' this fork. Callers must also exclude ordinary readers and writers. New data
#' are flushed before root publication, but the root update is not crash-atomic
#' or power-loss durable. An I/O failure before publication can leave unreachable
#' bytes; a failure during publication can damage the header. Keep recoverable
#' inputs or backups. This operation is not a multi-file transaction.
#' @export
#' @examples
#' path <- tempfile(fileext = ".fst")
#' write_fst(data.frame(a = letters[1:3], b = letters[4:6], c = letters[7:9]), path)
#' replace_existing_columns(path, data.frame(b = c("a", "b", "c")))
#' read_fst(path)
#' # Replacing b with numbers, or supplying an unknown column d, raises an error.
#' unlink(path)
replace_existing_columns <- function(path, x, compress = 50, uniform_encoding = TRUE) {
  if (!is.character(path) || length(path) != 1L || is.na(path) || !nzchar(path)) {
    stop("Please specify a single, non-empty path.")
  }
  if (!is.list(x) || length(x) == 0L) {
    stop("Please supply a non-empty data frame or named list of replacement columns.")
  }
  if (!is.numeric(compress) || length(compress) != 1L || !is.finite(compress) || compress < 0 || compress > 100) {
    stop("Parameter compress must be a single number between 0 and 100.")
  }
  if (!is.logical(uniform_encoding) || length(uniform_encoding) != 1L || is.na(uniform_encoding)) {
    stop("Parameter uniform_encoding must be TRUE or FALSE.")
  }
  result <- fstreplacecolumns(normalizePath(path, mustWork = TRUE), x, as.integer(compress), uniform_encoding)
  if (inherits(result, "fst_error")) stop(result)
  invisible(x)
}
