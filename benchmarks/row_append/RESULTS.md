# On-disk row append: implementation and benchmarks

Date: 2026-09-16. Implemented in `Roleren/fstcore` and `Roleren/fst`, both on
branch `feature/append-rows`, based on the column-append branches.

## Use

```r
library(fst)
append_rows_fst(new_rows, "chromosome_chunk.fst", compress = 50)

# Reads can cross any number of appended batches.
read_fst("chromosome_chunk.fst", columns = c("lib1", "lib2"),
         from = 1999990, to = 2000020)
```

Install the matching fstcore first (0.10.0.9001), then fst (0.9.9.9001).
The validated local installation is in this directory's `R-library`:

```r
.libPaths(c("/media/roler/S/data/Bio_data/projects/fst_update_docs/R-library", .libPaths()))
library(fst)
```

Every appended column must have the same number of new rows. Column names and
order, storage types, factor levels/order, timezones and time units must match
the stored schema. Named atomic-column lists and `data.table_long` are accepted.
There is no implicit coercion. Empty batches validate the schema without writing.
Nonempty row appends drop stored keys because sortedness is not checked.

Row and column append can alternate. A subsequently appended library column
must cover the entire current row count. ORFik must keep its own genomic row
mapping consistent; this change supplies the storage API, not an ORFik workflow
change.

## How it works

This implements the saved design's independently compressed row batches, using
a manifest rather than a linked chain. Each column has a list of triples:
`(first row, number of rows, absolute payload offset)`.

1. Lock the file and validate its metadata and the new batch's schema.
2. Treat original format-1/2 columns as a single existing segment each.
3. Write replacement metadata and a segment manifest at EOF, followed by a new
   independently compressed payload for each column.
4. Fill in offsets/checksums, flush, and publish the new 48-byte root header.

All old bytes after the root header stay unchanged. In particular, neither the
old payloads nor their last partially filled compression blocks are rewritten.
The existing codecs and their block sizes are reused. A new segment has its own
block index, which avoids the original problem of needing to enlarge a block
index located before an existing payload.

On reads, each selected output vector is allocated once. The reader finds the
segments intersecting the requested rows and decompresses directly into that
vector at the correct offsets. Character columns use a destination-offset
adapter; factors reuse the canonical dictionary. No R-level concatenation of
old and new tables occurs.

A newly appended column can have one segment spanning all historical rows,
while older columns retain their row-batch boundaries. This is why the manifest
is per column rather than a single shared list of table-wide batch boundaries.

Native implementation and exact format:
[fstcore/ROW_APPEND.md](https://github.com/Roleren/fstcore/blob/feature/append-rows/ROW_APPEND.md).
R API:
[fst/R/append_rows_fst.R](https://github.com/Roleren/fst/blob/feature/append-rows/R/append_rows_fst.R).

## Benchmark method

The comparison measures:

```r
# Existing approach, timed together:
loaded <- read_fst(base)
combined <- rbind(loaded, new_rows)
write_fst(combined, rewritten)

# New approach:
append_rows_fst(new_rows, existing_copy)
```

Synthetic independent library columns contain 1% nonzero values. Integer counts
are 1–100; the double case uses values uniformly distributed between 0 and 100.
Each new batch adds 1% of the original row count. Compression is 50 and fst uses
four threads. Every case has three repetitions; method order alternates. Setup,
base-file copies, explicit GC and validation are outside the timers. Each
result is verified against every old and new value in batches of 32 columns.

Hardware: Intel Core i7-8850H, 31 GiB RAM, Linux x86-64, local `/dev/sda2` storage.
These are buffered, warm-cache local timings, not cold-storage or server/network
measurements. No fsync is included in either method. Times use R's elapsed wall
clock; millisecond-scale results are especially sensitive to timer resolution
and scheduling. Speedup is median rewrite time divided by median append time.
The data are synthetic rather than a sampled ORFik server file.

## Comparable results

| Existing rows | Library columns | Type | New rows | Rewrite median | Append median (range) | Speedup |
| ---: | ---: | --- | ---: | ---: | ---: | ---: |
| 2,000,000 | 32 | integer | 20,000 | 0.789 s | 0.002 s (0.002–0.004) | ~395× |
| 2,000,000 | 128 | integer | 20,000 | 2.589 s | 0.024 s (0.010–0.027) | ~108× |
| 2,000,000 | 512 | integer | 20,000 | 9.664 s | 0.052 s (0.029–0.062) | ~186× |
| 200,000 | 4,000 | integer | 2,000 | 7.839 s | 0.078 s (0.058–0.169) | ~100× |
| 2,000,000 | 128 | double | 20,000 | 3.789 s | 0.034 s (0.012–0.072) | ~111× |

For the 512-column integer case, appending grows the file by 1.067 MiB, versus
rewriting approximately the entire 102 MiB compressed table. At 4,000 columns
and 200,000 original rows, growth is 1.247 MiB. Small row batches have more
metadata and partially filled block overhead relative to their payload.

## Full human-width append

For **2,000,000 existing rows × 4,000 integer library columns**, appending
**20,000 rows** took **0.212 seconds median** (0.202–0.217 seconds over three
repetitions). The original compressed file was 796.480 MiB and the append added
8.300 MiB. Every old and new value was verified in bounded column batches.

The complete rewrite baseline was not run at this size: the existing integer
values alone require 32 GB before the extra allocations needed by read/rbind.
The 200,000-row × 4,000-column comparison above supplies a measured wide-table
speedup; no extrapolated full-size rewrite time is claimed.

## Read cost

For two-segment files, warm reads of the first 32 complete columns took median
0.089 s versus 0.082 s compact at 2m × 128 integers, and 0.090 s versus 0.086 s
at 2m × 512. At 200k × 4,000, the same 32-column read was 0.013 s versus 0.009 s.
These short three-repeat measurements show that faster append does not imply
faster reads. They are not a broad read-throughput study.

## Validation

- fst tests: 1,074 passing checks, zero failures/warnings; two existing tests
  skipped under `NOT_CRAN=false` (legacy fixture test and lint).
- fstcore tests: 57 passing checks, zero failures/warnings; two existing tests
  skipped (lint and the legacy giant-vector test).
- The minimal data.table example supplied by Roleren is included in
  `fst/ROW_APPEND.md` and as a regression test that checks the initial write,
  one-column append and one-row append.
- Row tests cover empty originals/batches, repeated appends, codec boundaries,
  compression 0/50/100, reordered partial reads, mixed types, special numeric
  values, encodings, factors, integer64, nanotime, timestamps and time units.
- Schema rejection leaves the complete original file byte-for-byte unchanged.
  Successful appends preserve all original bytes after the 48-byte root header.
- Alternating row/column appends, key removal, malformed/truncated manifests,
  native argument validation and ordinary export are tested.
- External tests verify upstream writer input, upstream rejection of format 3,
  reading a format-1 export upstream, and cooperative row/column lock exclusion.
- An injected file-size-limit failure before publication preserves the previous
  table; a subsequent append succeeds despite orphaned bytes at EOF.
- A real segmented raw column with **2,147,483,664 rows** passes boundary reads
  around 2^31 and a full read into **`data.table_long`**. This establishes tested
  long-row addressing and output integration, not exhaustive testing of every
  type at every 64-bit size. The legacy factor writer/empty-level reader also
  had 32-bit counters widened to prevent narrowing at 2^32.

## Limits and next steps

**Compatibility:** row-appended files require this fork's format-3 reader.
Unmodified upstream fst rejects them. A normal read/write export produces
format 1 when the table fits in a regular R data frame.

**Publication:** the cooperative lock excludes appenders using this API.
Ordinary readers/writers must also be excluded by the caller. Root publication
is not crash-atomic or power-loss durable. The successful pre-publication failure
test does not establish safety for a crash during root overwrite. Keep
recoverable inputs; transactions do not span chromosome files. Windows and the
actual server filesystem/locking behavior remain unvalidated.

**Many small batches:** the live manifest takes
`32 + 8*C + 24*sum(segments_per_column)` bytes. Every append writes a new complete
manifest; obsolete versions remain in the file. For C columns and S row appends,
live metadata is O(C*S), and cumulative obsolete manifests are O(C*S^2).
At 4,000 columns after 1,000 row appends, the live index is approximately 96 MB
and the manifest triples written over time total approximately 48 GB. Use
substantial batches. Frequent tiny appends need compaction or a future paged /
incremental manifest. Metadata and reads currently load the whole live manifest
even when selecting only a few columns.

For ORFik, the next deployment step is to install both matching forks on the
server and benchmark actual sparse count files with the intended batch size.
If rows need frequent small updates, implement bounded-memory compaction or an
incremental manifest before adopting that workload.

## Reproduce

From this report directory, with the matching forks installed in `R-library`
or otherwise available on `.libPaths()`:

```sh
Rscript benchmarks/benchmark_row_append.R 2000000 32 20000 integer 3
Rscript benchmarks/benchmark_row_append.R 2000000 128 20000 integer 3
Rscript benchmarks/benchmark_row_append.R 2000000 512 20000 integer 3
Rscript benchmarks/benchmark_row_append.R 200000 4000 2000 integer 3
Rscript benchmarks/benchmark_row_append.R 2000000 128 20000 double 3
Rscript benchmarks/benchmark_row_append.R 2000000 4000 20000 integer 3 append-only
Rscript benchmarks/validate_row_append_64bit.R
python3 benchmarks/validate_row_external.py
```

Raw measurements and R session details are in `results-row/`. Execution logs are
`benchmark-row-final.log`, `test-row-core-full.log`, `test-row-fst-full.log`,
`test-row-external.log`, `test-row-64bit.log` and `test-row-example.log`.
The external compatibility test requires upstream fst/fstcore in the default R
library and the forks in `R-library`. The long-vector test requires the
data.table fork and enough RAM for a 2 GiB output vector plus overhead.
