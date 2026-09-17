# Append rows without rewriting old data

This branch provides `append_rows_fst()` alongside `append_columns_fst()` for columns.
To replace existing columns by name, see [column replacement](COLUMN_REPLACEMENT.md).
It requires the matching `Roleren/fstcore` branch `feature/append-rows`
(fstcore >= 0.10.0.9002; fst >= 0.9.9.9003).

```r
library(data.table)
dt <- data.table(a = 1)
file <- tempfile(fileext = ".fst")
fst::write_fst(dt, file)

fst::append_columns_fst(data.table(b = 1), file)
fst::read_fst(file)
#   a b
# 1 1 1

fst::append_rows_fst(data.table(a = 2, b = 2), file)
fst::read_fst(file)
#   a b
# 1 1 1
# 2 2 2

fst::replace_existing_columns(file, data.table(b = c(1, 3)))
fst::read_fst(file)
#   a b
# 1 1 1
# 2 2 3

unlink(file)
```

Install fstcore first, then fst from their `feature/append-rows` branches. Use
`?append_rows_fst` for the complete API contract. Named lists of equal-length
atomic columns are accepted, including the restricted `data.table_long` format.

Names/order and stored types must match. Factors need identical dictionaries;
timezones and time units must match. Empty batches do nothing after validation.
Nonempty row appends drop stored keys because sorting is not checked.

Each new batch is compressed independently. A per-column segment index maps row
ranges to payloads, so reads span batches directly in their final output vectors.
Existing compressed bytes are preserved; row and column appends can alternate.
The format and implementation are documented in
[fstcore/ROW_APPEND.md](https://github.com/Roleren/fstcore/blob/feature/append-rows/ROW_APPEND.md).

Files require the fork's format-3 reader. Ordinary `write_fst()` exports format 1
when the table fits a regular R data frame. The append lock excludes cooperating
appenders, but callers must also exclude ordinary readers and writers. Root
publication is not crash-atomic or power-loss durable. Keep recoverable inputs.

Use substantial batches: the complete segment index is rewritten each time and
obsolete metadata accumulates. Many tiny appends need compaction; see the format
document for the growth formula. Performance depends on batch size, column count,
data distribution, compression, storage and cache state.

Reproducible benchmarks and the measured results are in `benchmarks/row_append/`.
