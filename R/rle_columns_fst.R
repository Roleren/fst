#' Write or append integer columns straight from run-length encoded data
#'
#' Each column is the window \code{from:to} (1-based, inclusive) of a run-length encoded vector,
#' given as its run values and run lengths (e.g. \code{runValue()} / \code{runLength()} of an
#' S4Vectors \code{Rle}). Columns are decoded one at a time into a single reused buffer and
#' compressed directly, so the full table is never built in memory: for wide tables of long
#' columns this is several times faster than decoding to a data.frame and calling
#' \code{write_fst()} / \code{append_columns_fst()}, and produces the same file content.
#'
#' Values are converted like \code{as.integer()} (doubles truncated towards zero; NA, NaN and
#' out-of-range values become \code{NA}).
#'
#' @param values List of numeric or integer vectors: run values, one element per column.
#' @param lengths List of integer vectors: run lengths, parallel to \code{values}.
#' @param names Character vector of unique, non-empty column names.
#' @param from,to Window of positions (1-based, inclusive) to store; \code{to - from + 1} rows.
#' @param path Path of the fst file to create (\code{write_rle_columns_fst}) or append to
#'   (\code{append_rle_columns_fst}; same rules as \code{\link{append_columns_fst}}).
#' @param compress Compression level, from 0 to 100.
#' @param uniform_encoding Passed through for column names.
#' @return Invisibly, \code{path}.
#' @export
#' @examples
#' path <- tempfile(fileext = ".fst")
#' write_rle_columns_fst(list(c(0, 3, 0), c(1L, 2L)), list(c(2L, 3L, 5L), c(4L, 6L)),
#'                       c("lib1", "lib2"), from = 2, to = 9, path = path)
#' read_fst(path)
#' unlink(path)
write_rle_columns_fst <- function(values, lengths, names, from, to, path, compress = 50, uniform_encoding = TRUE) {
  check_rle_args(values, lengths, names, from, to, path, compress)
  result <- fstwriterle(path.expand(path), values, lengths, names, as.numeric(from), as.numeric(to),
                        as.integer(compress), uniform_encoding)
  if (inherits(result, "fst_error")) stop(result)
  invisible(path)
}

#' @rdname write_rle_columns_fst
#' @export
append_rle_columns_fst <- function(values, lengths, names, from, to, path, compress = 50, uniform_encoding = TRUE) {
  check_rle_args(values, lengths, names, from, to, path, compress)
  result <- fstappendrle(normalizePath(path, mustWork = TRUE), values, lengths, names, as.numeric(from),
                         as.numeric(to), as.integer(compress), uniform_encoding)
  if (inherits(result, "fst_error")) stop(result)
  invisible(path)
}

check_rle_args <- function(values, lengths, names, from, to, path, compress) {
  if (!is.character(path) || length(path) != 1L || is.na(path) || !nzchar(path))
    stop("Please specify a single, non-empty path.")
  if (!is.list(values) || !is.list(lengths) || length(values) != length(lengths) || length(values) == 0L)
    stop("values and lengths must be non-empty lists of equal length.")
  if (!is.character(names) || length(names) != length(values))
    stop("names must be a character vector with one name per column.")
  if (!is.numeric(from) || !is.numeric(to) || length(from) != 1L || length(to) != 1L)
    stop("from and to must be single numbers.")
  if (!is.numeric(compress) || length(compress) != 1L || is.na(compress) || compress < 0 || compress > 100)
    stop("Parameter compress must be a single number between 0 and 100.")
  invisible(TRUE)
}
