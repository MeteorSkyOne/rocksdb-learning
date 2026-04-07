# RocksDB 事务设计深度解析

> 面向开发者的源码级技术分析，基于 RocksDB 源码剖析事务子系统的架构设计、实现细节与工程权衡。

---

## 目录

- [第一章 引言与全局架构](#第一章-引言与全局架构)
- [第二章 核心抽象层设计](#第二章-核心抽象层设计)
- [第三章 乐观事务（Optimistic Concurrency Control）](#第三章-乐观事务optimistic-concurrency-control)
- [第四章 悲观事务与锁管理](#第四章-悲观事务与锁管理)
- [第五章 三种写入策略（Write Policy）](#第五章-三种写入策略write-policy)
- [第六章 两阶段提交（2PC）](#第六章-两阶段提交2pc)
- [第七章 冲突检测机制深入](#第七章-冲突检测机制深入)
- [第八章 设计决策总结与权衡分析](#第八章-设计决策总结与权衡分析)

---

## 第一章 引言与全局架构

### 1.1 设计目标：在 LSM-Tree 之上实现 ACID 事务

RocksDB 的核心是一个 LSM-Tree（Log-Structured Merge-Tree）存储引擎。LSM-Tree 天然擅长高吞吐写入，但它本身并不提供事务语义。所谓事务语义，是指一组操作要么全部成功、要么全部失败（原子性，Atomicity），且在并发场景下互不干扰（隔离性，Isolation）。

RocksDB 事务子系统的设计目标，可以用一句话概括：**在不破坏 LSM-Tree 写入性能优势的前提下，提供完整的 ACID 事务支持**。

具体而言，它需要解决三个核心问题：

- **写冲突检测（Write Conflict Detection）**：当两个事务同时修改同一个 key 时，如何发现并解决冲突？
- **读一致性（Read Consistency）**：事务内的读操作如何看到自己尚未提交的写入，同时不受其他事务影响？
- **灵活的并发控制策略**：不同业务场景对冲突频率的预期不同，需要支持悲观（Pessimistic）和乐观（Optimistic）两种并发控制模式。

为此，RocksDB 提供了两大类事务实现：

- **悲观事务（Pessimistic Transaction）**：写入前先加锁，适合冲突频繁的场景。类比现实中的"先占座再点餐"。
- **乐观事务（Optimistic Transaction）**：写入时不加锁，提交时才检查冲突，适合冲突稀少的场景。类比"先点餐，结账时发现座位被占了再重来"。

### 1.2 全局类继承体系

RocksDB 的事务子系统由两条并行的继承链组成：一条是**事务对象**（Transaction），另一条是**事务数据库**（TransactionDB）。下面的 ASCII 图展示了完整的继承关系：

```
                        事务对象（Transaction）继承链
 ============================================================================

                           Transaction (抽象基类)
                    include/rocksdb/utilities/transaction.h
                                    |
                          TransactionBaseImpl (核心抽象层)
                   utilities/transactions/transaction_base.h
                          /                        \
                         /                          \
          PessimisticTransaction                OptimisticTransaction
   utilities/transactions/                utilities/transactions/
   pessimistic_transaction.h              optimistic_transaction.h
            |
    +-------+----------+
    |                   |
 WriteCommittedTxn   WritePreparedTxn
 (pessimistic_       (write_prepared_
  transaction.h)      txn.h)
                        |
                   WriteUnpreparedTxn
                   (write_unprepared_
                    txn.h)


                   事务数据库（TransactionDB）继承链
 ============================================================================

    StackableDB                        StackableDB
        |                                  |
    TransactionDB (抽象基类)       OptimisticTransactionDB
  include/rocksdb/utilities/       include/rocksdb/utilities/
    transaction_db.h              optimistic_transaction_db.h
        |                                  |
  PessimisticTransactionDB        OptimisticTransactionDBImpl
  utilities/transactions/          utilities/transactions/
  pessimistic_transaction_db.h    optimistic_transaction_db_impl.h
        |
    +---+---+
    |       |
WriteCommitted  WritePreparedTxnDB
  TxnDB         (write_prepared_txn_db.h)
(pessimistic_       |
transaction_db.h) WriteUnpreparedTxnDB
                (write_unprepared_txn_db.h)
```

这个双链设计的核心思想是**将"事务行为"和"数据库管理"分离**：

- **Transaction 链**负责单个事务的生命周期：缓冲写入、跟踪锁、冲突检测、提交/回滚。
- **TransactionDB 链**负责全局管理：创建事务、管理锁表、协调并发。

### 1.3 两大家族：悲观 vs 乐观

#### 悲观家族（Pessimistic Family）

悲观事务的核心假设是**冲突很可能发生**，因此每次写入或 `GetForUpdate` 时都立即获取锁。

它的组件配对关系如下：

| 组件 | 类名 | 职责 |
|------|------|------|
| 数据库层 | `PessimisticTransactionDB` | 持有全局 `LockManager`，管理锁的获取与释放 |
| 事务层 | `PessimisticTransaction` | 在 `TryLock` 中真正调用 `LockManager` 加锁 |

从源码可以看到，`PessimisticTransactionDB` 提供了锁操作的入口（`pessimistic_transaction_db.h` 第 146-153 行）：

```cpp
// utilities/transactions/pessimistic_transaction_db.h:146-153
Status TryLock(PessimisticTransaction* txn, uint32_t cfh_id,
               const std::string& key, bool exclusive);
Status TryRangeLock(PessimisticTransaction* txn, uint32_t cfh_id,
                    const Endpoint& start_endp, const Endpoint& end_endp);

void UnLock(PessimisticTransaction* txn, const LockTracker& keys);
void UnLock(PessimisticTransaction* txn, uint32_t cfh_id,
            const std::string& key);
```

而 `PessimisticTransaction` 负责在每次写操作前调用这些锁接口。如果加锁失败（超时或死锁），操作立即返回错误。

#### 乐观家族（Optimistic Family）

乐观事务的核心假设是**冲突很少发生**，因此写入时不加锁，只在提交时验证。

它的组件配对关系如下：

| 组件 | 类名 | 职责 |
|------|------|------|
| 数据库层 | `OptimisticTransactionDB` | 提供 `BeginTransaction` 接口，管理验证策略 |
| 事务层 | `OptimisticTransaction` | 提交时调用 `CheckTransactionForConflicts` 验证 |

乐观事务的 `TryLock` 实现非常轻量——它只是记录 key，并不真正加锁（`optimistic_transaction.h` 第 71-73 行）：

```cpp
// utilities/transactions/optimistic_transaction.h:71-73
void UnlockGetForUpdate(ColumnFamilyHandle* /* unused */,
                        const Slice& /* unused */) override {
  // Nothing to unlock.
}
```

冲突检测推迟到提交阶段，通过 `OptimisticTransactionCallback` 实现（`optimistic_transaction.h` 第 82-91 行）：

```cpp
// utilities/transactions/optimistic_transaction.h:82-91
class OptimisticTransactionCallback : public WriteCallback {
 public:
  explicit OptimisticTransactionCallback(OptimisticTransaction* txn)
      : txn_(txn) {}

  Status Callback(DB* db) override {
    return txn_->CheckTransactionForConflicts(db);
  }

  bool AllowWriteBatching() override { return false; }
```

这个 `WriteCallback` 在 DB 的 write group 中执行，确保验证和写入是原子的。

#### 两大家族的选择指南

```
冲突频繁？
   |
   +-- 是 --> PessimisticTransactionDB (先锁后写，及早发现冲突)
   |
   +-- 否 --> OptimisticTransactionDB  (先写后验，减少锁开销)
```

### 1.4 写策略三兄弟：TxnDBWritePolicy

悲观事务家族内部还有一个关键维度：**数据何时写入 DB？** 这由 `TxnDBWritePolicy` 枚举控制（`transaction_db.h` 第 26-37 行）：

```cpp
// include/rocksdb/utilities/transaction_db.h:26-37
enum TxnDBWritePolicy {
  WRITE_COMMITTED = 0,   // 提交时写入
  WRITE_PREPARED,        // Prepare 阶段写入 (实验性)
  WRITE_UNPREPARED       // Prepare 之前写入 (实验性)
};
```

三种策略的区别如下：

| 策略 | 数据写入时机 | 可见性控制 | 适用场景 |
|------|------------|-----------|---------|
| `WRITE_COMMITTED` | Commit 时 | 天然隔离，只有已提交数据在 DB 中 | 默认策略，最成熟 |
| `WRITE_PREPARED` | Prepare 时 | 需要额外机制区分已提交/未提交数据 | 减少 Commit 延迟 |
| `WRITE_UNPREPARED` | 写入时即刻 | 需要更复杂的可见性判断 | 支持超大事务（避免内存溢出） |

每种策略对应不同的实现类：

- `WRITE_COMMITTED` -> `WriteCommittedTxnDB` + `WriteCommittedTxn`
- `WRITE_PREPARED` -> `WritePreparedTxnDB` + `WritePreparedTxn`
- `WRITE_UNPREPARED` -> `WriteUnpreparedTxnDB` + `WriteUnpreparedTxn`

`WRITE_COMMITTED` 是默认且最成熟的策略。`WRITE_PREPARED` 和 `WRITE_UNPREPARED` 标注为实验性（EXPERIMENTAL），主要服务于两阶段提交（2PC, Two-Phase Commit）场景，如 MyRocks（MySQL on RocksDB）。

用一个类比来理解：

- **WRITE_COMMITTED** 像"写完论文再提交"：改动只在最后一刻一次性写入。
- **WRITE_PREPARED** 像"草稿先存云端，确认后发布"：数据提前持久化，但标记为未发布。
- **WRITE_UNPREPARED** 像"边写边自动保存"：每一段改动都即时持久化，适合超长论文。

这三种策略构成了继承链中 `PessimisticTransaction` 下方的三个分支，每个分支都重写了 `PrepareInternal()`、`CommitInternal()` 和 `RollbackInternal()` 等关键方法，以实现各自的写入时序语义。

---

## 第二章 核心抽象层设计

### 2.1 TransactionBaseImpl：事务的"骨架"

如果说 `Transaction` 是事务的"接口规范"，那么 `TransactionBaseImpl` 就是事务的"骨架实现"。它位于继承体系的中间层，被悲观事务和乐观事务共同继承，承载了所有事务类型共享的核心逻辑。

用一个类比来理解：`TransactionBaseImpl` 就像一个"购物车"。不管你是在线下超市（悲观事务）还是线上商城（乐观事务）购物，购物车的基本功能都是一样的——往里放商品、查看已选商品、设置回退点、最终结账或清空。

#### 核心成员变量

`TransactionBaseImpl` 定义在 `utilities/transactions/transaction_base.h`，其关键成员如下：

```cpp
// utilities/transactions/transaction_base.h:380-445（关键成员摘录）

DB* db_;                     // 底层 DB 实例的引用
DBImpl* dbimpl_;             // DB 的内部实现（用于获取时钟、快照等）

WriteOptions write_options_; // 写入选项（如 sync 模式）

const Comparator* cmp_;      // key 的比较器

uint64_t start_time_;        // 事务创建时间（微秒）

std::shared_ptr<const Snapshot> snapshot_;  // 当前快照

uint64_t num_puts_ = 0;           // Put 操作计数
uint64_t num_put_entities_ = 0;   // PutEntity 操作计数
uint64_t num_deletes_ = 0;        // Delete 操作计数
uint64_t num_merges_ = 0;         // Merge 操作计数

WriteBatchWithIndex write_batch_;  // 事务写缓冲（带索引）

std::unique_ptr<LockTracker> tracked_locks_;  // 已跟踪的锁

std::unique_ptr<std::stack<SavePoint, autovector<SavePoint>>>
    save_points_;                  // 保存点栈
```

这些成员可以分为四个职责组：

- **写缓冲**：`write_batch_` —— 暂存事务内所有写操作
- **锁跟踪**：`tracked_locks_` —— 记录事务获取（或需要检查）的锁
- **快照管理**：`snapshot_` —— 提供一致性读取的基线
- **状态计数**：`num_puts_`、`num_deletes_` 等 —— 统计操作数量

#### TryLock：悲观与乐观的分水岭

`TransactionBaseImpl` 声明了一个纯虚方法 `TryLock`（`transaction_base.h` 第 44-47 行）：

```cpp
// utilities/transactions/transaction_base.h:44-47
virtual Status TryLock(ColumnFamilyHandle* column_family, const Slice& key,
                       bool read_only, bool exclusive,
                       const bool do_validate = true,
                       const bool assume_tracked = false) = 0;
```

这是悲观事务和乐观事务的核心分水岭：

- **悲观事务**的 `TryLock` 会真正去 `LockManager` 获取锁，可能阻塞等待或返回超时。
- **乐观事务**的 `TryLock` 只是在 `tracked_locks_` 中记录这个 key，不做任何阻塞操作。

所有的写操作（Put、Delete、Merge 等）都遵循相同的模式：先 TryLock，再写入 batch。以 `Put` 为例（`transaction_base.cc` 第 584-598 行）：

```cpp
// utilities/transactions/transaction_base.cc:584-598
Status TransactionBaseImpl::Put(ColumnFamilyHandle* column_family,
                                const Slice& key, const Slice& value,
                                const bool assume_tracked) {
  const bool do_validate = !assume_tracked;
  // 第一步：尝试加锁（悲观事务真加锁，乐观事务只记录）
  Status s = TryLock(column_family, key, false /* read_only */,
                     true /* exclusive */, do_validate, assume_tracked);

  if (s.ok()) {
    // 第二步：写入事务缓冲区
    s = GetBatchForWrite()->Put(column_family, key, value);
    if (s.ok()) {
      num_puts_++;
    }
  }

  return s;
}
```

#### TrackKey：锁追踪的内部实现

当 `TryLock` 成功后，具体的子类会调用 `TrackKey` 来记录这个 key（`transaction_base.cc` 第 823-840 行）：

```cpp
// utilities/transactions/transaction_base.cc:823-840
void TransactionBaseImpl::TrackKey(uint32_t cfh_id, const std::string& key,
                                   SequenceNumber seq, bool read_only,
                                   bool exclusive) {
  PointLockRequest r;
  r.column_family_id = cfh_id;  // 列族 ID
  r.key = key;                   // key 本身
  r.seq = seq;                   // 首次涉及此 key 的序列号
  r.read_only = read_only;       // 是否只读
  r.exclusive = exclusive;       // 是否排他锁

  // 更新全局锁追踪器
  tracked_locks_->Track(r);

  // 如果有活跃的 SavePoint，也更新它的锁追踪器
  if (save_points_ != nullptr && !save_points_->empty()) {
    save_points_->top().new_locks_->Track(r);
  }
}
```

注意最后的 SavePoint 联动——当存在保存点时，新获取的锁会同时记录在保存点中，以便回滚时精确释放。

### 2.2 WriteBatchWithIndex：事务的写缓冲区

#### 是什么

`WriteBatchWithIndex`（简称 WBWI）是 RocksDB 为事务场景专门设计的写缓冲区。它在标准 `WriteBatch` 的基础上增加了**二分搜索索引**，使得可以按 key 快速查找事务内的待提交写入。

用类比来理解：`WriteBatch` 像一个只能追加的日志本；`WriteBatchWithIndex` 则在日志本旁边附加了一份按字母排序的索引目录，让你能快速翻到某个 key 的最新记录。

#### 在事务中的角色

在 `TransactionBaseImpl` 的构造函数中（`transaction_base.cc` 第 61-81 行），`write_batch_` 被初始化为一个启用了 `overwrite_key` 的 WBWI：

```cpp
// utilities/transactions/transaction_base.cc:70
write_batch_(cmp_, 0, true, 0, write_options.protection_bytes_per_key),
//                     ^^^^ overwrite_key = true
```

`overwrite_key = true` 意味着对同一个 key 的多次写入，迭代器只返回最新的那一次。这对于事务语义至关重要——如果你先 Put("A", "1") 再 Put("A", "2")，读取时应该看到 "2"。

#### indexing_enabled_ 开关

`TransactionBaseImpl` 提供了 `DisableIndexing()` / `EnableIndexing()` 方法来控制是否对写入建索引（`transaction_base.h` 第 274-278 行）：

```cpp
// utilities/transactions/transaction_base.cc:847-855
WriteBatchBase* TransactionBaseImpl::GetBatchForWrite() {
  if (indexing_enabled_) {
    return &write_batch_;            // 走 WBWI，建索引
  } else {
    return write_batch_.GetWriteBatch();  // 走原始 WriteBatch，不建索引
  }
}
```

这是一个性能优化：如果调用方确定不需要在事务内读取这些 key（例如批量导入场景），关闭索引可以省去索引维护的开销。

### 2.3 读自己的写：GetFromBatchAndDB

#### 问题背景

事务内有一个经典需求：写入一个 key 后，还没提交，就想读取到刚才写入的值。这就是**读自己的写（Read Your Own Writes）** 语义。

挑战在于：事务的写入暂存在 `write_batch_` 中，还没有进入 DB。普通的 `DB::Get` 看不到这些未提交的数据。

#### 解决方案：两阶段查找

`TransactionBaseImpl::GetImpl` 的实现非常简洁（`transaction_base.cc` 第 286-292 行）：

```cpp
// utilities/transactions/transaction_base.cc:286-292
Status TransactionBaseImpl::GetImpl(const ReadOptions& read_options,
                                    ColumnFamilyHandle* column_family,
                                    const Slice& key,
                                    PinnableSlice* pinnable_val) {
  return write_batch_.GetFromBatchAndDB(db_, read_options, column_family, key,
                                        pinnable_val);
}
```

它将所有工作委托给 `WriteBatchWithIndex::GetFromBatchAndDB`。这个方法的核心逻辑可以用以下流程图表示：

```
          GetFromBatchAndDB(key)
                  |
    +-------------+-------------+
    |    第一阶段：查 Batch      |
    |   GetFromBatch(key)       |
    +-------------+-------------+
                  |
        +--------+---------+
        |        |         |
     kFound   kDeleted  kNotFound / kMergeInProgress
        |        |         |
   直接返回  返回      第二阶段：查 DB
   batch中  NotFound     DB::GetImpl(key)
   的值                    |
                     +-----+------+
                     |            |
                kNotFound    找到 DB 值
                     |            |
                  返回         如果有 Merge:
                NotFound      合并 batch 中的
                              Merge 操作数和
                              DB 中的 base value
                                  |
                              返回合并结果
```

第一阶段（`GetFromBatch`）的内部实现使用 WBWI 的索引快速定位 key（`write_batch_with_index_internal.cc` 第 804-909 行）：

```cpp
// utilities/write_batch_with_index/write_batch_with_index_internal.cc:813-818
std::unique_ptr<WBWIIteratorImpl> iter(
    static_cast_with_check<WBWIIteratorImpl>(
        batch->NewIterator(column_family)));

iter->Seek(key);                          // 利用索引快速定位
auto result = iter->FindLatestUpdate(key, context);  // 找到最新操作
```

`FindLatestUpdate` 会根据 key 上最新的操作类型返回不同结果：

- **Put/PutEntity** -> `kFound`：直接拿到值
- **Delete/SingleDelete** -> `kDeleted`：key 已被删除
- **Merge** -> `kMergeInProgress`：需要进一步与 DB 合并
- **不存在** -> `kNotFound`：batch 中没有这个 key

### 2.4 SavePoint 机制：事务内的回退点

#### 是什么

SavePoint（保存点）允许你在事务内部设置"存档点"。如果后续操作失败，可以回退到存档点，而不必放弃整个事务。

用游戏类比：事务的 Commit 是"通关存档"，Rollback 是"放弃本局"，而 SavePoint 则是"关卡内存档"——打 Boss 失败了可以从存档点重来，而不是从头开始。

#### SavePoint 的数据结构

`SavePoint` 定义为 `TransactionBaseImpl` 的内部结构体（`transaction_base.h` 第 402-430 行）：

```cpp
// utilities/transactions/transaction_base.h:402-430
struct SavePoint {
  std::shared_ptr<const Snapshot> snapshot_;
  bool snapshot_needed_ = false;
  std::shared_ptr<TransactionNotifier> snapshot_notifier_;
  uint64_t num_puts_ = 0;
  uint64_t num_put_entities_ = 0;
  uint64_t num_deletes_ = 0;
  uint64_t num_merges_ = 0;

  // 记录此保存点之后新获取的所有锁
  std::shared_ptr<LockTracker> new_locks_;
  // ...
};
```

#### RollbackToSavePoint 的实现

回滚保存点时（`transaction_base.cc` 第 187-213 行）：

```cpp
// utilities/transactions/transaction_base.cc:187-213
Status TransactionBaseImpl::RollbackToSavePoint() {
  if (save_points_ != nullptr && save_points_->size() > 0) {
    // 1. 恢复事务元数据
    TransactionBaseImpl::SavePoint& save_point = save_points_->top();
    snapshot_ = save_point.snapshot_;
    num_puts_ = save_point.num_puts_;
    num_deletes_ = save_point.num_deletes_;
    num_merges_ = save_point.num_merges_;

    // 2. 回滚 WriteBatchWithIndex 中的写入
    Status s = write_batch_.RollbackToSavePoint();

    // 3. 释放保存点之后获取的锁
    tracked_locks_->Subtract(*save_point.new_locks_);

    save_points_->pop();
    return s;
  } else {
    return Status::NotFound();
  }
}
```

回滚分三步：

1. **恢复元数据**：从保存点恢复快照引用和操作计数
2. **回滚写入**：`write_batch_.RollbackToSavePoint()` 丢弃保存点之后的所有写操作
3. **释放锁**：`tracked_locks_->Subtract(*save_point.new_locks_)` 从全局锁追踪器中移除保存点之后获取的锁

```
事务时间线：
  Begin -> Put(A) -> SetSavePoint -> Put(B) -> Put(C) -> RollbackToSavePoint
                          |                                       |
                     保存: {A}                          恢复到: {A}
                                                       B 和 C 的写入被丢弃
                                                       B 和 C 的锁被释放
```

### 2.5 快照管理：一致性读取的基线

#### SetSnapshot：获取一致性视图

快照（Snapshot）是 RocksDB 的 MVCC（多版本并发控制）机制的核心。设置快照后，事务内的冲突检测将基于快照时间点。

`SetSnapshot` 的实现（`transaction_base.cc` 第 125-137 行）：

```cpp
// utilities/transactions/transaction_base.cc:125-137
void TransactionBaseImpl::SetSnapshot() {
  const Snapshot* snapshot = dbimpl_->GetSnapshotForWriteConflictBoundary();
  SetSnapshotInternal(snapshot);
}

void TransactionBaseImpl::SetSnapshotInternal(const Snapshot* snapshot) {
  // 使用自定义 deleter：快照需要被 Release，而不是 delete
  snapshot_.reset(snapshot, std::bind(&TransactionBaseImpl::ReleaseSnapshot,
                                      this, std::placeholders::_1, db_));
  snapshot_needed_ = false;
  snapshot_notifier_ = nullptr;
}
```

#### SetSnapshotOnNextOperation：延迟快照

有时候，你希望快照尽可能"新鲜"。`SetSnapshotOnNextOperation` 在下一次 Put/Delete/GetForUpdate 操作时才真正创建快照，最大限度地缩小了快照创建与首次操作之间的时间窗口。

```
// 防止以下竞态：
//   txn1->SetSnapshot();
//                             txn2->Put("A", ...);
//                             txn2->Commit();
//   txn1->GetForUpdate(opts, "A", ...);  // 失败！
//
// 使用 SetSnapshotOnNextOperation 后：
//   txn1->SetSnapshotOnNextOperation();
//   txn1->GetForUpdate(opts, "A", ...);
//   // 快照在 GetForUpdate 内部创建，紧挨着冲突检查
```

---

## 第三章 乐观事务（Optimistic Concurrency Control）

### 3.1 设计哲学：先写再说，提交时算账

悲观事务（Pessimistic Transaction）就像一个谨慎的人——每次操作数据前都先加锁，确保没人能碰这块数据。这种方式安全但代价高昂：每次加锁都需要与锁管理器交互，高并发时锁竞争会成为严重的瓶颈。

乐观事务（Optimistic Transaction）则像一个大胆的人——先放手去做，等到最后提交时再回头检查有没有人在此期间动过同样的数据。如果没有冲突，提交成功；如果有冲突，事务失败，由调用方决定是否重试。

这就是 OCC（Optimistic Concurrency Control，乐观并发控制）的核心思想：

- **写入阶段**：不加任何锁，只记录"我打算操作哪些 key"
- **验证阶段**：提交时检查这些 key 在事务期间是否被其他写入修改过
- **提交阶段**：验证通过则原子写入，否则返回 `Status::Busy`

### 3.2 TryLock：只记录，不加锁

当事务执行 `Put()`、`Delete()`、`GetForUpdate()` 等操作时，基类 `TransactionBaseImpl` 会调用虚函数 `TryLock()`。在乐观事务中，它只是记录 key 和当前序列号。

以下是 `optimistic_transaction.cc`（第 158-184 行）的实现：

```cpp
Status OptimisticTransaction::TryLock(ColumnFamilyHandle* column_family,
                                      const Slice& key, bool read_only,
                                      bool exclusive, const bool do_validate,
                                      const bool assume_tracked) {
  if (!do_validate) {
    return Status::OK();    // 不需要验证的写入（如 PutUntracked），直接跳过
  }

  uint32_t cfh_id = GetColumnFamilyID(column_family);

  SetSnapshotIfNeeded();    // 如果设置了 SetSnapshotOnNextOperation，在此刻拍快照

  SequenceNumber seq;
  if (snapshot_) {
    seq = snapshot_->GetSequenceNumber();   // 使用事务快照的序列号
  } else {
    seq = db_->GetLatestSequenceNumber();   // 没有快照则使用当前最新序列号
  }

  std::string key_str = key.ToString();

  // 将 key 及其序列号记录到 tracked_locks_ 中
  // 这里不加任何锁，只是"记个账"
  TrackKey(cfh_id, key_str, seq, read_only, exclusive);

  // 永远返回 OK——冲突检测推迟到 Commit 时
  return Status::OK();
}
```

关键点在于 `TrackKey()` 方法。它将 `(column_family_id, key, sequence_number)` 三元组记录到 `tracked_locks_` 这个 `LockTracker` 对象中。这个序列号至关重要——它标记了"我在这个时间点读/写了这个 key"，提交时会用来判断是否有人在此之后修改了同一个 key。

### 3.3 冲突检测流程

冲突检测是乐观事务的核心。整个流程可以用一句话概括：**逐个检查事务追踪的每个 key，看它在数据库中的最新序列号是否超过了事务记录时的序列号**。

#### 入口：CheckTransactionForConflicts

`CheckTransactionForConflicts()`（`optimistic_transaction.cc` 第 192-201 行）委托给 `TransactionUtil`：

```cpp
Status OptimisticTransaction::CheckTransactionForConflicts(DB* db) {
  auto db_impl = static_cast_with_check<DBImpl>(db);

  // 在写线程中运行，不希望阻塞其他写入
  // 因此只做 cache-only 检查（仅查 MemTable，不查 SST 文件）
  return TransactionUtil::CheckKeysForConflicts(db_impl, *tracked_locks_,
                                                true /* cache_only */);
}
```

这里 `cache_only = true` 是一个重要的性能权衡：只检查 MemTable 中的数据，不读取 SST 文件。如果 MemTable 中的历史不够长（key 已经被 flush 到磁盘），检测会返回 `Status::TryAgain` 而非误判。

#### 单 key 检测核心逻辑

真正的冲突判定逻辑在 `TransactionUtil::CheckKey()` 中（`transaction_util.cc` 第 50-152 行）。算法的核心可以用一个不等式表达：

```
如果 db_latest_seq(key) > txn_snapshot_seq(key) → 冲突（Status::Busy）
如果 db_latest_seq(key) <= txn_snapshot_seq(key) → 安全（Status::OK）
```

打个比方：事务在第 100 号时刻"看了一眼"某个 key，提交时发现这个 key 在第 105 号时刻被别人改过了——这就是冲突。如果没人改过，或者只有第 100 号之前的修改，那就没有冲突。

### 3.4 串行验证 vs 并行验证

RocksDB 为乐观事务提供了两种验证策略，对应枚举 `OccValidationPolicy`：

```cpp
enum class OccValidationPolicy {
  kValidateSerial = 0,    // 串行验证：在 write-group 之后验证
  kValidateParallel = 1   // 并行验证：在 write-group 之前验证
};
```

#### 串行验证

串行验证通过 `WriteCallback` 机制在写线程内完成验证和写入，由全局写互斥锁保证原子性：

```cpp
Status OptimisticTransaction::CommitWithSerialValidate() {
  OptimisticTransactionCallback callback(this);
  DBImpl* db_impl = static_cast_with_check<DBImpl>(db_->GetRootDB());
  Status s = db_impl->WriteWithCallback(
      write_options_, GetWriteBatch()->GetWriteBatch(), &callback);
  if (s.ok()) {
    Clear();
  }
  return s;
}
```

**优点**：实现简单，验证与写入之间绝对不会有其他写入插入。**缺点**：所有事务排队经过同一个全局写锁，高并发下成为瓶颈。

#### 并行验证

并行验证用分桶互斥锁替代全局写锁，让操作不同 key 的事务可以并行验证：

```cpp
Status OptimisticTransaction::CommitWithParallelValidate() {
  // 第一步：收集所有需要的锁桶指针
  std::set<port::Mutex*> lk_ptrs;  // 使用 set 保证指针地址有序
  // ... 遍历 tracked_locks_ 中的所有 key，映射到锁桶 ...

  // 第二步：按指针地址升序加锁（防止死锁）
  for (auto v : lk_ptrs) {
    v->Lock();
  }

  // 第三步：在持有分桶锁的情况下检测冲突
  Status s = TransactionUtil::CheckKeysForConflicts(db_impl, *tracked_locks_,
                                                    true /* cache_only */);

  // 第四步：验证通过，直接写入
  if (s.ok()) {
    s = db_impl->Write(write_options_, GetWriteBatch()->GetWriteBatch());
  }
  // 解锁 ...
}
```

精妙设计：使用 `std::set<port::Mutex*>` 按指针地址自动排序，确保所有事务以相同顺序获取锁，避免死锁。

| 特性 | 串行验证 (kValidateSerial) | 并行验证 (kValidateParallel) |
|------|--------------------------|----------------------------|
| 锁粒度 | 全局写互斥锁 | 分桶互斥锁（默认约 100 万个桶） |
| 并发度 | 低——所有事务排队验证 | 高——操作不同 key 的事务可并行 |
| 默认策略 | 否 | **是** |

### 3.5 适用场景与局限

**适合乐观事务的场景**：
- 低冲突工作负载（按用户分区、UUID 主键）
- 读多写少
- 短事务
- 对延迟敏感

**适合悲观事务的场景**：
- 高冲突（热点计数器、库存扣减）
- 长事务
- 需要 2PC
- 需要死锁检测

**乐观事务的局限**：
- 不支持 DeleteRange
- 不支持两阶段提交（`Prepare()` 返回 `InvalidArgument`）
- MemTable 历史依赖：需要合理配置 `max_write_buffer_size_to_maintain`

---

## 第四章 悲观事务与锁管理

### 4.1 悲观事务的设计哲学

悲观事务假设冲突频繁，在每次写操作发生之前就立即加锁。可以用收费停车场来类比——进场前先拿到车位锁才能停进去。好处是冲突在发生时就被拦截，事务不会在最后提交阶段因为冲突而功亏一篑。

#### TryLock() —— 悲观事务的灵魂

每当事务执行写操作时，底层都会调用 `TryLock()` 来在 LockManager 中获取对应 key 的锁（`pessimistic_transaction.cc` 第 1138-1254 行）：

```
TryLock(key)
    |
    v
[已被当前事务锁定?] ---是---> [需要升级?] ---否---> 直接返回 OK
    |                            |
    否                           是
    |                            |
    v                            v
[txn_db_impl_->TryLock()] <-----+   // 委托给 LockManager
    |
    v
[有 snapshot?] ---是---> ValidateSnapshot()
    |                        |
    否                   失败? ---> 释放锁，返回错误
    |                        |
    v                     成功
[TrackKey() 记录锁] <------+
    |
    v
  返回 OK
```

`TryLock()` 不仅仅是加锁，还集成了快照验证（Snapshot Validation）。如果事务设置了快照，加锁后还要检查该 key 自快照以来是否被其他事务修改过。这保证了快照隔离语义。

#### 事务 ID 管理

每个悲观事务都有全局唯一的事务 ID，用于死锁检测和锁持有者标识：

```cpp
std::atomic<TransactionID> PessimisticTransaction::txn_id_counter_(1);

TransactionID PessimisticTransaction::GenTxnID() {
  return txn_id_counter_.fetch_add(1);  // 原子自增
}
```

Range Lock Manager 使用事务对象的内存地址作为 ID，因为底层 locktree 库使用指针来标识事务。

### 4.2 PessimisticTransactionDB

`PessimisticTransactionDB` 在底层 `DBImpl` 之上添加了事务管理和锁管理能力。

```cpp
class PessimisticTransactionDB : public TransactionDB {
  DBImpl* db_impl_;
  const TransactionDBOptions txn_db_options_;
  std::shared_ptr<LockManager> lock_manager_;     // 核心！
};
```

LockManager 通过工厂方法 `NewLockManager()` 创建：

```
NewLockManager()
    |
    +-- opt.lock_mgr_handle 存在? --> 使用自定义锁管理器（如 Range Lock）
    |
    +-- opt.use_per_key_point_lock_mgr? --> PerKeyPointLockManager
    |
    +-- 默认 --> PointLockManager（分片点锁，最常用）
```

### 4.3 Point Lock Manager 的分片架构

点锁管理器通过分片（Striping）来降低锁竞争。如果把所有 key 的锁信息放在一个全局 hash map 里，高并发场景下就会成为瓶颈。分片设计将锁信息分散到多个独立的"条带"（Stripe）中。

核心数据结构的层次关系：

```
PointLockManager
    |
    +-- lock_maps_ : Map<ColumnFamilyId, LockMap*>   (每个 CF 一个 LockMap)
            |
            +-- LockMap
                  |
                  +-- lock_map_stripes_ : vector<LockMapStripe*>  (N 个分片)
                        |
                        +-- LockMapStripe
                              |
                              +-- stripe_mutex   (每个分片独立的互斥锁)
                              +-- stripe_cv      (条件变量，用于等待通知)
                              +-- keys : Map<string, LockInfo>  (key -> 锁信息)
```

#### LockInfo —— 每个 key 的锁状态

```cpp
struct LockInfo {
  bool exclusive;                     // 是否独占锁
  autovector<TransactionID> txn_ids;  // 持锁事务 ID 列表
  uint64_t expiration_time;           // 锁的过期时间
  std::unique_ptr<std::list<KeyLockWaiter*>> waiter_queue; // 等待队列
};
```

共享锁 vs 独占锁的兼容性矩阵：

```
            请求方
          Shared    Exclusive
持有方
 Shared    允许       冲突
Exclusive  冲突       冲突（除非同一事务）
```

### 4.4 死锁检测

死锁检测的核心是构建"等待图"（Wait-For Graph），然后检测环。PointLockManager 使用 BFS（广度优先搜索）遍历实现：

```
事务 T1 等待 T2，T2 等待 T3，T3 等待 T1

等待图：T1 --> T2 --> T3 --> T1  （环！）

BFS 从 T1 出发：
  head=0: 检查 T2（T1 等待的对象）
  head=1: 检查 T3（T2 等待的对象）
  head=2: 检查 T1 —— 发现 next == id，死锁！
```

死锁检测到的路径记录在环形缓冲区 `DeadlockInfoBuffer` 中，用户可通过 `TransactionDB::GetDeadlockInfoBuffer()` 获取诊断信息。

死锁检测是可配置的：

| 参数 | 含义 |
|------|------|
| `TransactionOptions::deadlock_detect` | 是否启用死锁检测 |
| `TransactionOptions::deadlock_detect_depth` | BFS 搜索最大深度 |
| `TransactionOptions::deadlock_timeout_us` | 死锁检测触发前的延迟 |

### 4.5 Range Lock Manager

范围锁管理器用于锁定一个 **key 范围**，基于 PerconaFT（原 TokuDB）的 locktree 库。

| 特性 | 点锁 (PointLockManager) | 范围锁 (RangeTreeLockManager) |
|------|------------------------|------------------------------|
| 锁粒度 | 单个 key | key 范围 [start, end] |
| 冲突检测 | 精确匹配 | 范围重叠检测 |
| 幻读防护 | 不支持 | 支持 |
| 数据结构 | 哈希表 + 分片 | 平衡二叉树 |

范围锁支持**锁升级（Lock Escalation）**：当锁数量过多时，将同一事务持有的多个小范围锁合并为一个更大的范围锁，减少内存占用。代价是可能产生"假冲突"。

### 4.6 LockTracker 接口

每个事务通过 `LockTracker` 记录"我持有了哪些锁"，类比为"钥匙串"。

```cpp
class LockTracker {
 public:
  virtual void Track(const PointLockRequest& lock_request) = 0;
  virtual UntrackStatus Untrack(const PointLockRequest& lock_request) = 0;
  virtual void Merge(const LockTracker& tracker) = 0;
  virtual void Subtract(const LockTracker& tracker) = 0;
  virtual PointLockStatus GetPointLockStatus(
      ColumnFamilyId cf_id, const std::string& key) const = 0;
};
```

`PointLockTracker` 的内部数据结构是两层嵌套哈希表：`CF ID -> (key -> TrackedKeyInfo)`。`TrackedKeyInfo` 中的 `num_reads` 和 `num_writes` 引用计数机制使得 SavePoint 回滚时能正确判断哪些锁可以安全释放。

---

## 第五章 三种写入策略（Write Policy）

三种策略决定了**数据在什么时机被写入 MemTable**：

- **Write-Committed**：先攒着，最后一口气搬家
- **Write-Prepared**：提前搬行李进新房，但不告诉邻居你已经住了
- **Write-Unprepared**：行李太多，边打包边搬进新房

### 5.1 Write-Committed：默认策略

事务执行期间，所有写操作只缓存在内存中的 WriteBatch 里，直到 Commit 时才一次性原子地写入 MemTable。

```
  Write-Committed 提交流程
  ========================

  txn->Put(k1,v1) ──┐
  txn->Put(k2,v2) ──┤  缓存阶段：所有写操作追加到 WriteBatch
  txn->Delete(k3) ──┘

  txn->Commit() ─────→ db_impl_->WriteImpl(wb)
                          │
                          ├──→ 写 WAL（持久化）
                          └──→ 写 MemTable（可见）
```

**优点**：最简单、最成熟、读取零开销。**缺点**：大事务内存压力大、2PC Commit 是性能瓶颈。

### 5.2 Write-Prepared：为 2PC 而生

数据在 Prepare 阶段就写入 MemTable，但通过一套 commit 缓存（CommitCache）机制控制数据的可见性。

```
  Write-Prepared 两阶段提交流程
  ==============================

  Phase 1: Prepare
  ─────────────────
  txn->Prepare()       → WriteImpl(!DISABLE_MEMTABLE)
                           │
                           ├──→ WAL: Put(k1,v1) + EndPrepare(txn1)  [prepare_seq]
                           ├──→ MemTable: Put(k1,v1)                [prepare_seq]
                           └──→ PreparedHeap.push(prepare_seq)

  Phase 2: Commit
  ─────────────────
  txn->Commit()        → WriteImpl(DISABLE_MEMTABLE)
                           │
                           ├──→ WAL: Commit(txn1)                   [commit_seq]
                           ├──→ CommitCache[prepare_seq] = commit_seq
                           └──→ PreparedHeap.erase(prepare_seq)
```

#### CommitCache：高效的提交记录缓存

默认大小 `2^23 = 8,388,608` 个条目。每个条目只占 64 位（`CommitEntry64b`），通过存储 `delta = commit_seq - prepare_seq + 1` 实现紧凑编码。

#### IsInSnapshot()：核心可见性判断

```
  IsInSnapshot(prep_seq, snapshot_seq) 判断流程
  =============================================

  ① prep_seq == 0 ?                    ──→ 返回 true（compaction 输出）
  ② snapshot_seq < prep_seq ?           ──→ 返回 false（快照太旧）
  ③ prep_seq < min_uncommitted ?        ──→ 返回 true（一定已提交）
  ④ CommitCache[prep_seq % SIZE] 命中?  ──→ 返回 commit_seq <= snapshot_seq
  ⑤ max_evicted_seq < prep_seq ?        ──→ 返回 false（未驱逐=未提交）
  ⑥ delayed_prepared_ 中存在?           ──→ 检查 delayed_prepared_commits_
  ⑦ max_evicted_seq < snapshot_seq ?    ──→ 返回 true（一定可见）
  ⑧ old_commit_map_[snapshot_seq] 中?   ──→ 存在则 false，不存在则 true
```

#### PreparedHeap：追踪进行中的 Prepare 事务

使用双端队列 + 懒删除堆实现 O(1) 的最小值查询：

- 主队列用 `deque`（prepare_seq 是严格递增的）
- `erase` 操作不直接删除，记入 `erased_heap_`
- `top()` 用原子变量提供无锁读取

### 5.3 Write-Unprepared：极致的内存优化

数据甚至在 Prepare 之前就可以增量地写入 MemTable。当 WriteBatch 数据量超过阈值时自动刷盘：

```
  Write-Unprepared 增量刷盘流程
  =============================

  txn->Put(k1,v1)  ──→ HandleWrite()
  txn->Put(k2,v2)  ──→ HandleWrite()
  txn->Put(k3,v3)  ──→ HandleWrite() → 超阈值 → FlushWriteBatchToDB()
                                          │
                                          ├──→ WAL + MemTable [unprep_seq_1]
                                          └──→ 重置 WriteBatch

  txn->Prepare()   ──→ FlushWriteBatchToDB(kPrepared)  // 最终批次
  txn->Commit()    ──→ 为所有 unprep_seqs_ 更新 CommitCache
```

自读未提交数据通过 `WriteUnpreparedTxnReadCallback` 实现：先检查是不是自己写的（遍历 `unprep_seqs_`），如果不是再走 `IsInSnapshot()` 标准路径。

### 5.4 三种策略对比

| 对比维度 | Write-Committed | Write-Prepared | Write-Unprepared |
|---------|----------------|---------------|-----------------|
| **写入时机** | Commit 时 | Prepare 时 | 事务执行中增量 |
| **内存占用** | 高 | 中 | 低 |
| **可见性判断** | 无需额外判断 | CommitCache + IsInSnapshot() | CommitCache + unprep_seqs_ |
| **Commit 开销** | 高（写 WAL + MemTable） | 低（只写 WAL 标记） | 低 |
| **恢复复杂度** | 低 | 中 | 高 |
| **成熟度** | 生产就绪 | 实验性 | 实验性 |
| **典型用户** | 通用场景 | MySQL/MyRocks | 超大事务场景 |

从继承关系也能看出这种递进设计：

```
  PessimisticTransaction
       │
       ├── WriteCommittedTxn          # 最简单
       │
       └── WritePreparedTxn           # 增加 CommitCache
               │
               └── WriteUnpreparedTxn # 增加增量刷盘
```

---

## 第六章 两阶段提交（2PC）

### 6.1 2PC 概述

两阶段提交（Two-Phase Commit，简称 2PC）是分布式系统中保证跨参与者事务原子性的经典协议。RocksDB 引入 2PC 的直接驱动力是 MySQL/MyRocks：

1. 事务开始，写入操作缓存在 `WriteBatchWithIndex` 中
2. MySQL 调用 `Prepare()`，RocksDB 将数据写入 WAL
3. MySQL 写 binlog
4. MySQL 调用 `Commit()`，RocksDB 将数据写入 memtable

如果在步骤 2 和 3 之间崩溃，MySQL 恢复时调用 `Rollback()`。如果在步骤 3 和 4 之间崩溃，MySQL 重新调用 `Commit()`。

### 6.2 事务状态机

```cpp
enum TransactionState {
  STARTED = 0,           // 事务已开始
  AWAITING_PREPARE = 1,  // 正在 Prepare（过渡状态）
  PREPARED = 2,          // Prepare 完成
  AWAITING_COMMIT = 3,   // 正在 Commit（过渡状态）
  COMMITTED = 4,         // 已提交
  AWAITING_ROLLBACK = 5, // 正在 Rollback（过渡状态）
  ROLLEDBACK = 6,        // 已回滚
  LOCKS_STOLEN = 7,      // 事务过期，锁已被窃取
};
```

```
              ┌─────────┐   Prepare()           ┌──────────────────┐
              │ STARTED  │──────────────────────►│AWAITING_PREPARE  │
              └────┬─────┘                      └───────┬──────────┘
                   │                                    │
                   │ Commit()                           │ 成功
                   │ (skip_prepare)                     ▼
                   │                            ┌───────────┐
                   │                            │ PREPARED   │
                   │                            └──┬─────┬──┘
                   │                      Commit() │     │ Rollback()
                   ▼                               ▼     ▼
            ┌──────────────┐              ┌──────────────────────┐
            │AWAITING_COMMIT│              │ AWAITING_ROLLBACK    │
            └──────┬───────┘              └───────────┬──────────┘
                   ▼                                  ▼
            ┌───────────┐                     ┌────────────┐
            │ COMMITTED  │                    │ ROLLEDBACK  │
            └───────────┘                     └────────────┘
```

过渡状态（AWAITING_xxx）是并发安全的核心。当事务可能过期时，使用 CAS 操作进行原子状态转换，防止与锁窃取竞争。

### 6.3 WAL 中的 2PC 标记

RocksDB 在 WAL 中通过特殊的标记类型记录 2PC 各阶段：

```
┌────────────────────────────────────────────────────────┐
│  Prepare 记录（一个 WriteBatch）                        │
│  ┌──────────────────────────────────────────────────┐  │
│  │ kTypeBeginPrepareXID (0x09)                      │  │ ← 开始标记
│  │ Put(cf, key1, val1)                              │  │ ← 用户写入
│  │ Delete(cf, key2)                                 │  │
│  │ kTypeEndPrepareXID | length | xid_name           │  │ ← 结束标记+事务名
│  └──────────────────────────────────────────────────┘  │
├────────────────────────────────────────────────────────┤
│  Commit 记录                                           │
│  ┌──────────────────────────────────────────────────┐  │
│  │ kTypeCommitXID (0x0B) | length | xid_name        │  │ ← 提交标记+事务名
│  │ [可选: CommitTimeWriteBatch 数据]                 │  │
│  └──────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────┘
```

不同 WritePolicy 使用不同的 BeginPrepare 标记，防止切换写策略后旧 WAL 被错误解析。

`MarkEndPrepare` 函数的巧妙设计："先写 Noop 占位、后改写为 BeginPrepare"——避免在 WriteBatch 头部插入数据导致的内存搬移。

### 6.4 崩溃恢复

#### WAL 重放阶段

WAL 重放时，`MemTableInserter` 的回调方法识别 2PC 标记：

- 遇到 `BeginPrepare`：开始收集写操作到临时 WriteBatch
- 遇到 `EndPrepare`：将收集到的 WriteBatch 存入 `recovered_transactions_`
- 遇到 `Commit`：通过事务名查找 prepared 事务并重放数据
- 遇到 `Rollback`：删除对应的 recovered 事务

#### 重建阶段

WAL 重放结束后，残留的只有 Prepare 没有 Commit/Rollback 的事务被 `PessimisticTransactionDB` 重建为"真正的"事务对象，状态设为 PREPARED。

应用层（如 MyRocks）通过 `GetAllPreparedTransactions()` 获取这些事务，根据 binlog 状态决定 `Commit()` 还是 `Rollback()`。

### 6.5 CommitTimeWriteBatch

`GetCommitTimeWriteBatch()` 返回一个特殊的 WriteBatch，其中的数据只在事务提交时才被写入。典型用例是 MyRocks 中的 GTID（Global Transaction ID）。

```cpp
Transaction* txn = db->BeginTransaction(write_options, txn_options);
// ... 正常的事务操作 ...
txn->GetCommitTimeWriteBatch()->Put("cat", "dog");
txn->Commit();  // "cat" -> "dog" 与事务数据一起原子写入
```

**重要限制**：CommitTimeWriteBatch 中的数据**绕过并发控制**。对于 WritePrepared/WriteUnprepared 模式，需要 `use_only_the_last_commit_time_batch_for_recovery` 标志才能使用。

---

## 第七章 冲突检测机制深入

### 7.1 TransactionUtil::CheckKeyForConflicts() 源码解析

冲突检测的核心问题：**检查自从事务获取快照以来，某个 key 是否被其他事务修改过**。

#### SuperVersion

`CheckKeyForConflicts` 首先获取 column family 的 SuperVersion——一个轻量级快照结构，包含：
- `mem`：当前活跃的 MemTable
- `imm`：不可变 MemTable 列表
- `current`：当前 LSM-tree 的 Version（所有 SST 文件信息）

#### CheckKey 核心逻辑

算法分三个阶段：

**阶段一：判断 MemTable 是否覆盖足够历史**

```
时间线：  [earliest_seq] -------- [snap_seq] -------- [current_seq]

情况 1: earliest_seq <= snap_seq  =>  memtable 覆盖了快照之后的写入，OK
情况 2: snap_seq < earliest_seq   =>  memtable 可能漏掉写入，需要读 SST
```

**阶段二：查找 key 的最新序列号**

```cpp
Status s = db_impl->GetLatestSequenceForKey(
    sv, key, !need_to_read_sst, lower_bound_seq, &seq,
    !read_ts ? nullptr : &timestamp, &found_record_for_key, nullptr);
```

**阶段三：比较序列号判定冲突**

```cpp
// 普通模式：snap_seq < seq 就是冲突
// Write-Prepared：使用 snap_checker 判断可见性
bool write_conflict = snap_checker == nullptr
                          ? snap_seq < seq
                          : !snap_checker->IsVisible(seq);

// UDT 扩展：基于用户自定义时间戳的额外检查
if (enable_udt_validation && !write_conflict && read_ts != nullptr) {
  write_conflict = ucmp->CompareTimestamp(*read_ts, timestamp) < 0;
}
```

### 7.2 GetLatestSequenceForKey：分层搜索

按 RocksDB 数据分层结构自顶向下搜索，只要序列号不要值（性能优化）：

```
搜索顺序：
┌──────────────────────────────────┐
│  1. Active MemTable (sv->mem)     │  ← 最新的写入
├──────────────────────────────────┤
│  2. Immutable MemTables (sv->imm) │  ← 等待 flush
├──────────────────────────────────┤
│  3. MemTable History              │  ← 已 flush 但保留的历史
├──────────────────────────────────┤
│  4. SST Files (sv->current)       │  ← 持久化数据（仅 cache_only=false）
└──────────────────────────────────┘
```

### 7.3 快照序列号机制

RocksDB 为每次写入分配单调递增的 64 位序列号。快照的序列号就是"读时间戳"：

```
写入操作     序列号
─────────  ──────
Put(a, 1)    100
Put(b, 2)    101
Delete(a)    102
Put(a, 3)    103

snapshot_seq = 102 → 能看到 seq <= 102 的所有已提交写入
```

不同事务模型下的差异：
- **Write-Committed**：`prepare_seq == commit_seq`，比较直接
- **Write-Prepared**：`prepare_seq != commit_seq`，需要 `IsInSnapshot()` 判断
- **Write-Unprepared**：多个 `unprepared_seq` + `commit_seq`

### 7.4 Write-Prepared 的 IsInSnapshot() 详解

该方法是整个 Write-Prepared 方案的灵魂，依赖以下数据结构：

```
WritePreparedTxnDB
├── commit_cache_[]        // 固定大小数组：prep_seq → commit_seq 映射
├── prepared_txns_         // PreparedHeap：追踪未提交的 prepare 序列号
├── max_evicted_seq_       // 被驱逐的最大 commit 序列号
├── delayed_prepared_      // 长事务集合（正常情况下为空）
└── old_commit_map_        // 为旧快照保留的驱逐条目
```

算法通过精巧的并发控制（双重读取 `max_evicted_seq_`、先读 `delayed_prepared_empty_` 再查 cache）处理竞态条件，确保在无锁热路径上的正确性。

### 7.5 Write-Unprepared 的读回调

```cpp
bool WriteUnpreparedTxnReadCallback::IsVisibleFullCheck(SequenceNumber seq) {
  // 第一步：检查是否属于自己的未 prepare 写入
  for (const auto& it : unprep_seqs_) {
    if (it.first <= seq && seq < it.first + it.second) {
      return true;  // 自己的写入，可见！
    }
  }
  // 第二步：委托 Write-Prepared 的可见性判断
  return db_->IsInSnapshot(seq, wup_snapshot_, min_uncommitted_, &snap_released);
}
```

### 7.6 SnapshotChecker：保护未提交数据不被 Compaction 丢弃

```cpp
SnapshotCheckerResult WritePreparedSnapshotChecker::CheckInSnapshot(
    SequenceNumber sequence, SequenceNumber snapshot_sequence) const {
  bool in_snapshot = txn_db_->IsInSnapshot(sequence, snapshot_sequence,
                                           kMinUnCommittedSeq, &snapshot_released);
  return in_snapshot ? kInSnapshot : kNotInSnapshot;
}
```

Compaction 使用与读操作完全相同的可见性算法判断数据的提交状态，确保 prepared-but-uncommitted 的数据不会被错误丢弃。

---

## 第八章 设计决策总结与权衡分析

### 8.1 为什么同时支持 OCC 和 PCC？

不同工作负载特征需要不同策略：

- **OCC**：低冲突时省去锁开销，事务执行期间不阻塞其他事务
- **PCC**：高冲突时及早发现冲突，避免 OCC 中"大量工作在提交时全部白费"

具体场景：100 个事务同时更新同一个热点 key：
- OCC：100 个事务都执行到提交，但只有 1 个成功，99 个白费
- PCC：第 1 个获取锁后，其余 99 个立即排队或超时，不做无谓工作

### 8.2 为什么 Write-Prepared/Write-Unprepared 标记为 EXPERIMENTAL？

- **可见性逻辑复杂**：需要 CommitCache、PreparedHeap、delayed_prepared 等多个辅助结构
- **恢复边界情况多**：Prepare 时数据已写入 memtable，崩溃恢复需重建 commit_map
- **与其他功能兼容性有限**：不支持部分迭代器类型，CommitTimeWriteBatch 需要特殊标志
- **测试覆盖面不足**：主要由 MyRocks 团队验证，社区场景覆盖不够

### 8.3 锁分片数量的工程权衡

默认分片数 16：

| 因素 | 分片数少 | 分片数多 |
|------|---------|---------|
| 锁竞争 | 高 | 低 |
| 内存开销 | 低 | 高 |
| 缓存效率 | 好 | 差 |

大多数部署中并发事务在几十到几百，16 个分片已有效分散竞争。每个 Column Family 独立创建分片，所以分片数 × CF 数量 = 实际总数。

### 8.4 WriteBatchWithIndex 作为事务缓冲区的优劣

**优势**：
- 读己之写：跳表索引支持 `GetFromBatchAndDB`
- SavePoint：精确回滚到检查点
- 有序遍历：与 DB 迭代器高效归并
- 批量写入：直接传给 `DB::Write()`

**劣势**：
- 内存开销：跳表节点的额外指针和引用
- 大事务风险：OOM（这是 WriteUnprepared 被提出的直接原因）
- 索引维护成本：每次写操作 O(log N)

### 8.5 接口抽象的分层设计

RocksDB 的分层抽象使不同策略自由组合：

- **LockManager 接口**：允许 PointLockManager、RangeTreeLockManager 或自定义实现
- **LockTracker 接口**：由 LockTrackerFactory 创建匹配的追踪器
- **Transaction/TransactionDB 分层**：公共逻辑下沉到基类，策略特定逻辑在子类
- **OCC 独立继承链**：因为冲突检测机制完全不同，不强行统一

### 8.6 与其他系统的对比

| 方面 | RocksDB | InnoDB | PostgreSQL |
|------|---------|--------|------------|
| 存储结构 | LSM-tree（追加写） | B+ tree（原地更新） | 堆表 |
| Undo 日志 | 不需要 | 需要 | 通过元组多版本 |
| MVCC 实现 | 序列号 + 快照 | undo log 链 + ReadView | 事务 ID 可见性映射 |
| 写放大来源 | Compaction | 页分裂 + undo log | WAL + vacuum |
| 锁粒度 | key 级/范围级 | 行锁 + 间隙锁 | 行锁 |

RocksDB 的独特之处：

- **无原地更新**：写操作永远是追加的，回滚不需要恢复旧值
- **WriteBatch 原子性**：2PC 直接利用 WriteBatch 机制
- **可插拔写策略**：三种策略在同一框架下共存
- **Compaction 感知**：可见性判断需与 Compaction 协同（SnapshotChecker）

---

> 本文基于 RocksDB 源码分析，所有代码引用均标注了文件路径和行号。由于源码持续演进，行号可能随版本变化，请以最新源码为准。
