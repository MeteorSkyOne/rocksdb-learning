# SavePoint Mechanism: A Stack of Bookmarks into an Append-Only Log

## Layer 1: WriteBatch is a Flat Byte Buffer (`rep_`)

```
rep_ layout:
┌──────────────────────┬──────────┬──────────┬──────────┬─────┐
│  Header (12 bytes)   │  Op #1   │  Op #2   │  Op #3   │ ... │
│  [seq_num + count]   │  Put(k,v)│  Del(k)  │  Put(k,v)│     │
└──────────────────────┴──────────┴──────────┴──────────┴─────┘
                                                         ↑
                                                    rep_.size()
```

All mutations (Put, Delete, Merge, etc.) are **serialized and appended** sequentially to this single `std::string`. It's an append-only log — operations are never inserted in the middle or reordered.

## Layer 2: SavePoint = A Snapshot of 3 Numbers

When you call `SetSavePoint()`, it captures:

```
SavePoint {
  size:          rep_.size()           // byte offset — where to truncate
  count:         WriteBatch::Count()   // operation count
  content_flags: content_flags_        // bitflags (has Put? Delete? Merge?)
}
```

That's it. No copying of data. No undo log. Just 3 integers pushed onto a stack.

Source: `include/rocksdb/write_batch.h:45-62`

```cpp
struct SavePoint {
  size_t size;     // size of rep_
  uint32_t count;  // count of elements in rep_
  uint32_t content_flags;
  // ...
};
```

The `SavePoints` container is simply a stack (`db/write_batch.cc:172-174`):

```cpp
struct SavePoints {
  std::stack<SavePoint, autovector<SavePoint>> stack;
};
```

## Layer 3: The Three Operations

### `SetSavePoint()` — Take a bookmark

```
rep_:  [Header | Op1 | Op2 | Op3 ]
                                  ↑
                        SavePoint{size=47, count=3, flags=0x05}
                        pushed onto save_points_->stack
```

Source: `db/write_batch.cc:1820-1827`

```cpp
void WriteBatch::SetSavePoint() {
  if (save_points_ == nullptr) {
    save_points_.reset(new SavePoints());
  }
  save_points_->stack.push(SavePoint(
      GetDataSize(), Count(), content_flags_.load(std::memory_order_relaxed)));
}
```

### `RollbackToSavePoint()` — Truncate back to bookmark

```
Before:  [Header | Op1 | Op2 | Op3 | Op4 | Op5 ]
                                  ↑
                            SavePoint{size=47}

After:   [Header | Op1 | Op2 | Op3 ]   ← rep_.resize(47) — Op4, Op5 gone
```

Three lines do all the work (`db/write_batch.cc:1847-1852`):

```cpp
rep_.resize(savepoint.size);                           // truncate the buffer
WriteBatchInternal::SetCount(this, savepoint.count);   // restore count
content_flags_.store(savepoint.content_flags);         // restore flags
```

Full source: `db/write_batch.cc:1829-1856`

```cpp
Status WriteBatch::RollbackToSavePoint() {
  if (save_points_ == nullptr || save_points_->stack.size() == 0) {
    return Status::NotFound();
  }

  SavePoint savepoint = save_points_->stack.top();
  save_points_->stack.pop();

  if (savepoint.size == rep_.size()) {
    // No changes to rollback
  } else if (savepoint.size == 0) {
    // Rollback everything
    Clear();
  } else {
    rep_.resize(savepoint.size);
    if (prot_info_ != nullptr) {
      prot_info_->entries_.resize(savepoint.count);
    }
    WriteBatchInternal::SetCount(this, savepoint.count);
    content_flags_.store(savepoint.content_flags, std::memory_order_relaxed);
  }
  // ...
}
```

### `PopSavePoint()` — Discard bookmark, keep the data

Simply pops the stack. The operations stay in `rep_`. This means "I'm happy with what I did since the savepoint — commit it into the batch."

Source: `db/write_batch.cc:1858-1867`

```cpp
Status WriteBatch::PopSavePoint() {
  if (save_points_ == nullptr || save_points_->stack.size() == 0) {
    return Status::NotFound();
  }
  save_points_->stack.pop();
  return Status::OK();
}
```

## Layer 4: Nested Savepoints Form a Stack

```
rep_:  [Header | Op1 | Op2 | Op3 | Op4 | Op5 | Op6 ]

save_points_ stack (top → bottom):
  ┌─ SP2 {size=70, count=5}   ← after Op5
  ├─ SP1 {size=47, count=3}   ← after Op3
  └─ (bottom)

RollbackToSavePoint() → rolls back to SP2, discards Op6
RollbackToSavePoint() → rolls back to SP1, discards Op4+Op5
```

Each rollback peels one layer. You can nest as many as you want.

## Layer 5: Transaction Layer Adds Lock Tracking

At the transaction level (`utilities/transactions/transaction_base.h:402`), there's a **richer SavePoint** that also saves:

```cpp
TransactionBaseImpl::SavePoint {
  snapshot_              // DB snapshot for conflict detection
  snapshot_needed_       // whether snapshot was required
  snapshot_notifier_     // notification callback
  num_puts_              // stats: puts since txn start
  num_put_entities_      // stats: put entities
  num_deletes_           // stats: deletes
  num_merges_            // stats: merges
  new_locks_             // keys locked SINCE this savepoint
}
```

On rollback (`utilities/transactions/transaction_base.cc:187-213`), the transaction layer:

1. **Restores snapshot & stats** — brings transaction metadata back to the savepoint state
2. **Calls `write_batch_.RollbackToSavePoint()`** — the buffer truncation described above
3. **Releases locks** acquired since the savepoint via `tracked_locks_->Subtract(*save_point.new_locks_)`

This two-layer design cleanly separates concerns:
- **WriteBatch::SavePoint** handles data (the byte buffer)
- **TransactionBaseImpl::SavePoint** handles transaction metadata (locks, snapshots, stats)

## The Key Insight

The entire mechanism exploits one property: **`rep_` is append-only**. Because operations are only ever appended, a byte offset is a perfect partition — everything before the offset is "committed to the batch," everything after is "tentative." Rollback is just `resize()`, which is O(1) for shrinking a `std::string`.

No undo log. No reverse operations. No operation-level bookkeeping. Just **truncate the tape**.

## Comparison with Traditional Database Savepoints

| Aspect | Traditional RDBMS | RocksDB |
|--------|------------------|---------|
| Undo mechanism | Undo log with reverse operations | Buffer truncation |
| Cost of SetSavePoint | Varies | O(1) — save 3 integers |
| Cost of Rollback | O(n) — apply undo records | O(1) — resize a string |
| Nesting | Stack of undo log pointers | Stack of (offset, count, flags) |
| Lock handling | Integrated in undo system | Separate `LockTracker` layer |

This simplicity is possible because RocksDB's WriteBatch is a **write-ahead buffer** — nothing is applied to the database until the entire batch is committed. In a traditional RDBMS, modifications are applied in-place, so you need undo records to reverse them. RocksDB sidesteps this entirely by deferring all writes.
