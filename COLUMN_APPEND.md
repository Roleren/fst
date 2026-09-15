# Append library columns

Install the matching fstcore fork first, then this fst fork. In a fresh R session:

```r
library(fst)
append_fst(data.frame(new_library = counts), "chr1_chunk_001.fst")
```

`counts` must have the same length and genomic row order as the chunk. Supply
only new libraries; names must be unique and must not already exist. Several
new libraries can be appended together. Compression defaults to 50 and applies
only to the new columns. Existing data.table keys are preserved.

The function writes only the new column values and updated metadata. It does
not read, decompress or rewrite existing library values. Normal `read_fst`,
`metadata_fst`, selected-column and selected-row reads work with appended files.

**Compatibility:** appended files require this fstcore fork. Upstream readers
reject them. Ordinary `write_fst` output remains upstream-compatible. To export
or compact, read with this fork and write to a different path with `write_fst`.

**Coordination:** prevent readers and other writers from accessing a chunk while
appending. Appenders use a cooperative exclusive lock. Network locking needs
verification on your server. Header publication is not crash-atomic or power-loss
durable; retain source libraries/backups. See `?append_fst` for details.

For ORFik, preserve each existing chromosome/chunk row mapping and use
`append_fst(new_library_columns_for_that_chunk, chunk_path)` in place of
`read_fst` + `cbind` + `write_fst`. Publish the library in your server's metadata
only after all its chunks succeed. This per-file API does not make a collection
of chromosome chunks transactional.
