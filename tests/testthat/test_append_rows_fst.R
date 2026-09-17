context("row append")

test_that("one row, one column append, and one row append work with data.table", {
  skip_if_not_installed("data.table")
  dt <- data.table::data.table(a = 1)
  file <- tempfile(fileext = ".fst")
  on.exit(unlink(file))
  fst::write_fst(dt, file)
  expect_identical(fst::read_fst(file), data.frame(a = 1))

  fst::append_columns_fst(data.table::data.table(b = 1), file)
  expect_identical(fst::read_fst(file), data.frame(a = 1, b = 1))

  fst::append_rows_fst(data.table::data.table(a = 2, b = 2), file)
  expect_identical(fst::read_fst(file), data.frame(a = c(1, 2), b = c(1, 2)))

  fst::replace_existing_columns(file, data.table::data.table(b = c(1, 3)))
  expect_identical(fst::read_fst(file), data.frame(a = c(1, 2), b = c(1, 3)))
})

row_bytes <- function(path) readBin(path, "raw", n = file.info(path)$size)
row_slice <- function(x, first, last, columns = names(x)) {
  x <- x[first:last, columns, drop = FALSE]
  rownames(x) <- NULL
  x
}

test_that("segments span codec boundaries and retain existing payload bytes", {
  path <- tempfile(); on.exit(unlink(path))
  set.seed(81)
  make <- function(n) data.frame(i = sample(c(NA_integer_, -5:20), n, TRUE),
    d = rnorm(n), s = rep(c("é", "世界", NA, ""), length.out = n),
    f = factor(rep(c("a", NA, "b"), length.out = n), levels = c("a", "b", "unused")),
    l = rep(c(TRUE, NA, FALSE), length.out = n), r = as.raw(seq_len(n) %% 256))
  for (compression in c(0, 50, 100)) {
    x <- make(0)
    write_fst(x, path, compress = compression)
    for (n in c(1, 2047, 2048, 4095, 4096, 4097, 16385)) {
      batch <- make(n); before <- row_bytes(path)
      expect_identical(append_rows_fst(batch, path, compress = compression), batch)
      after <- row_bytes(path)
      expect_identical(after[49:length(before)], before[49:length(before)])
      old <- nrow(x); x <- rbind(x, batch)
      expect_identical(read_fst(path), x)
      first <- max(1, old - 11); last <- min(nrow(x), old + 19)
      expect_identical(read_fst(path, c("s", "i", "f", "r"), first, last),
        row_slice(x, first, last, c("s", "i", "f", "r")))
    }
    for (i in seq_len(10)) {
      first <- sample.int(nrow(x), 1); last <- sample(first:nrow(x), 1)
      expect_identical(read_fst(path, from = first, to = last), row_slice(x, first, last))
    }
  }
})

test_that("row and column appends can alternate", {
  path <- tempfile(); export <- tempfile(); on.exit(unlink(c(path, export)))
  x <- data.frame(a = 1:4097)
  write_fst(x, path)
  append_columns_fst(data.frame(b = letters[(seq_len(nrow(x)) %% 26) + 1]), path)
  x <- read_fst(path)
  for (i in 1:3) {
    batch <- row_slice(x, 100, 217)
    append_rows_fst(batch, path); x <- rbind(x, batch)
    col <- setNames(data.frame(seq_len(nrow(x))), paste0("new", i))
    append_columns_fst(col, path); x <- cbind(x, col)
    expect_identical(read_fst(path), x)
  }
  expect_identical(as.data.frame(fst(path)), x)
  bytes <- row_bytes(path)
  expect_identical(readBin(bytes[25:28], "integer", size = 4, endian = "little"), 3L)
  write_fst(read_fst(path), export)
  expect_identical(readBin(row_bytes(export)[25:28], "integer", size = 4, endian = "little"), 1L)
  expect_identical(read_fst(export), x)
})

test_that("annotations and special values survive segmented reads", {
  skip_if_not_installed("bit64")
  path <- tempfile(); on.exit(unlink(path))
  x <- data.frame(i = c(NA_integer_, -1L, 0L, 1L, .Machine$integer.max),
    d = c(NA_real_, NaN, Inf, -Inf, pi),
    ordered = ordered(c("b", NA, "a", "b", "a")),
    empty_factor = factor(rep(NA_character_, 5)),
    date = as.Date("2020-01-01") + 0:4,
    time = as.POSIXct("2020-01-01", tz = "Europe/Oslo") + 0:4,
    duration = as.difftime(0:4, units = "hours"),
    big = bit64::as.integer64(c("9223372036854775807", "-12345678901234", NA, "0", "1")))
  for (compression in c(0, 50, 100)) {
    write_fst(x[FALSE, ], path)
    append_rows_fst(x, path, compress = compression)
    append_rows_fst(x, path, compress = compression)
    expect_identical(read_fst(path), rbind(x, x))
    expect_identical(read_fst(path, from = 4, to = 8), row_slice(rbind(x, x), 4, 8))
  }
})

test_that("empty append is a no-op and nonempty append drops keys", {
  skip_if_not_installed("data.table")
  path <- tempfile(); on.exit(unlink(path))
  x <- data.table::data.table(a = 1:3, b = letters[1:3], key = "a")
  write_fst(x, path); before <- row_bytes(path)
  append_rows_fst(x[0], path)
  expect_identical(row_bytes(path), before)
  expect_identical(metadata_fst(path)$keys, "a")
  append_rows_fst(x, path)
  expect_null(metadata_fst(path)$keys)
  actual <- read_fst(path, as.data.table = TRUE)
  expect_null(data.table::key(actual))
  expect_identical(as.data.frame(actual), rbind(as.data.frame(x), as.data.frame(x)))
  before <- row_bytes(path); append_rows_fst(x[0], path)
  expect_identical(row_bytes(path), before)
})

test_that("schema rejection leaves every byte unchanged", {
  path <- tempfile(); on.exit(unlink(path))
  x <- data.frame(a = 1:3, f = factor(c("a", "b", NA), levels = c("a", "b")),
    t = as.POSIXct("2020-01-01", tz = "UTC") + 1:3,
    d = as.difftime(1:3, units = "hours"))
  write_fst(x, path); before <- row_bytes(path)
  reject <- function(bad, ...) {
    expect_error(append_rows_fst(bad, path, ...))
    expect_identical(row_bytes(path), before)
  }
  reject(x[c(2, 1, 3, 4)])
  y <- x; names(y)[2] <- "a"; reject(y)
  y <- x; names(y)[1] <- NA_character_; reject(y)
  y <- x; y$a <- as.double(y$a); reject(y)
  y <- x; y$f <- factor(y$f, levels = c("b", "a")); reject(y)
  y <- x; attr(y$t, "tzone") <- "Europe/Oslo"; reject(y)
  y <- x; attr(y$d, "units") <- "secs"; reject(y)
  y <- as.list(x); y$a <- 1:2; reject(y)
  y <- as.list(x); y$a <- matrix(1:3, 3); reject(y)
  y <- as.list(x); y$a <- complex(3); reject(y)
  y <- as.list(x); y$a <- list(1, 2, 3); reject(y)
  reject(unname(as.list(x))); reject(list())
  for (v in list(NA, numeric(), c(1, 2), -1, 101, Inf, "50")) reject(x, compress = v)
  for (v in list(NA, logical(), c(TRUE, FALSE), 1)) reject(x, uniform_encoding = v)
  append_rows_fst(as.list(x), path)
  expect_identical(read_fst(path), rbind(x, x))
})

test_that("damaged and truncated segment manifests fail reads and appends", {
  path <- tempfile(); on.exit(unlink(path))
  x <- data.frame(a = 1:20)
  write_fst(x, path); append_rows_fst(x, path)
  original <- row_bytes(path)
  magic <- charToRaw("FSTROW01")
  hits <- which(original == magic[1])
  at <- hits[vapply(hits, function(i) i + 7 <= length(original) &&
    identical(original[i:(i + 7)], magic), logical(1))]
  expect_length(at, 1)
  # Flip a row count after the manifest header, leaving its checksum unchanged.
  bad <- original; bad[at + 40] <- as.raw(bitwXor(as.integer(bad[at + 40]), 1L))
  writeBin(bad, path)
  expect_error(read_fst(path), "manifest")
  expect_error(metadata_fst(path), "manifest")
  expect_error(append_rows_fst(x, path), "manifest")
  expect_identical(row_bytes(path), bad)
  writeBin(original[seq_len(at + 15)], path)
  expect_error(read_fst(path), "manifest")
})

test_that("nanotime and character encodings survive row segments", {
  path <- tempfile(); on.exit(unlink(path))
  latin <- iconv("café", from = "UTF-8", to = "latin1")
  x <- data.frame(s = rep(enc2utf8("café"), 5))
  names(x) <- enc2utf8("文庫")
  write_fst(x, path)
  y <- x; y[[1]] <- rep(latin, 5)
  append_rows_fst(y, path, uniform_encoding = FALSE)
  expect_identical(read_fst(path), rbind(x, y))
  skip_if_not_installed("nanotime")
  x <- data.frame(n = nanotime::nanotime(c(0, 1, NA_real_)))
  write_fst(x, path); append_rows_fst(x, path)
  expect_identical(read_fst(path), rbind(x, x))
})
