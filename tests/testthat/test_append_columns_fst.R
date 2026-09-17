context("column append")

append_bytes <- function(path) readBin(path, "raw", n = file.info(path)$size)

test_that("repeated appends preserve original bytes and allow reordered partial reads", {
  path <- tempfile(fileext = ".fst")
  on.exit(unlink(path))
  set.seed(113)
  x <- data.frame(a = sample(c(NA_integer_, 0:100), 20001, TRUE), b = rnorm(20001))
  for (compression in c(0, 50, 100)) {
    write_fst(x, path, compress = compression)
    before <- append_bytes(path)
    y <- data.frame(c = sample(c(TRUE, FALSE, NA), nrow(x), TRUE))
    expect_identical(append_columns_fst(y, path, compress = compression), y)
    after <- append_bytes(path)
    expect_identical(after[49:length(before)], before[49:length(before)])
    z <- data.frame(d = rep(c("a", "é", NA), length.out = nrow(x)))
    append_columns_fst(z, path, compress = compression)
    expected <- cbind(x, y, z)
    expect_identical(read_fst(path), expected)
    expect_identical(metadata_fst(path)$columnNames, names(expected))
    actual <- read_fst(path, c("d", "a", "c"), 2040, 8200)
    selected <- expected[2040:8200, c("d", "a", "c")]
    rownames(selected) <- NULL
    expect_identical(actual, selected)
  }
})

test_that("all supported R column types and annotations survive append", {
  skip_if_not_installed("bit64")
  path <- tempfile()
  on.exit(unlink(path))
  x <- data.frame(id = 1:5)
  y <- data.frame(
    int = c(NA_integer_, -1L, 0L, 1L, .Machine$integer.max),
    real = c(NA_real_, NaN, Inf, -Inf, pi),
    chr = c(NA, "", "é", "hello", "世界"),
    fac = factor(c("b", NA, "a", "b", "a"), levels = c("a", "b", "unused")),
    ord = ordered(c("b", NA, "a", "b", "a")),
    log = c(TRUE, NA, FALSE, TRUE, FALSE), raw = as.raw(0:4),
    date = as.Date("2020-01-01") + 0:4,
    time = as.POSIXct("2020-01-01", tz = "UTC") + 0:4,
    duration = as.difftime(0:4, units = "hours"),
    big = bit64::as.integer64(c("9223372036854775807", "-12345678901234", NA, "0", "1")))
  for (compression in c(0, 50, 100)) {
    write_fst(x, path)
    append_columns_fst(y, path, compress = compression, uniform_encoding = TRUE)
    expect_identical(read_fst(path), cbind(x, y))
  }
})

test_that("empty rows and data.table keys work", {
  path <- tempfile()
  on.exit(unlink(path))
  write_fst(data.frame(a = integer()), path)
  append_columns_fst(data.frame(b = character(), c = double()), path)
  expect_identical(read_fst(path), data.frame(a = integer(), b = character(), c = double()))
  skip_if_not_installed("data.table")
  for (key in list("id", c("id", "value"))) {
    x <- data.table::data.table(id = rep(1:5, each = 2), value = 1:10)
    data.table::setkeyv(x, key)
    write_fst(x, path)
    append_columns_fst(data.frame(lib = 11:20), path)
    expect_identical(metadata_fst(path)$keys, key)
    y <- read_fst(path, as.data.table = TRUE)
    expect_identical(data.table::key(y), key)
    expect_identical(y$lib, 11:20)
    expect_identical(y$id, x$id)
  }
})

test_that("invalid requests leave the original table readable", {
  path <- tempfile()
  on.exit(unlink(path))
  x <- data.frame(a = 1:3)
  write_fst(x, path)
  before <- append_bytes(path)
  expect_error(append_columns_fst(data.frame(b = 1:2), path), "same number")
  expect_error(append_columns_fst(x, path), "names")
  bad <- data.frame(b = 1:3, c = 1:3)
  names(bad) <- c("b", "b")
  expect_error(append_columns_fst(bad, path), "names")
  names(bad) <- c("", NA)
  expect_error(append_columns_fst(bad, path), "names")
  expect_error(append_columns_fst(data.frame(), path), "at least one")
  for (value in list(NA, numeric(), c(1, 2), -1, 101, Inf, "50")) {
    expect_error(append_columns_fst(data.frame(b = 1:3), path, compress = value), "compress")
  }
  for (value in list(NA, logical(), c(TRUE, FALSE), 1)) {
    expect_error(append_columns_fst(data.frame(b = 1:3), path, uniform_encoding = value), "uniform_encoding")
  }
  expect_identical(append_bytes(path), before)
  expect_error(append_columns_fst(data.frame(b = 1:3, bad = complex(3)), path), "type|Type")
  expect_identical(read_fst(path), x)
  append_columns_fst(data.frame(c = 4:6), path)
  expect_identical(read_fst(path), data.frame(a = 1:3, c = 4:6))
})

test_that("appended format is marked and ordinary export remains version 1", {
  path <- tempfile()
  export <- tempfile()
  on.exit(unlink(c(path, export)))
  version <- function(p) {
    con <- file(p, "rb"); on.exit(close(con)); seek(con, 24)
    readBin(con, "integer", n = 1, size = 4, endian = "little")
  }
  write_fst(data.frame(a = 1:3), path)
  expect_identical(version(path), 1L)
  append_columns_fst(data.frame(b = 4:6), path)
  expect_identical(version(path), 2L)
  write_fst(read_fst(path), export)
  expect_identical(version(export), 1L)
  expect_identical(read_fst(export), read_fst(path))
})

test_that("names preserve Unicode and compare across encodings", {
  path <- tempfile()
  on.exit(unlink(path))
  original <- data.frame(a = 1:3)
  names(original) <- enc2utf8("café")
  write_fst(original, path)
  same_name <- data.frame(a = 4:6)
  names(same_name) <- iconv("café", from = "UTF-8", to = "latin1")
  expect_error(append_columns_fst(same_name, path), "names")
  new <- data.frame(a = c("a", "b", NA))
  names(new) <- enc2utf8("新文庫")
  append_columns_fst(new, path, uniform_encoding = FALSE)
  expect_identical(read_fst(path), cbind(original, new))
})

test_that("zero-column files accept empty columns and fst objects can read appends", {
  path <- tempfile()
  on.exit(unlink(path))
  write_fst(data.frame(), path)
  append_columns_fst(data.frame(a = integer()), path)
  expect_identical(read_fst(path), data.frame(a = integer()))
  write_fst(data.frame(a = 1:3), path)
  append_columns_fst(data.frame(b = 4:6), path)
  expect_identical(as.data.frame(fst(path)), data.frame(a = 1:3, b = 4:6))
})

test_that("row selectors are not narrowed to 32-bit integers", {
  path <- tempfile()
  on.exit(unlink(path))
  write_fst(data.frame(a = 1:3), path)
  expect_error(read_fst(path, from = 2^31 + 1), "out of range")
  expect_identical(read_fst(path, to = 2^31 + 1), data.frame(a = 1:3))
  expect_error(read_fst(path, from = 2^53 + 2), "numerical")
})
