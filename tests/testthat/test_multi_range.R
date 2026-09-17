context("multiple row intervals")

selected_frame <- function(x, i, columns = names(x)) {
  result <- x[i, columns, drop = FALSE]; rownames(result) <- NULL; result
}

test_that("intervals preserve order, overlaps and duplicates for every column type", {
  skip_if_not_installed("bit64")
  path <- tempfile(); on.exit(unlink(path))
  n <- 20003
  x <- data.frame(i = rep(c(NA_integer_, -2L, 0L, 1L), length.out = n),
    d = rep(c(NA_real_, NaN, Inf, -Inf, pi), length.out = n),
    l = rep(c(TRUE, FALSE, NA), length.out = n), r = as.raw(seq_len(n) %% 256),
    s = rep(c("é", "世界", NA, ""), length.out = n),
    f = factor(rep(c("a", "b", NA), length.out = n), levels = c("a", "b", "unused")),
    o = ordered(rep(c("b", "a", NA), length.out = n)),
    empty = factor(rep(NA_character_, n)),
    date = as.Date("2020-01-01") + seq_len(n),
    time = as.POSIXct("2020-01-01", tz = "Europe/Oslo") + seq_len(n),
    duration = as.difftime(seq_len(n), units = "hours"),
    big = bit64::as.integer64(rep(c("9223372036854775807", NA, "-12345678901234"), length.out = n)))
  from <- c(16380, 1, 2040, 4090, 2040, 20000)
  to <- c(16390, 1, 2055, 4100, 2045, 30000)
  selected <- unlist(Map(seq.int, from, pmin(to, n)))
  for (compression in c(0, 50, 100)) {
    write_fst(x, path, compress = compression)
    for (gap in list(NULL, 0, 1000, 65536)) {
      expect_identical(read_fst(path, from = from, to = to, merge_gap = gap), selected_frame(x, selected))
      cols <- c("s", "i", "big", "f")
      expect_identical(read_fst(path, cols, from, to, merge_gap = gap), selected_frame(x, selected, cols))
    }
    expect_identical(read_fst(path, from = numeric(), to = numeric()), x[FALSE, ])
    expect_identical(fst(path)[numeric(), , drop = FALSE], x[FALSE, ])
    i <- seq(2, n, by = 2)
    expect_identical(fst(path)[i, , drop = FALSE], selected_frame(x, i))
    expect_identical(fst(path)[rev(c(i, 2, 2)), , drop = FALSE], selected_frame(x, rev(c(i, 2, 2))))
  }
})

test_that("selections cross row segments with different per-column layouts", {
  path <- tempfile(); on.exit(unlink(path))
  x <- data.frame(a = 1:4097, s = rep(c("a", NA, "é"), length.out = 4097))
  write_fst(x, path); append_rows_fst(x, path); x <- rbind(x, x)
  append_columns_fst(data.frame(b = as.double(seq_len(nrow(x)))), path)
  x$b <- as.double(seq_len(nrow(x)))
  batch <- x[1:2039, ]; append_rows_fst(batch, path); x <- rbind(x, batch)
  replace_existing_columns(path, list(a = rev(x$a))); x$a <- rev(x$a)
  from <- c(8190, 4090, 1, 10230, 4090); to <- c(8200, 4105, 2, 10233, 4098)
  i <- unlist(Map(seq.int, from, to))
  expect_identical(read_fst(path, from = from, to = to), selected_frame(x, i))
  expect_identical(fst(path)[i, c("b", "a", "s"), drop = FALSE], selected_frame(x, i, c("b", "a", "s")))
  expect_identical(read_fst(path, from = c(2, 9000), to = c(3, 9001))$a, x$a[c(2:3, 9000:9001)])
})

test_that("selection windows are bounded and handle long dense runs", {
  path <- tempfile(); on.exit(unlink(path))
  n <- 600007L
  x <- data.frame(i = seq_len(n), s = rep(c("a", NA, "é"), length.out = n))
  write_fst(x, path)
  i <- seq(2, n, by = 2)
  expect_identical(read_fst(path, from = i, to = i), selected_frame(x, i))
  # A large overlapping range plus short ranges must not grow scratch buffers.
  from <- c(1, 100, 500000); to <- c(n, 110, 500003)
  expect_identical(read_fst(path, from = from, to = to), selected_frame(x, unlist(Map(seq.int, from, to))))
})

test_that("key annotations follow the actual output order", {
  skip_if_not_installed("data.table")
  path <- tempfile(); on.exit(unlink(path))
  x <- data.table::data.table(a = 1:10, b = letters[1:10], key = "a")
  write_fst(x, path)
  ordered <- read_fst(path, from = c(2, 3, 8), to = c(3, 4, 9), as.data.table = TRUE)
  expect_identical(data.table::key(ordered), "a")
  expect_identical(ordered$a, c(2:3, 3:4, 8:9))
  for (from in list(c(8, 2), c(2, 3))) {
    result <- read_fst(path, from = from, to = c(9, 4), as.data.table = TRUE)
    expect_null(data.table::key(result))
  }
})

test_that("invalid endpoints fail without rounding, recycling or truncation", {
  path <- tempfile(); on.exit(unlink(path))
  write_fst(data.frame(a = 1:10), path)
  for (bad in list(NA_real_, NaN, Inf, -1, 0, 1.5, 2^53 + 2, "2")) {
    expect_error(read_fst(path, from = bad, to = 5))
    expect_error(read_fst(path, from = 1, to = bad))
    expect_error(read_fst(path, from = c(1, bad), to = c(2, 5)))
  }
  expect_error(read_fst(path, from = c(1, 5), to = 7))
  expect_error(read_fst(path, from = c(1, 5), to = NULL))
  expect_error(read_fst(path, from = c(1, 5), to = c(2, 4)))
  expect_error(read_fst(path, from = c(1, 11), to = c(2, 20)), "out of range")
  expect_error(fst(path)[c(1, NA), , drop = FALSE])
  expect_error(fst(path)[c(1, 1.5), , drop = FALSE])
  expect_identical(fst(path)[c(0, 2, 4), , drop = FALSE], data.frame(a = c(2L, 4L)))
  for (gap in list(-1, NA_real_, Inf, 0.5, c(1, 2), "2"))
    expect_error(read_fst(path, from = c(1, 3), to = c(1, 3), merge_gap = gap), "merge_gap")
})

test_that("zero-row originals support empty and multiple requests", {
  path <- tempfile(); on.exit(unlink(path))
  x <- data.frame(a = integer(), b = character(), f = factor(character(), levels = c("a", "b")))
  write_fst(x, path)
  expect_identical(read_fst(path, from = c(1, 5), to = c(2, 9)), x)
  expect_identical(fst(path)[integer(), , drop = FALSE], x)
})
