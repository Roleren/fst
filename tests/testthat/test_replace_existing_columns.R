context("replace existing columns")

replacement_bytes <- function(path) readBin(path, "raw", file.info(path)$size)

test_that("named data.table replacements preserve column order and untouched bytes", {
  skip_if_not_installed("data.table")
  path <- tempfile(fileext = ".fst"); on.exit(unlink(path))
  x <- data.frame(a = letters[1:3], b = letters[4:6], c = letters[7:9])
  for (compression in c(0, 50, 100)) {
    write_fst(x, path)
    before <- replacement_bytes(path)
    new <- data.table::data.table(b = c("a", "b", "c"))
    expect_identical(replace_existing_columns(path, new, compress = compression), new)
    expected <- x; expected$b <- new$b
    expect_identical(read_fst(path), expected)
    after <- replacement_bytes(path)
    expect_identical(after[49:length(before)], before[49:length(before)])
    new <- data.table::data.table(c = c("z", NA, ""), a = c("x", "y", "é"))
    replace_existing_columns(path, new, compress = compression)
    expected$c <- new$c; expected$a <- new$a
    expect_identical(read_fst(path), expected)
    expect_identical(metadata_fst(path)$columnNames, names(x))
    expect_identical(read_fst(path, c("c", "b"), 2, 3),
      structure(expected[2:3, c("c", "b")], row.names = c(NA_integer_, -2L)))
  }
})

test_that("all validation is completed before any bytes are changed", {
  path <- tempfile(); on.exit(unlink(path))
  x <- data.frame(a = letters[1:3], b = letters[4:6], c = letters[7:9])
  write_fst(x, path); before <- replacement_bytes(path)
  reject <- function(value, pattern, ...) {
    expect_error(replace_existing_columns(path, value, ...), pattern)
    expect_identical(replacement_bytes(path), before)
    expect_identical(read_fst(path), x)
  }
  reject(data.frame(b = c(1, 2, 3)), "types")
  reject(data.frame(d = c("1", "2", "3")), "does not exist")
  reject(list(a = letters[1:3], b = 1:3), "types")
  reject(list(a = letters[1:3], d = letters[1:3]), "does not exist")
  reject(list(b = "a"), "same number of rows")
  reject(list(b = letters[1:4]), "same number of rows")
  reject(list(b = character()), "same number of rows")
  reject(list(b = letters[1:3], b = letters[1:3]), "unique")
  reject(setNames(list(letters[1:3]), ""), "names")
  reject(setNames(list(letters[1:3]), NA_character_), "names")
  reject(unname(list(letters[1:3])), "names")
  reject(list(b = matrix(letters[1:3], 3)), "dimensions")
  reject(list(b = as.list(letters[1:3])), "atomic")
  reject(list(b = complex(3)), "types")
  reject(list(), "non-empty")
  for (v in list(NA, numeric(), c(1, 2), -1, 101, Inf, "50")) reject(x, "compress", compress = v)
  for (v in list(NA, logical(), c(TRUE, FALSE), 1)) reject(x, "uniform_encoding", uniform_encoding = v)
  missing <- tempfile()
  expect_error(replace_existing_columns(missing, x))
  expect_false(file.exists(missing))
})

test_that("replacement handles every R column type and enforces schema attributes", {
  skip_if_not_installed("bit64")
  path <- tempfile(); on.exit(unlink(path))
  x <- data.frame(i = c(NA_integer_, 1L, -2L), d = c(NaN, Inf, -Inf),
    l = c(TRUE, FALSE, NA), r = as.raw(1:3), s = c("é", "世界", NA),
    f = factor(c("a", "b", NA), levels = c("a", "b", "unused")),
    o = ordered(c("b", "a", NA)), empty = factor(rep(NA_character_, 3)),
    date = as.Date("2020-01-01") + 0:2,
    time = as.POSIXct("2020-01-01", tz = "UTC") + 0:2,
    duration = as.difftime(0:2, units = "hours"),
    big = bit64::as.integer64(c("9223372036854775807", NA, "-12345678901234")))
  for (compression in c(0, 50, 100)) {
    write_fst(x, path)
    y <- x[3:1, ]; rownames(y) <- NULL
    replace_existing_columns(path, y[rev(names(y))], compress = compression)
    expect_identical(read_fst(path), y)
    before <- replacement_bytes(path)
    expect_error(replace_existing_columns(path, list(i = as.double(y$i))), "types")
    expect_error(replace_existing_columns(path, list(d = 1:3)), "types")
    expect_error(replace_existing_columns(path, list(date = as.double(y$date))), "types")
    expect_error(replace_existing_columns(path, list(f = factor(y$f, levels = c("b", "a", "unused")))), "levels")
    expect_error(replace_existing_columns(path, list(o = factor(y$o, ordered = FALSE))), "types")
    value <- y$time; attr(value, "tzone") <- "Europe/Oslo"
    expect_error(replace_existing_columns(path, list(time = value)), "timezones")
    value <- y$duration; attr(value, "units") <- "secs"
    expect_error(replace_existing_columns(path, list(duration = value)), "types")
    expect_identical(replacement_bytes(path), before)
  }
  if (requireNamespace("nanotime", quietly = TRUE)) {
    x <- data.frame(n = nanotime::nanotime(c(0, 1, NA_real_)))
    write_fst(x, path); replace_existing_columns(path, x)
    expect_identical(read_fst(path), x)
  }
})

test_that("replacement interoperates with row and column appends in every format", {
  path <- tempfile(); export <- tempfile(); on.exit(unlink(c(path, export)))
  for (version in 1:3) {
    x <- data.frame(a = 1:4097, b = rep(c("a", NA), length.out = 4097))
    write_fst(x, path)
    if (version >= 2) {
      append_columns_fst(data.frame(c = as.double(x$a)), path); x$c <- as.double(x$a)
    }
    if (version == 3) { append_rows_fst(x, path); x <- rbind(x, x) }
    y <- list(b = rep("new", nrow(x)), a = rev(x$a))
    replace_existing_columns(path, y)
    x$b <- y$b; x$a <- y$a
    expect_identical(read_fst(path), x)
    batch <- x[1:5, ]; append_rows_fst(batch, path); x <- rbind(x, batch)
    append_columns_fst(data.frame(extra = rep(TRUE, nrow(x))), path); x$extra <- TRUE
    replace_existing_columns(path, list(b = rep("again", nrow(x))))
    x$b <- "again"
    expect_identical(read_fst(path), x)
    expect_identical(read_fst(path, c("b", "a"), 4090, 4100),
      structure(x[4090:4100, c("b", "a")], row.names = c(NA_integer_, -11L)))
    write_fst(read_fst(path), export)
    expect_identical(read_fst(export), x)
  }
})

test_that("key replacement drops the key and other replacements preserve it", {
  skip_if_not_installed("data.table")
  path <- tempfile(); on.exit(unlink(path))
  x <- data.table::data.table(a = 1:3, b = letters[1:3], key = "a,b")
  for (version in 1:2) {
    write_fst(x, path)
    if (version == 2) append_columns_fst(data.frame(c = 1:3), path)
    replace_existing_columns(path, list(b = rev(x$b)))
    expect_null(metadata_fst(path)$keys)
    expect_null(data.table::key(read_fst(path, as.data.table = TRUE)))
  }
  data.table::setkeyv(x, "a"); write_fst(x, path)
  replace_existing_columns(path, list(b = rev(x$b)))
  expect_identical(metadata_fst(path)$keys, "a")
  expect_identical(data.table::key(read_fst(path, as.data.table = TRUE)), "a")
  replace_existing_columns(path, list(a = 3:1))
  expect_null(metadata_fst(path)$keys)
  expect_identical(read_fst(path)$a, 3:1)
})

test_that("zero-row replacements validate schema without writing", {
  path <- tempfile(); on.exit(unlink(path))
  x <- data.frame(a = integer(), b = character())
  write_fst(x, path); before <- replacement_bytes(path)
  replace_existing_columns(path, list(b = character()))
  expect_identical(replacement_bytes(path), before)
  expect_error(replace_existing_columns(path, list(a = double())), "types")
  expect_identical(replacement_bytes(path), before)
})

test_that("Unicode names match across encodings without positional replacement", {
  path <- tempfile(); on.exit(unlink(path))
  x <- data.frame(a = 1:3, b = letters[1:3]); names(x) <- c("café", "文庫")
  write_fst(x, path)
  y <- setNames(list(3:1), iconv("café", from = "UTF-8", to = "latin1"))
  replace_existing_columns(path, y)
  x[[1]] <- 3:1
  expect_identical(read_fst(path), x)
  y <- setNames(list(1:3, 3:1), c(enc2utf8("café"), names(y)))
  expect_error(replace_existing_columns(path, y), "unique")
})
