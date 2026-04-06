---
docid: study-roadmap
title: RocksDB Study Roadmap (for LevelDB developers)
layout: docs
permalink: /docs/study-roadmap.html
---

# RocksDB Study Roadmap

A structured study plan for developers already familiar with LevelDB. Each phase
builds on the previous one, starting from shared foundations and progressively
introducing RocksDB-specific concepts.

---

## Phase 0: Orientation — Map LevelDB Knowledge to RocksDB

**Goal:** Get your bearings. Understand what stayed the same and what changed.

**Key differences at a glance:**

| Concept | LevelDB | RocksDB |
|---|---|---|
| LSM tree structure | Single key space | Multiple Column Families sharing WAL + sequence space |
| Compaction | Level-style only | Level, Universal, FIFO, None (manual) |
| Concurrency | Single writer thread | Grouped writes, parallel memtable inserts |
| Memtable | Skip list only | Pluggable: SkipList, HashSkipList, HashLinkList, Vector |
| Block cache | Simple LRU | Sharded LRU, HyperClockCache, secondary cache |
| Filters | Basic Bloom | Full/partitioned Bloom, Ribbon filter |
| Transactions | None | Pessimistic (2PL) and Optimistic |
| Merge operator | None | Read-modify-write without read-before-write |
| Large values | Inline | Integrated BlobDB (separate blob files) |
| Configuration | Compile-time | Rich runtime Options, dynamic `SetOptions()`, OPTIONS file persistence |

**What to read:**
- `docs/_docs/getting-started.md` — familiar API patterns
- `docs/_docs/architecture.md` — high-level system map
- `include/rocksdb/db.h` — compare with `leveldb/db.h`; note Column Family overloads, `MultiGet`, `IngestExternalFile`
- [RocksDB Wiki Overview](https://github.com/facebook/rocksdb/wiki/RocksDB-Overview)

**Exercise:** Open the RocksDB `examples/` directory. Build and run
`simple_example.cc` and `column_families_example.cc`.

---

## Phase 1: Core Write Path

**Goal:** Understand how writes flow from `Put()` to WAL to memtable.

### 1.1 WriteBatch and WriteThread

LevelDB serializes writes one at a time with a single leader. RocksDB introduces
**write batch grouping** and **parallel memtable writes**.

**Key files:**
- `db/write_batch.cc` — batch encoding (same concept as LevelDB, more record types)
- `db/write_thread.h` / `db/write_thread.cc` — leader election, batch grouping
- `db/db_impl/db_impl_write.cc` — `WriteImpl()` entry point

**Study order:**
1. Read `WriteThread::JoinBatchGroup()` — how concurrent writers merge
2. Read `DBImpl::WriteImpl()` — the main write coordination loop
3. Understand `WriteController` — write stall and throttle logic

### 1.2 WAL (Write-Ahead Log)

Same 32KB-block framing as LevelDB, with extensions: recycled record format,
WAL compression, and multi-CF WAL tracking.

**Key files:**
- `db/log_writer.cc`, `db/log_reader.cc` — same structure as LevelDB
- `db/wal_manager.cc` — WAL lifecycle, archiving, cleanup
- `include/rocksdb/wal_filter.h` — filter records during recovery

### 1.3 Memtable

LevelDB has a single skip-list memtable. RocksDB has a pluggable `MemTableRep`
abstraction and a `WriteBufferManager` for global memory budgeting.

**Key files:**
- `db/memtable.h` / `db/memtable.cc` — wrapper with merge/timestamp/flush integration
- `memtable/inlineskiplist.h` — lock-free concurrent skip list (compare with LevelDB's)
- `memtable/write_buffer_manager.cc` — cross-CF memory cap
- `db/memtable_list.h` — immutable memtable list management

**Exercise:** Trace a `DB::Put()` call from API entry through WAL write to
memtable insertion. Note where sequence numbers are assigned.

---

## Phase 2: Core Read Path

**Goal:** Understand `Get()`, `MultiGet()`, and the `SuperVersion` mechanism.

### 2.1 SuperVersion and Version

LevelDB uses `Version` + `VersionSet` for the live file set. RocksDB adds
`SuperVersion` — a per-column-family bundle of {mutable memtable, immutable
memtable list, current Version}. This allows readers to proceed without holding
the DB mutex.

**Key files:**
- `db/column_family.h` — `SuperVersion` definition
- `db/version_set.h` / `db/version_set.cc` — `Version`, `VersionSet` (familiar from LevelDB, much larger)
- `db/version_edit.h` — delta records for MANIFEST

### 2.2 Point Lookups

**Key files:**
- `db/db_impl/db_impl.cc` — `DBImpl::GetImpl()`
- `db/version_set.cc` — `Version::Get()` → level-by-level file search
- `table/block_based/block_based_table_reader.cc` — block lookup, filter check, cache interaction

**Study order:**
1. Follow `DBImpl::GetImpl()` — SuperVersion acquisition, memtable search, Version search
2. Understand `GetContext` — the callback context that collects results
3. Read `MultiGet` path for batched lookups with async I/O

### 2.3 Iterators

LevelDB's `MergingIterator` concept is preserved but extended with more
iterator types.

**Key files:**
- `db/db_iter.cc` — `DBIter`, user-facing iterator applying visibility rules
- `table/merging_iterator.cc` — heap-based merge of multiple sorted sources
- `db/arena_wrapped_db_iter.cc` — arena-allocated iterator wrapper

**Exercise:** Trace a `DB::Get()` call. Draw the search order:
mutable memtable → immutable memtables → L0 files → L1+ files.
Note how Bloom filters short-circuit unnecessary block reads.

---

## Phase 3: SST File Format and Table Subsystem

**Goal:** Understand the on-disk format and how it extends LevelDB's table format.

### 3.1 Block-Based Table (default)

Same general structure as LevelDB (data blocks, index block, footer), with many
additions: filter blocks, compression dictionaries, range deletion blocks,
properties blocks, and multiple format versions.

**Key files:**
- `table/block_based/block_based_table_builder.cc` — SST file writer
- `table/block_based/block_based_table_reader.cc` — SST file reader
- `table/format.cc` — on-disk block layout, footer, magic numbers
- `table/block_based/filter_policy.cc` — Bloom and Ribbon filter construction
- `table/block_based/index_builder.cc` — binary search and hash index builders

**Key concepts to study:**
- Format versions (1–7) and their differences
- Partitioned index and filter blocks — for large SST files
- Compression dictionaries — trained dictionaries for better compression ratios
- Block checksums — CRC32c, xxHash, xxHash64, XXH3

### 3.2 Alternative Table Formats

- `table/plain/` — PlainTable: memory-mapped, hash-indexed, for in-memory workloads
- `table/cuckoo/` — CuckooTable: O(1) point lookup, no range scan

### 3.3 TableCache

**Key files:**
- `db/table_cache.cc` — caches open table readers; avoids re-opening SST files

**Exercise:** Use `sst_dump` tool to inspect an SST file. Examine data blocks,
index blocks, filter blocks, and properties.

---

## Phase 4: Compaction

**Goal:** Understand all compaction styles and the compaction pipeline.

### 4.1 Compaction Styles

| Style | When to use | Key file |
|---|---|---|
| Level | General-purpose, minimize space amp | `db/compaction/compaction_picker_level.cc` |
| Universal | Write-heavy, minimize write amp | `db/compaction/compaction_picker_universal.cc` |
| FIFO | Time-series, cache-like data | `db/compaction/compaction_picker_fifo.cc` |

### 4.2 Compaction Pipeline

**Key files:**
- `db/compaction/compaction_job.cc` — `Prepare()`, `Run()`, `Install()`
- `db/compaction/compaction_iterator.cc` — merges versions, applies filters, handles tombstones
- `db/compaction/subcompaction_state.cc` — parallel subcompaction support
- `include/rocksdb/compaction_filter.h` — application-defined key transformation during compaction

**Study order:**
1. Understand `CompactionPicker::PickCompaction()` for level-style (compare with LevelDB)
2. Read `CompactionJob::Run()` — how input files are merged into output files
3. Study subcompaction splitting — how large compactions are parallelized
4. Understand `CompactionIterator` — snapshot handling, merge resolution, tombstone processing

### 4.3 Flush

**Key files:**
- `db/flush_job.cc` — converts immutable memtables to L0 SST files
- Atomic flush across multiple column families

**Exercise:** Set up a small DB with verbose logging (`options.info_log_level = DEBUG_LEVEL`).
Write enough data to trigger flushes and compactions. Read the LOG file to trace
the lifecycle of files.

---

## Phase 5: Column Families

**Goal:** Understand the multi-namespace abstraction that LevelDB lacks.

Column families are logically independent LSM trees that share:
- WAL files and sequence number space
- Background thread pools
- Write thread and batch grouping
- Block cache and rate limiter

Each column family has its own:
- Memtables and Version chain
- Compaction settings and picker
- Comparator, merge operator, compaction filter

**Key files:**
- `db/column_family.h` / `db/column_family.cc` — `ColumnFamilyData`, `ColumnFamilySet`
- `include/rocksdb/db.h` — CF-aware API overloads (`Put`, `Get`, `NewIterator` with `ColumnFamilyHandle`)

**Study order:**
1. Read `ColumnFamilyData` — per-CF state ownership
2. Understand how `SuperVersion` is per-CF
3. Study WAL recovery with multiple CFs — `DBImpl::RecoverLogFiles()`

**Exercise:** Write a program using 3 column families with different compaction
styles. Observe how they share WAL but compact independently.

---

## Phase 6: Configuration and Options System

**Goal:** Master RocksDB's rich configuration system.

LevelDB has a flat `Options` struct. RocksDB splits options into:
- `DBOptions` — database-wide settings (parallelism, WAL, statistics)
- `ColumnFamilyOptions` — per-CF settings (memtable, compaction, compression)
- `Options` = `DBOptions` + `ColumnFamilyOptions` (convenience for single-CF use)
- `ReadOptions` / `WriteOptions` — per-operation settings

**Key files:**
- `include/rocksdb/options.h` — primary option definitions
- `include/rocksdb/advanced_options.h` — advanced tuning knobs
- `options/options_helper.cc` — parsing, serialization
- `options/db_options.cc` / `options/cf_options.cc` — mutable vs. immutable split

**Key concepts:**
- Dynamic options: `DB::SetOptions()` — change options at runtime without restart
- OPTIONS file: persists configuration to disk (auto-saved on open)
- Option validation and sanitization

**Exercise:** Read through `options.h` top to bottom. For each option, consider
whether LevelDB has an equivalent. Focus on options that control compaction,
memtable, and caching behavior.

---

## Phase 7: Cache Subsystem

**Goal:** Understand the multi-tier caching architecture.

### 7.1 Block Cache

- `cache/lru_cache.cc` — sharded LRU (default)
- `cache/clock_cache.cc` — HyperClockCache: concurrent clock-based eviction
- `cache/secondary_cache_adapter.cc` — tier-2 cache for evicted entries

### 7.2 Other Caches

- Row cache: caches merged point-lookup results (`DBOptions::row_cache`)
- Table cache: caches open `TableReader` objects (`db/table_cache.cc`)
- Write buffer manager: not a cache per se, but can charge against block cache

**Key concepts:**
- Cache entry roles and memory accounting
- Cache priorities (LOW, HIGH, BOTTOM)
- Compressed block cache vs. uncompressed block cache

**Exercise:** Write a benchmark that varies block cache size and measures read
latency. Compare LRU vs. HyperClockCache behavior under concurrent reads.

---

## Phase 8: Transactions

**Goal:** Understand ACID transaction support, which LevelDB completely lacks.

### 8.1 Pessimistic Transactions

**Key files:**
- `utilities/transactions/pessimistic_transaction_db.cc` — `TransactionDB` wrapper
- `utilities/transactions/pessimistic_transaction.cc` — lock-based conflict detection
- `utilities/transactions/transaction_lock_mgr.cc` — point and range lock management

### 8.2 Optimistic Transactions

**Key files:**
- `utilities/transactions/optimistic_transaction_db.cc`
- `utilities/transactions/optimistic_transaction.cc` — validation-based conflict detection

### 8.3 Write Policies

- `WRITE_COMMITTED` — writes visible only after commit (default, simplest)
- `WRITE_PREPARED` — writes after 2PC prepare (for distributed transactions)
- `WRITE_UNPREPARED` — writes before prepare (large transactions)

**Exercise:** Write a program with two concurrent transactions that conflict on
the same key. Observe deadlock detection with pessimistic and commit-time
validation with optimistic.

---

## Phase 9: Merge Operator and Compaction Filter

**Goal:** Understand RocksDB's unique read-modify-write and compaction-time
data transformation features.

### 9.1 Merge Operator

Allows atomic read-modify-write without a preceding Get:
```cpp
db->Merge(write_options, key, increment_value);
```
Merge operands accumulate in memtables and SST files. Resolution happens lazily
during reads and eagerly during compaction.

**Key files:**
- `include/rocksdb/merge_operator.h` — `AssociativeMergeOperator`, `MergeOperator`
- `db/merge_helper.cc` — merge resolution logic
- `utilities/merge_operators/` — built-in implementations (counters, string append, etc.)

### 9.2 Compaction Filter

Application logic that runs during compaction to modify, delete, or transform
key-value pairs.

**Key files:**
- `include/rocksdb/compaction_filter.h` — filter interface
- `db/compaction/compaction_iterator.cc` — where filters are invoked

**Exercise:** Implement a simple counter using `AssociativeMergeOperator`.
Compare performance against read-Get-Put-write pattern.

---

## Phase 10: Advanced Features

**Goal:** Study features that make RocksDB a production-grade engine.

### 10.1 BlobDB (Large Value Storage)

- `db/blob/` — integrated BlobDB; values exceeding `min_blob_size` go to separate blob files
- SST stores `BlobIndex` pointers instead of inline values

### 10.2 SST File Ingestion

- `db/external_sst_file_ingestion_job.cc` — bulk-load pre-built SST files
- `include/rocksdb/sst_file_writer.h` — build SST files externally

### 10.3 Rate Limiter

- `include/rocksdb/rate_limiter.h` — token-bucket I/O throttling
- Controls compaction/flush I/O to avoid starving foreground reads

### 10.4 Secondary / Follower Instances

- Read-only secondary instances that tail the primary's MANIFEST and WAL
- Useful for read replicas without full replication

### 10.5 User-Defined Timestamps

- Application-provided timestamps appended to user keys
- Enables point-in-time reads without relying solely on sequence numbers

### 10.6 Wide-Column Entities

- `PutEntity()` / `GetEntity()` — store multiple named columns per key
- Partial column retrieval for wide rows

### 10.7 Backup and Checkpoint

- `utilities/backup/` — incremental hot backups with checksum verification
- `utilities/checkpoint/` — zero-copy snapshots via hard links

**Exercise:** Build and run `db_bench` with different configurations. Practice
using `sst_dump`, `ldb`, and `db_bench` tools.

---

## Phase 11: Monitoring, Debugging, and Operations

**Goal:** Learn the observability and operational tools.

### 11.1 Statistics and Perf Context

- `include/rocksdb/statistics.h` — tickers (counters) and histograms
- `include/rocksdb/perf_context.h` — per-operation performance breakdown
- `include/rocksdb/iostats_context.h` — per-thread I/O accounting

### 11.2 Event Listeners

- `include/rocksdb/listener.h` — callbacks for flush, compaction, stall, error events
- Useful for custom monitoring integration

### 11.3 Tools

| Tool | Purpose |
|---|---|
| `db_bench` | Benchmarking (equivalent to LevelDB's `db_bench`, much richer) |
| `ldb` | CLI for inspecting and manipulating RocksDB databases |
| `sst_dump` | Inspect SST file contents, metadata, and statistics |
| `db_stress` | Long-running randomized stress test |

**Exercise:** Open a production-like workload with statistics enabled.
Query `db->GetProperty("rocksdb.stats")` and interpret the output.
Use `PerfContext` to profile a hot read loop.

---

## Suggested Reading Order for Source Code

For each phase, the recommended source reading order from most important to
supplementary:

```
Phase 1:  db/db_impl/db_impl_write.cc → db/write_thread.cc → db/write_batch.cc
Phase 2:  db/db_impl/db_impl.cc (GetImpl) → db/version_set.cc → table/block_based/block_based_table_reader.cc
Phase 3:  table/format.cc → table/block_based/block_based_table_builder.cc → table/block_based/filter_policy.cc
Phase 4:  db/compaction/compaction_job.cc → db/compaction/compaction_picker_level.cc → db/compaction/compaction_iterator.cc
Phase 5:  db/column_family.cc → db/db_impl/db_impl_open.cc (RecoverLogFiles)
Phase 6:  include/rocksdb/options.h → options/db_options.cc → options/cf_options.cc
Phase 7:  cache/lru_cache.cc → cache/clock_cache.cc → db/table_cache.cc
Phase 8:  utilities/transactions/pessimistic_transaction.cc → utilities/transactions/transaction_lock_mgr.cc
Phase 9:  include/rocksdb/merge_operator.h → db/merge_helper.cc
Phase 10: db/blob/blob_file_builder.cc → db/external_sst_file_ingestion_job.cc
Phase 11: include/rocksdb/statistics.h → tools/db_bench_tool.cc
```

---

## External Resources

- [RocksDB GitHub Wiki](https://github.com/facebook/rocksdb/wiki) — the most comprehensive reference
- [RocksDB Blog](http://rocksdb.org/blog/) — deep dives on specific features
- [RocksDB Tuning Guide](https://github.com/facebook/rocksdb/wiki/RocksDB-Tuning-Guide) — practical performance tuning
- [RocksDB FAQ](https://github.com/facebook/rocksdb/wiki/RocksDB-FAQ)
- Original LevelDB documentation — useful as a baseline comparison
