# Replace columns by name

Implemented 2026-09-17 in fst 0.9.9.9002 and fstcore 0.10.0.9002.
Install fstcore first and then fst. Restart R if either package is already loaded.

```r
library(data.table)
file <- tempfile(fileext = ".fst")
fst::write_fst(data.table(a = letters[1:3], b = letters[4:6], c = letters[7:9]), file)

fst::replace_existing_columns(file, data.table(b = c("a", "b", "c")))
fst::read_fst(file)
#   a b c
# 1 a a g
# 2 b b h
# 3 c c i

# Both raise R errors without changing any bytes:
try(fst::replace_existing_columns(file, data.table(b = c(1, 2, 3))))
try(fst::replace_existing_columns(file, data.table(d = c("1", "2", "3"))))

# Multiple replacements can be supplied in any order.
fst::replace_existing_columns(file, data.table(c = c("x", "y", "z"), a = c("j", "k", "l")))
fst::read_fst(file) # file order remains a, b, c
unlink(file)
```

The API is `replace_existing_columns(path, x, compress = 50,
uniform_encoding = TRUE)`. It returns `x` invisibly and accepts data frames,
data.tables and named atomic-column lists, including `data.table_long`.

## Validation and semantics

- Every replacement name must exist. Names must be unique and nonempty in the
  file and input. Matching is exact and encoding-aware, with no partial matching.
- Every supplied vector must have exactly the stored row count. No recycling,
  insertion, deletion, type conversion or row reordering is performed.
- Stored types and attributes must match. Integer and double are distinct.
  Factor levels/order, ordered-factor status, timezones and time units must match.
  A numeric vector cannot replace character, even if coercion would be possible.
- Arrays, matrices, list columns, unknown names and an empty replacement list
  are rejected. A schema-valid replacement in a zero-row file is a no-op.
- All supplied columns are validated before writing. One invalid replacement
  rejects the entire request and leaves the file byte-for-byte unchanged.
- Replacing a stored key column drops the entire key because sortedness is not
  checked. Replacing only non-key columns preserves the key.

## Implementation and practical limits

The writer appends new payloads only for the supplied columns. It writes new
metadata retaining the other payload offsets and publishes the new 48-byte root
header after flushing. Column count, order and row count stay the same. Existing
bytes after the root header are preserved, including old replaced payloads.
Repeated replacements therefore grow the file; they do not securely erase old
values. A read/write export to another file compacts it when the table fits that
export path's memory and row limits.

For segmented files, each replacement becomes one segment spanning all current
rows; other columns retain their existing segments. Replacements interoperate
with both row and column appends. No new format version is needed: original
files become format 2; existing format-3 files remain format 3. The previous
row-append reader (fstcore 0.10.0.9001) successfully reads the results. Upstream
fst lacks support for these fork formats; ordinary export still writes format 1.

The same cooperative exclusive lock covers append and replacement. Ordinary
readers and writers must be excluded by the caller. Publication is **not
crash-atomic or power-loss durable**: an I/O failure before publication preserves
the committed table but can leave orphaned bytes; a failure during root overwrite
can damage the header. Keep recoverable input data or backups. There are no
multi-file transactions. Windows and server/network filesystem behavior have
not been validated in this local Linux run.

## Validation

- New public replacement tests: 151 passing checks.
- Complete fst suite: 1,228 passing checks; fstcore: 85 passing checks, with no
  failures or warnings. Four existing tests skipped under `NOT_CRAN=false`
  (two lint tests, legacy fixture test and legacy giant-vector test).
- Coverage includes the example above, mixed valid/invalid requests, unchanged
  bytes after rejection, unchanged old payloads after success, all exposed R
  column types, schema attributes, compression 0/50/100, Unicode names, keys,
  empty files, partial reads, reordered replacements, format 1/2/3 input and
  alternating replacement/row append/column append.
- External tests exercise lock exclusion and injected file-size-limit failures
  on ordinary and segmented files. The old table survives, and a subsequent
  replacement and compact export succeed. Results are also read with the
  previously installed fstcore 0.10.0.9001 reader.
- A real 2^31 + 16 row raw column is replaced from a `data.table_long`, verified
  across the 2^31 boundary, and then extended by row append. This is a tested
  long-row path, not exhaustive validation of every column type at that size.

Sources: `R/replace_existing_columns.R`, `tests/testthat/test_replace_existing_columns.R`,
and fstcore's `src/flex_store.cpp` / `src/fstlib/interface/fststore.cpp`.
External validation scripts and logs are in the `fst_update_docs` workspace:
`benchmarks/validate_replacement_external.py`,
`benchmarks/validate_replacement_64bit.R`, and `test-replace-*.log`.
