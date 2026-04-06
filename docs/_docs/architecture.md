---
docid: architecture
title: Architecture
layout: docs
permalink: /docs/architecture.html
---

# Architecture

This document describes the high-level architecture of RocksDB. It is aimed at
developers who want a practical map of the code base: what the major runtime
objects are, how data flows through the engine, and where to look when making a
change.

See also:

- [Getting started](/docs/getting-started.html)
- [RocksDB Overview](https://github.com/facebook/rocksdb/wiki/RocksDB-Overview)
- [BlockBasedTable file format](https://github.com/facebook/rocksdb/wiki/Rocksdb-BlockBasedTable-Format)
- [Write-Ahead Log file format](https://github.com/facebook/rocksdb/wiki/Write-Ahead-Log-File-Format)

## Bird's Eye View

RocksDB is an embeddable LSM-tree storage engine, not a standalone server. The
public API is exposed through `include/rocksdb/`, while the storage engine is
primarily implemented by `DBImpl` in `db/db_impl/`.

At a high level, RocksDB takes writes from application threads, appends them to
the WAL, inserts them into per-column-family memtables, and later turns those
memtables into SST files through background flush and compaction. Reads operate
on a point-in-time snapshot of one column family's state via `SuperVersion`.

```text
application threads
  -> public API (`include/rocksdb/`)
  -> `DBImpl`
       -> `WriteThread` + `log::Writer` -> WAL files
       -> `ColumnFamilyData`
            -> `SuperVersion`
                 -> mutable memtable
                 -> immutable memtables
                 -> current `Version`
                      -> `TableCache`
                           -> `TableReader`
                                -> block cache / file system / SSTs
       -> background work
            -> `FlushJob`
            -> `CompactionPicker` / `CompactionJob`
       -> `VersionSet`
            -> MANIFEST / CURRENT / OPTIONS files
```

Some deployments also enable blob storage. In that mode, SST files may contain
blob indexes while large values live in blob files managed under `db/blob/`.

**Architecture Invariant:** RocksDB correctness does not come from a single
"database state" object. Durable state is split across WALs, SST/blob files,
MANIFEST metadata, and current in-memory memtables. Correctness comes from how
those pieces are ordered, published, and retired.

## Runtime Model

### Opening and recovery

Opening a DB starts in `DB::Open()` and ends up constructing `DBImpl` (or a
close relative such as `DBImplReadOnly` or `DBImplSecondary`).

The open path does roughly the following:

1. Sanitize and validate DB/column family options.
2. Open database directories and lock the DB.
3. Recover the live file set from `CURRENT` + `MANIFEST` through
   `VersionSet::Recover()`.
4. Replay WAL files that contain updates newer than the recovered SST state.
5. Build and install the first `SuperVersion` for each column family.
6. Start background threads and periodic work as needed.

`OpenForReadOnly()` shares most of the recovery path but disables write-side
operations. `OpenAsSecondary()` also reuses the same machinery, but keeps a
secondary instance catch-up capable by replaying MANIFEST and WAL changes from
the primary via `TryCatchUpWithPrimary()`.

**Architecture Invariant:** the recovered DB state is the combination of
`VersionSet`/MANIFEST state and WAL replay. MANIFEST alone does not capture the
latest unflushed writes, and WAL replay alone does not define the live file
set.

### Write path

User writes typically arrive as a `WriteBatch`, even when the public call looks
like `Put()` or `Delete()`.

The hot write path is:

1. `DBImpl::WriteImpl()` admits the write, applies write-stall policy, and
   enters `WriteThread`.
2. `WriteThread` groups writers, assigns sequence numbers, and coordinates who
   writes the WAL and who inserts into memtables.
3. `log::Writer` appends the batch to the WAL.
4. The batch is inserted into one or more mutable memtables.
5. If a memtable fills up, RocksDB seals it, adds it to the immutable memtable
   list, installs a fresh mutable memtable, and schedules flush work.

The logical order of writes is defined by sequence numbers and WAL order, not
by which CPU core reaches a memtable first. RocksDB can parallelize some
memtable work, but it must still preserve this ordering contract.

**Architecture Invariant:** durability and visibility are related but distinct.
WAL policy controls durability. Sequence numbers, snapshots, and published
memtable state control visibility.

### Read path

Point reads, `MultiGet`, and iterators all need a consistent read-side view.
That view is represented by `SuperVersion`, which bundles:

- the current mutable memtable
- the immutable memtable list
- the current `Version` (the live SST/blob file set)
- the current mutable column family options needed by reads

The common read path is:

1. Acquire a referenced `SuperVersion`.
2. Check the mutable memtable.
3. Check immutable memtables.
4. If needed, search SST files through `Version::Get()` and `TableCache`.
5. Resolve merge operands, tombstones, timestamps, and snapshot visibility.

Old `SuperVersion`s can outlive the newest one because iterators, compactions,
and in-flight reads may still reference them. This is how RocksDB gives readers
a stable view without holding the DB mutex while touching storage.

`TableCache` caches `TableReader` objects. The block cache caches blocks read by
those table readers. They are related, but they are not the same layer.

**Architecture Invariant:** read operations should avoid holding the DB mutex
across IO or long scans. The normal pattern is to pin a `SuperVersion`, then
operate on immutable/read-only structures.

### Flush and compaction

When writes outgrow in-memory state, RocksDB uses background jobs to rewrite the
LSM tree.

Flush:

1. `FlushJob` picks one or more immutable memtables.
2. It builds a new SST file, usually in L0.
3. It writes the file, syncs what must be synced, and creates a `VersionEdit`.
4. `VersionSet` applies that edit and a new `SuperVersion` is installed.

Compaction:

1. `CompactionPicker` decides which files should be compacted.
2. `CompactionJob::Prepare()` builds subcompaction boundaries if needed.
3. `CompactionJob::Run()` reads keys from input files, merges versions,
   applies filters, handles range tombstones, and writes output files.
4. `CompactionJob::Install()` commits a new `VersionEdit`, publishes outputs,
   and retires obsolete inputs.

Different compaction styles live behind the same general pipeline. Level,
universal, and FIFO mostly differ in file layout policy and picking logic, not
in the fundamental publish/install model.

**Architecture Invariant:** the live file set is changed by appending
`VersionEdit`s and installing a new `Version`, not by mutating the current
`Version` in place.

### Column families, snapshots, and wrappers

Each column family is its own LSM tree with its own memtables, `SuperVersion`,
and file metadata. At the same time, column families still share DB-wide
concerns such as sequence numbering, WAL management, background scheduling, and
many resource limits.

Snapshots are sequence-number based. A read snapshot does not copy data; it
changes visibility rules while traversing memtables and SSTs.

Higher-level features such as `TransactionDB`, `OptimisticTransactionDB`,
`StackableDB`, and secondary/read-only modes generally wrap or reuse `DBImpl`
rather than replacing the storage core.

**Architecture Invariant:** column families are mostly independent on the read
and compaction side, but writes and recovery can still couple them through
shared WALs and shared sequence space. Any cross-column-family feature needs
DB-wide reasoning.

## Code Map

### `include/rocksdb/`

This is the public API boundary. If an application embeds RocksDB as a library,
this is the supported interface it should depend on.

Important headers include:

- `db.h` for the main DB API
- `options.h` and friends for configuration
- `table.h` for table factories and table-format options
- `cache.h`, `env.h`, `file_system.h`, `statistics.h`, etc. for extensibility
- `utilities/*.h` for optional layers such as transactions, checkpoints, and
  backup

`db/c.cc` implements the C API declared in `include/rocksdb/c.h`. Language
bindings and wrappers should generally build on this public surface, not on
internal headers.

**API Boundary:** everything under `include/rocksdb/` carries compatibility
weight. Internal headers do not.

### `db/`

This is the storage engine core.

Key areas:

- `db/db_impl/`: `DBImpl`, open/recovery, read path, write path, file
  management, secondary/read-only variants
- `column_family.h`: `ColumnFamilyData`, `SuperVersion`, and read-side lifetime
  rules
- `version_set.h`: `Version`, `VersionSet`, and live-file metadata
- `version_edit.h`: MANIFEST deltas
- `memtable.*`: memtable wrapper and immutable memtable list integration
- `flush_job.*`: flush execution
- `compaction/`: compaction picking and execution
- `blob/`: integrated blob file support

This is the best place to start when you want to understand how data moves
through RocksDB.

**Architecture Invariant:** `db/` owns core storage semantics. Optional
features are allowed to extend it, but they should not duplicate it.

### `memtable/`

This directory contains concrete memtable representations and helpers:

- skiplist-based memtables
- hash-linked and hash-skiplist variants
- vector-based variants
- write buffer management support

The `MemTable` abstraction in `db/memtable.*` wraps these lower-level data
structures and integrates them with snapshots, merge processing, timestamps,
and flush.

### `table/`

This directory owns SST formats and table readers/builders.

Important subdirectories:

- `block_based/`: the default SST format and the default read path
- `plain/`: plain table format
- `cuckoo/`: cuckoo table format
- `adaptive/`: adaptive table factory support

The default `BlockBasedTable` implementation is where index blocks, filter
blocks, data blocks, compression dictionaries, and block-cache behavior come
together.

**Architecture Invariant:** `table/` changes often have on-disk compatibility
cost. A format change is not just a local optimization.

### `cache/`

Generic cache implementations used across the engine live here:

- LRU and clock caches
- secondary cache support
- sharding and charging helpers

These caches are used by block-based tables and other internal components.
Remember that this layer implements caches themselves; policy about what to
cache is usually in `table/` or `db/`.

### `options/`

This directory translates the public configuration surface into runtime-ready
structures:

- option validation
- option sanitization
- mutable vs immutable option splitting
- options file parsing and serialization
- `Configurable` / `Customizable` plumbing

If a change adds a new option, this directory is usually involved even if the
actual behavior lives elsewhere.

### `monitoring/`

Statistics, perf context, histogram utilities, thread status, and other
observability support live here. This code is cross-cutting: it touches hot
paths, so low overhead matters.

### `utilities/`

Optional features and wrappers live here, including:

- transactions
- backup and checkpoint support
- TTL wrappers
- merge operators
- persistent cache helpers
- legacy `BlobDB` wrappers and other add-on modules

These pieces usually sit on top of the core engine rather than redefining the
core engine itself.

**Architecture Invariant:** utility layers should reuse existing `DB`/`DBImpl`
mechanisms wherever possible. Forking core read/write behavior makes
correctness, testing, and maintenance much harder.

### `env/`, `file/`, `port/`, `util/`, `memory/`

These directories provide low-level infrastructure:

- environment and file-system abstractions
- file naming and IO helpers
- platform portability shims
- reusable utility code
- memory allocators and arenas

They are used everywhere, especially in hot paths and recovery code.

### `tools/`, `db_stress_tool/`, `microbench/`

These are the operational and performance tools:

- `tools/db_bench_tool.cc` for benchmarks
- `db_stress_tool/` for long-running randomized stress
- `microbench/` for focused microbenchmarks

When a change is performance-sensitive, these are usually part of the
validation story.

### Tests

RocksDB keeps many tests close to the code they exercise:

- `db/*_test.cc`
- `table/*/*_test.cc`
- `cache/*_test.cc`
- `options/*_test.cc`
- `monitoring/*_test.cc`

This means the best examples for how a subsystem is expected to behave are
often right next to the implementation.

## Cross-Cutting Concerns

### Options and customization

RocksDB is highly configurable. Many important components are injected through
interfaces:

- comparator
- merge operator
- compaction filter
- table factory
- memtable representation factory
- cache
- env / file system
- listeners and statistics sinks

Public options live in `include/rocksdb/`. Runtime-ready derivatives live in
`options/` and are further split into immutable and mutable forms.

**Architecture Invariant:** a feature is not "integrated" just because the code
path exists. It also needs option validation, configuration plumbing, reopen
behavior, and tests.

### Concurrency and lifetime management

RocksDB tries hard to keep the hot read path lock-light. It does this by
publishing new versions of shared state and holding references to old state
while readers still need it.

Key lifetime tools include:

- `SuperVersion` reference counting
- `Version` lifetime managed through `VersionSet`
- memtable reference counting
- `WriteThread` for logical write serialization
- background jobs that pick work under lock and execute most heavy work outside
  the DB mutex

**Architecture Invariant:** prefer immutable-after-publication state plus
reference counting over ad hoc shared mutable state.

### Observability and performance

RocksDB is extremely performance-sensitive, especially in:

- WAL append and sync
- memtable insert and lookup
- block cache lookups
- `Version::Get()` / iterator read paths
- compaction inner loops

The code base therefore contains a large amount of statistics, perf counters,
IO tracing, and thread status support. These are not side features; they are
part of how the engine is operated and tuned.

### Compatibility

There are several compatibility boundaries that deserve extra care:

- public headers in `include/rocksdb/`
- WAL record formats in `db/log_*`
- MANIFEST / `VersionEdit` encoding
- SST formats and metadata in `table/`
- options files and configurable object names

Backward and forward compatibility matter much more here than in ordinary
internal refactoring.

## Where To Start

If you are new to the code base, a good reading order is:

1. `include/rocksdb/db.h`
2. `db/db_impl/db_impl.h`
3. `db/column_family.h`
4. `db/version_set.h`
5. `db/db_impl/db_impl_open.cc`
6. `db/db_impl/db_impl_write.cc`
7. `db/db_impl/db_impl.cc`
8. `db/flush_job.h`
9. `db/compaction/compaction_job.h`
10. `db/table_cache.h`
11. `table/block_based/block_based_table_reader.h`

If you are changing a specific area, start here:

- Public API change: `include/rocksdb/`, then implementation in `db/` and any
  relevant bindings or utilities.
- New or removed option: `include/rocksdb/options.h`, `options/`, then the
  owning subsystem.
- Write path change: `db/db_impl/db_impl_write.cc`, `db/write_thread.h`,
  `db/log_writer.h`, `db/memtable.h`, and `memtable/`.
- Read path change: `db/db_impl.cc`, `db/column_family.h`, `db/table_cache.h`,
  and `table/block_based/`.
- Recovery or metadata change: `db/db_impl/db_impl_open.cc`,
  `db/version_set.h`, `db/version_edit.h`, `db/log_reader.h`.
- Flush or compaction change: `db/flush_job.*`, `db/compaction/*`,
  `db/version_set.h`, and performance validation in `db_bench`.
- Table format or cache change: `table/`, `cache/`, and compatibility tests.

This document is intentionally high level. Once you know which part of the code
owns a concern, the next step is usually to read the surrounding tests, then
the implementation.
