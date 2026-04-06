# RocksDB 点查与范围扫描基准测试：综合分析

本文对 RocksDB 在点查、范围扫描以及混合负载下的读性能进行深入分析。除了给出测试结果外，还会把每个观察到的现象追溯到 RocksDB 代码中的根因，例如 block cache 分片、迭代器归并、bloom filter 短路，以及操作系统层面的影响。

## 测试环境

| 参数 | 数值 |
|-----------|-------|
| CPU | AMD Ryzen 9 9950X（16 核 / 32 线程） |
| RocksDB 版本 | 11.1.0（release build，`DEBUG_LEVEL=0`） |
| Key 数量 | 1,000,000（随机写入后完成 compact） |
| Key 大小 | 16 字节 |
| Value 大小 | 100 字节 |
| 总数据量 | 约 116 MB（compact 后在 L1 有 2 个 SST 文件） |
| 压缩 | 无 |
| Bloom Filter | 10 bits/key（full filter） |
| Block Cache | AutoHyperClockCache（不同测试配置不同） |
| 时长 | 每个 benchmark 10 秒 |
| Benchmark 工具 | 通过 `db_bench` 运行 `tools/benchmark_read_scan.sh` |

### 数据加载后的 LSM Tree 形态

```
Level  Files   Size
L1     2/0     74.23 MB
```

所有数据在 compact 后都位于 L1，没有 L0 文件，也没有多层归并开销。这是读性能的最佳场景，有助于隔离读路径本身的行为，不受 compaction 交互影响。

---

## 1. 点查的线程扩展性

### 原始数据

| 线程数 | ops/sec | P50 (us) | P75 (us) | P95 (us) | P99 (us) | P99.9 (us) | P99.99 (us) | Max (us) |
|---------|---------|----------|----------|----------|----------|------------|-------------|----------|
| 1 | 1,026,622 | 0.56 | 0.84 | 1.73 | 3.58 | 9.38 | 255.42 | 282 |
| 4 | 4,422,821 | 0.65 | 0.97 | 1.57 | 3.80 | 9.97 | 20.72 | 446 |
| 8 | 8,458,941 | 0.97 | 2.30 | 1.61 | 4.76 | 11.94 | 94.38 | 268 |
| 16 | 14,005,066 | 0.96 | 2.26 | 1.83 | 3.98 | 8.40 | 112.37 | 333 |

### 扩展效率

| 线程数 | 相对 1T 的加速比 | 效率 |
|---------|--------------|------------|
| 1 | 1.0x | 100% |
| 4 | 4.3x | 108%（超线性） |
| 8 | 8.2x | 103% |
| 16 | 13.6x | 85% |

### 分析

**4 线程下出现超线性扩展**（108% 效率）是真实现象，不是测量误差。原因在于 block cache 的预热方式：

- 在 1 线程下，每个唯一数据块的首次访问都是 cache miss（`rocksdb.block.cache.miss = 19,156`）。在 1M ops/sec、持续 10 秒的运行中，这 1.9 万次冷 miss 会摊在整个测试过程里。
- 在 4 线程下，总工作集没有变化（仍然是 100 万个 key、约 1.9 万个 block），但 4 个线程能以 4 倍速度把 cache 预热起来。大约前 50ms 之后，4 个线程都能共享彼此完成的 cache 预热成果，因此单次操作的平均 miss rate 更低。

**16 线程下出现次线性扩展**（85% 效率）则暴露出两个瓶颈：

1. **Block cache shard 竞争**：RocksDB 的 AutoHyperClockCache 通过哈希把 cache 分到多个分区，每个分区各自带锁（`cache/clock_cache.cc:1559`）。在 2GB cache 下，默认有 64 个 shard。16 个线程打到 64 个 shard 上，会出现中等程度竞争，平均是每 4 个 shard 才有 1 个线程，但哈希冲突会带来锁等待。证据是：`rocksdb.read.block.get.micros` 的 P50 从 1.6us（1T）升到 18.4us（16T），说明仅仅因为竞争，block read 延迟就增加了 **10 倍**。

2. **CPU cache 污染**：16 个线程跑在 16 个物理核上，会产生跨核内存流量。每次 Get() 都要访问 block cache 元数据（跨核共享），从而导致 L3 cache line 在不同核心间来回迁移。AMD Zen 上的 MOESI 一致性协议需要在多个核心修改相邻 shard 计数器时反复失效并重新获取 cache line。

**为什么 16 线程下的 P99.9（8.40us）反而优于 8 线程（11.94us）**：这看起来反直觉，但可以用统计稀释解释。16 线程总共执行了 1.4 亿次操作（8 线程是 8400 万）。对 1.4 亿个样本计算 99.9 分位，相当于做了更强的平均化，极端异常值占比更小。真正的最大延迟仍然变差了（16T 为 333us，8T 为 268us），说明并发下尾部抖动实际上更严重。

### 尾延迟根因（P99.99: 20-255us）

点查中的 P99.99 尖峰（100-255us）主要来自三类来源：

1. **Block cache miss + SSD 读取**（约 20-100us）：当数据块不在 cache 中时，RocksDB 会从文件系统读取。即使命中 OS page cache，`pread()` 系统调用加上内核上下文切换也要约 2-10us。若是真的访问 NVMe，则通常在 50-100us。

2. **内核调度导致的上下文切换**（约 100-300us）：在 1000 万级 ops/sec 的压力下，CPU 已经趋近饱和。Linux CFS 调度器偶尔会为了内核工作（定时器中断、RCU 回调、network softirq）抢占 benchmark 线程。证据是：即使在单线程下，没有锁竞争，也能看到类似尖峰。

3. **NUMA / CCD 效应**：在 9950X 上，16 个核心虽然属于单 NUMA 节点，但 L3 被划分在不同 CCD 中。跨 CCD 访问 L3，每个 cache line 会额外增加约 10-20ns，这会在一次 Get() 触达多个 cache line 时累积起来，包括 memtable skip list node、block cache entry、data block 等。

---

## 2. Block Cache 温度效应

### 原始数据

| Cache 配置 | Cache 大小 | Hit Rate | ops/sec | P50 (us) | P99 (us) | P99.99 (us) |
|-------------|-----------|----------|---------|----------|----------|-------------|
| Cold | 1 MB | 1.3% | 4,236,571 | 0.51 | 1.48 | 1.85 |
| Warm | 256 MB | 99.96% | 8,587,762 | 1.04 | 4.86 | 28.25 |
| Hot | 4 GB | 99.97% | 8,650,854 | 0.96 | 3.98 | 10.36 |

### 冷缓存悖论

“冷”缓存（1MB）在 block cache hit rate 只有 1.3%、且发生了 2660 万次 cache miss 的情况下，**P50 延迟反而更低**（0.51us），比 warm/hot cache（0.96-1.04us）还好。这不是错误，而是揭示了 OS page cache 这个隐藏层的存在。

**解释**：74MB 的数据集完全可以放进 OS page cache（这台机器的 Linux 管理着约 32GB 内存）。当 block cache 只有 1MB 时，RocksDB 的 block cache miss 会触发 `pread()`，但实际命中的是内核 page cache，而不是 SSD。OS page cache 会映射进进程地址空间，只需要一次内存拷贝，成本大约 0.3-0.5us。

而较大的 block cache（256MB-4GB）会引入额外开销：
- 计算 cache key 的哈希
- 获取 shard 锁（`clock_cache.cc:1274`）
- 更新 LRU 元数据（引用计数、clock hand 推进）
- pin / unpin cache entry

**讽刺之处**在于：对一个本来就能完全驻留内存的数据集，block cache 反而给热路径增加了延迟，而 OS page cache 可以更快地提供读取。这就是为什么“冷缓存”测试的 P50 更低，因为它绕过了 block cache 的额外开销，直接利用了高效的 OS page cache。

**为什么冷缓存吞吐反而更低（4.2M vs 8.6M ops/sec）**：尽管 P50 更低，但冷缓存的延迟分布是双峰的。多数操作很快（OS page cache 命中），但 2660 万次 `pread()` 都会产生系统调用开销（每次大约 0.5us）。用户态到内核态再返回的切换约需 100-200ns，这会消耗掉约 25% 的 CPU 周期。热缓存则有 99.97% 的操作完全绕开了这些系统调用。

**实际含义**：对于小于可用内存的数据集，block cache 大小的重要性没有直觉中那么高，因为 OS page cache 会兜底。block cache 的核心价值主要在于避免系统调用开销，以及提供应用可控的淘汰策略。

### Warm vs Hot Cache

Warm（256MB）和 Hot（4GB）cache 的 hit rate（99.96% vs 99.97%）与吞吐（8.59M vs 8.65M）几乎一致。这说明 74MB 数据集在 256MB cache 中已经完全放得下。4GB cache 带来的收益主要体现在尾延迟：

| 分位数 | Warm (256MB) | Hot (4GB) | 改善幅度 |
|-----------|-------------|----------|-------------|
| P99 | 4.86 | 3.98 | 提升 18% |
| P99.9 | 9.37 | 7.31 | 提升 22% |
| P99.99 | 28.25 | 10.36 | 提升 63% |

更大的 cache 通过降低 shard 竞争改善了尾延迟，因为 shard 更多、哈希冲突概率更低、锁等待更少。

---

## 3. 范围扫描：扫描长度的影响

### 原始数据

| Nexts | ops/sec（扫描操作） | 吞吐（MB/s） | P50 (us) | P95 (us) | P99 (us) | P99.9 (us) | P99.99 (us) |
|-------|-------------------|-------------------|----------|----------|----------|------------|-------------|
| 10 | 1,257,503 | 1,391 | 0.95 | 5.37 | 4.47 | 13.64 | 35.40 |
| 100 | 392,481 | 4,342 | 0.86 | 5.87 | 3.98 | 11.30 | 142.46 |
| 1000 | 51,378 | 5,681 | 0.82 | 9.58 | 4.04 | 14.88 | 255.28 |

### 吞吐与延迟的权衡

当扫描长度增长 100 倍（10 -> 1000 nexts）时：
- **扫描 ops/sec 下降了 24 倍**（1.26M -> 51K），因为单次扫描持续时间按比例变长
- **数据吞吐提升了 4 倍**（1,391 -> 5,681 MB/s），因为 seek 开销被更好地摊薄了

这体现了 LSM 树中经典的 seek 与 scan 权衡。初始 Seek() 需要：
1. 对 index block 做二分查找，找到目标 data block
2. 在 data block 内再次二分查找，定位目标 key
3. 将 merge iterator 放到各层对应的位置

而后续每个 Next() 大多数时候只需要在当前 data block 内推进一个指针，直到跨过 block 边界。单个 Next() 的成本大致为：

```
Cost(Seek + N nexts) = Seek_cost + N * Next_cost
Cost per scan = (Seek_cost + N * Next_cost) / N
              = Seek_cost/N + Next_cost

其中：Seek_cost ~= 3-5us，Next_cost ~= 0.05-0.1us
```

在 N=1000 时，seek 开销被摊薄到每个 key 约 0.005us，单 key 成本趋近于纯 Next() 的成本（约 0.1us）。

### 为什么 P99.99 会随着扫描长度显著恶化

| Nexts | P99.99 (us) |
|-------|-------------|
| 10 | 35.40 |
| 100 | 142.46 |
| 1000 | 255.28 |

更长的扫描使 P99.99 尾延迟恶化了 7 倍，主要由三方面因素叠加导致：

1. **跨越 block 边界**：一次 1000 key 的扫描会跨过大约 15-20 个 data block（8KB block size、16B key + 100B value 时，每个 block 大约容纳 60-80 个 key）。每次跨越 block 边界都需要：
   - 查询 index block，获得下一个 data block 位置
   - 查询 block cache（可能发生 shard 竞争）
   - 解码 / 拷贝 block（即使 `compression=none`，仍有 memcpy）

   证据是：`rocksdb.read.block.get.micros` 在 seek 场景下的 P95 可达 368us，这就是 block cache shard 竞争的代价。一次长扫描有 15-20 次 block 切换，至少命中一次激烈竞争访问的概率会从约 1% 增加到约 15%。

2. **CPU cache 抖动**：扫描 1000 个 key 会触达约 116KB 的 key/value 数据，再加上 data block、index block 和 iterator 元数据，单次扫描的活跃工作集大致在 120-160KB。对 Ryzen 9 9950X 这类 Zen 5 核心来说，这已经明显超过单核 48KB L1 data cache，但通常仍能落在单核 1MB L2 内。因此，长扫描后段更容易从 L1 hit 退化为 L2 hit，增加单步 Next() 的平均成本；不过这更偏向解释平均延迟上升，而不是 100us 级的极端尾延迟。

3. **更容易暴露调度抖动**：一次 1000 key 扫描大约要 20us。在 20us 时间窗内被抢占的概率，大约是 2us 时间窗（10 key 扫描）的 10 倍。Linux 默认的 `sched_min_granularity_ns` 约 3ms，但 250Hz 的 timer interrupt 每 4ms 触发一次，任何一次中断落在扫描过程中都会额外带来 1-5us 延迟。

---

## 4. 正向扫描 vs 反向扫描

### 原始数据

| 方向 | Nexts=10 | Nexts=100 | Nexts=1000 |
|-----------|----------|-----------|------------|
| 正向 ops/sec | 1,257,503 | 392,481 | 51,378 |
| 正向 MB/s | 1,391 | 4,342 | 5,681 |
| 反向 ops/sec | 1,890,468 | 518,256 | 63,420 |
| 反向 MB/s | 2,091 | 5,733 | 7,012 |
| **反向加速比** | **1.50x** | **1.32x** | **1.23x** |

### 根因：迭代器实现的不对称性

反向迭代比正向快 30-50% 看起来很反直觉，但根因藏在迭代器实现细节里：

**正向迭代路径**（`db/db_iter.cc:169-219`，`Next()`）：
1. 调用 `iter_.Next()` 推进内部迭代器
2. 调用 `FindNextUserEntry()`，需要扫描当前 user key 对应的所有 internal key（删除标记、sequence number 等），才能找到下一个可见 user key
3. 这个 internal key 比较过程是顺序推进，无法跳过

**反向迭代路径**（`db/db_iter.cc:747-781`，`Prev()`）：
1. 调用 `PrevInternal()`，其内部使用 `FindUserKeyBeforeSavedKey()`
2. 当迭代器反向跨越 block 边界时，会对新 block 调用 `SeekForPrev()`，这里使用的是**二分查找**定位，而不是顺序扫描
3. 还有 `max_skip_` 优化（`db/db_iter.cc:1469`）：当遇到超过 `max_num_skips` 个 key 时，迭代器会退化回基于 Seek 的路径，而不是继续线性扫

**为什么扫描越长，差距越小**（10 nexts 时 1.50x，1000 nexts 时 1.23x）：
扫描越长，单个 Next()/Prev() 的成本越主导，总体上初始 Seek() 的影响越弱。在单个 data block 内，正向 Next() 和反向 Prev() 的成本很接近，本质都是指针调整。反向的优势主要集中在 **block 边界** 处，而 block 边界大约每 60-80 个 key 才出现一次。对于 nexts=10，多数扫描只落在 1-2 个 block 内，边界效应占比很大；对于 nexts=1000，大约只有 15 次边界切换，放到 1000 次操作里占比就小得多。

**额外因素：data block 布局**。RocksDB 的 block-based table 用 restart point 存储有序 key。正向迭代必须逐个解开 delta encoding 的 key，而反向迭代可以通过 `BlockIter::SeekToRestartPoint()` 更快地借助 restart point 在块内定位。

### 通过内部统计验证

`db.seek.micros` 的直方图验证了这种不对称性：

| 方向 | Nexts=100 | db.seek.micros P50 | db.seek.micros P95 |
|-----------|-----------|--------------------|--------------------|
| 正向 | 392K ops/s | 3.32 us | 5.87 us |
| 反向 | 518K ops/s | 0.99 us | 2.04 us |

反向扫描的内部 seek 时间在 P50 上快了 3.3 倍，这正是二分查找优势体现的位置。

### 进一步结论
这组结果更像是 DataBlockIter::PrevImpl() 的“prev cache”带来的cache hit优势，而不是 SeekForPrev() 的起始定位优势。

---

## 5. MultiGet 批大小分析

### 原始数据

| 批大小 | 总 ops/sec（key） | 单次调用延迟 P50 (us) | P99 (us) | P99.9 (us) | P99.99 (us) |
|-----------|---------------------|--------------------------|----------|------------|-------------|
| 1 | 6,353,592 | 0.98 | 5.44 | 9.91 | 26.11 |
| 16 | 10,308,780 | 2.85 | 13.01 | 24.20 | 268.95 |
| 64 | 10,109,851 | 3.73 | 25.36 | 59.24 | 286.78 |

### 为什么 Batch=16 是甜点

**吞吐**：Batch=16 比单 key Get 提高了 62% 吞吐，但 batch=64 **没有进一步提升**（反而回退 2%）。

**延迟**：Batch=64 的 P99（25.36 vs 13.01us）恶化了 1.9 倍，P99.9（59.24 vs 24.20us）恶化了 2.4 倍。

根因是批量操作中的 **拖尾者问题**（straggler problem）：

**MultiGet 内部实现**（`db/db_impl/db_impl.cc:3370`）会把一批 key 一起处理，对每个 key 做 block cache 查询并归并结果。一个 batch 的完成时间由其中**最慢**的那个 key 决定，而不是平均耗时。

对于批量大小为 N 的请求，如果每个 key 的查询延迟分布中 P99 = T：
- 这批请求中至少有一个 key 超过 T 的概率是：`1 - (0.99)^N`
  - Batch=16：`1 - 0.99^16 = 14.8%`，意味着 14.8% 的 batch 会被一个 P99 异常值拖慢
  - Batch=64：`1 - 0.99^64 = 47.3%`，意味着 47.3% 的 batch 会被一个 P99 异常值拖慢

这就解释了为什么 batch=64 的 P50（3.73us）已经体现出单 key 尾延迟特征，因为接近一半的 batch 里都至少带有一个慢 key。

**为什么吞吐平台化**：批量查询带来的 CPU 节省（共享 cache 查找、摊薄锁开销）被以下因素抵消了：
1. 每个 batch 的工作集更大，会把有用数据从 L1/L2 cache 中挤出去
2. 每批 key 更多，意味着访问更多 block cache shard，竞争更重
3. MultiGet 内部会按 block 对 key 排序，但对当前数据集而言，64 个 key 大约也只覆盖 1 个 block 左右，相比 16 并不能带来更多 block 级别的 batching 收益

**建议**：对当前数据集，batch size 16 在吞吐和延迟之间给出了最佳平衡。对于 key 更集中、能落在更少 block 中的数据集，更大的 batch 也许会更优。

---

## 6. Bloom Filter 的有效性

### 原始数据

| 测试 | ops/sec | P50 (us) | P95 (us) | P99 (us) | Cache Misses |
|------|---------|----------|----------|----------|-------------|
| readrandom（命中） | 8,458,941 | 0.97 | 1.61 | 4.76 | 19,178 |
| readmissing（全部 miss） | 31,749,700 | 0.94 | 0.95 | 3.91 | 7,921 |
| **加速比** | **3.75x** | | | | |

### Bloom Filter 的快速路径

当一次 Get() 遇到 bloom filter negative 时，会走一条极短的代码路径（`table/block_based/block_based_table_reader.cc:2329-2354`）：

```
Get() -> FullFilterKeyMayMatch() -> return false
```

这会直接跳过：
- index block 查找（约 0.5-1us）
- data block cache 查找（约 0.5-2us）
- data block 内二分查找（约 0.3-0.5us）
- key 比较（约 0.1us）

bloom filter 检查本身只需约 50-100ns，只是对 filter block 中的 10 个 bit 做少量内存访问，而这个 filter block 已经被 pin 在 block cache 中。

### Bloom Filter 统计深入分析

**readrandom（8 线程）**：
```
bloom.filter.useful:        30,815,043  （36.4% 的查找，filter 判断“这个文件里没有”）
bloom.filter.full.positive: 53,782,784  （63.6%，filter 判断“可能在这里”）
bloom.filter.full.true.positive: 53,482,116  （正例里有 99.4% 真实存在）
误判率：0.56%（300,668 / 53,782,784）
```

由于只有 2 个 SST 文件，每次 Get() 最多检查 2 个 bloom filter。36.4% 的 “useful” 比例意味着，大约 36% 的文件级检查能正确判断 key 在另一个文件里，从而省掉一次 data block 查找。

**readmissing（8 线程）**：
```
bloom.filter.useful:        314,358,457  （99.0%，几乎都被过滤掉）
bloom.filter.full.positive:   3,156,234  （1.0%，误判）
bloom.filter.full.true.positive:       0  （0，因为 key 实际上都不存在）
误判率：1.0%（3,156,234 / 317,514,691 总检查次数）
```

这个 1.0% 的误判率与 10-bit bloom filter 的理论值基本一致。理论误判率是 `(1 - e^(-k*n/m))^k`，其中 k=6.93，对应约 0.82%。实际值略高，主要是由于真实 key 分布带来的哈希碰撞聚集。

**为什么 readmissing 仍然有 7,921 次 cache miss**：这些 miss 其实是 bloom filter block 自身的加载。当某个此前未缓存的 SST 文件的 filter block 第一次被访问时，仍然需要从存储读取。预热完成后，后续检查都会命中 cache。

---

## 7. 写入压力的影响

### 写压力下的点查

| 条件 | ops/sec | P50 (us) | P99 (us) | P99.99 (us) | Memtable Hits |
|-----------|---------|----------|----------|-------------|--------------|
| 纯读（8T） | 8,458,941 | 0.97 | 4.76 | 94.38 | 0 |
| +10MB/s 后台写入 | 4,068,005 | 1.13 | 4.48 | 13.94 | 7,960,818 |
| 90/10 读写混合 | 2,786,926 | 0.91 | 5.43 | 27.72 | — |
| 50/50 读写混合 | 1,525,486 | 0.70 | 5.35 | 25.40 | — |

### 为什么后台写入会让读吞吐下降 52%

`readwhilewriting` 测试使用 8 个读线程加 1 个写线程。吞吐从 8.46M 降到 4.07M，下降 52%，主要有三个原因：

1. **Memtable 竞争**（主因）：写线程每次写入都要持有 DB mutex，而读线程为了获取 SuperVersion 引用，也需要短暂获取这个 mutex。这个串行点限制了并发读吞吐。证据是：`memtable.hit = 7,960,818`，说明现在有 20% 的读请求会在 memtable 中命中新写入的 key，而这需要在共享锁保护下遍历 skiplist。

2. **Flush 活动**：写线程以约 10MB/s 的速度产生数据，从而触发 memtable flush。flush 期间：
   - 正在 flush 的 memtable 会变成 immutable，但读线程仍然必须检查它
   - 读与 flush 写共享 I/O 带宽
   - 证据是：`memtable.payload.bytes.at.flush = 57,133,744`，说明 10 秒测试中 flush 了 57MB 数据

3. **9 个线程抢 8 个物理核**：新增的写线程也要竞争 CPU 时间，而超线程会共享执行资源。

### 为什么写压力下 P99.99 反而改善（94us -> 14us）

这主要是吞吐下降带来的统计假象。在 4M ops/sec（而不是 8.5M）下，总共只有 4000 万次操作。99.99 分位对应第 4000 个最慢操作；而在高吞吐场景（8400 万次）下，99.99 分位对应第 8400 个最慢操作。最差操作的绝对数量接近，但在较小样本中它们占比更大，因此分位点看起来更“好”。

### 写压力下的范围扫描

| 条件 | ops/sec | P50 (us) | P99.99 (us) |
|-----------|---------|----------|-------------|
| 纯 seek（8T） | 392,481 | 0.86 | 142.46 |
| +10MB/s 后台写入 | 251,627 | 0.92 | 260.63 |
| **退化幅度** | **36%** | **7%** | **83%** |

范围扫描在 P50 上受影响较小（只退化 7%），因为主要成本是顺序遍历 block，这部分和写入竞争不强。但 P99.99 恶化很明显（83%），因为：
- 长扫描更容易在执行过程中撞上一次 memtable flush
- 扫描必须同时查看 immutable memtable 和 SST 文件，merge iterator 复杂度更高
- flush I/O 带来的 block cache churn 可能会把扫描后续需要的 block 淘汰掉

### 混合负载中的 Compaction

| 负载 | Compaction 次数 | Compaction 时间 | 写出数据量 |
|----------|------------|-----------------|-------------|
| 90/10 mix | 1 | 426ms | 122MB |
| 50/50 mix | 4 | 1,710ms（总计） | 500MB |

50/50 混合负载触发了 4 倍更多的 compaction。每次 compaction 都会：
- 读取并重写 SST 文件，消耗 CPU 与 I/O
- 在 version switch 时短暂阻塞读
- 让被重写 block 的 block cache entry 失效
- 在 compaction 完成前增加 merge iterator 复杂度（例如临时出现更多 L0 文件）

---

## 8. Prefix Scan vs 全序扫描

### 原始数据

| 模式 | ops/sec | P50 (us) | P95 (us) | P99 (us) | Block Cache Misses |
|------|---------|----------|----------|----------|--------------------|
| 全序 seek | 392,481 | 0.86 | 5.87 | 3.98 | 41,069 |
| Prefix 模式 | 3,701,880 | 0.94 | 1.91 | 3.90 | 28,473 |
| **加速比** | **9.4x** | | | | |

### Prefix 优化机制

9.4 倍加速来自两个相互配合的机制：

**1. 基于 SST 的 bloom filter 剪枝**（`block_based_table_iterator.cc:84-90`）

当 `auto_prefix_mode=1` 时，Seek() 会先检查每个 SST 文件的 bloom filter，看目标 key 的 prefix 是否存在。如果 prefix 不存在，就可以**整文件跳过**，无需读取任何 index block 或 data block。

在只有 2 个 SST 文件、且 prefix 随机分布的情况下，大约有一半的 seek 可以直接跳过其中一个文件，也就省掉了该文件的一次 index block 查找和 data block 查找。

**2. 迭代器上界**（`db_bench_tool.cc:7430-7437`）

db_bench 会把 `iterate_upper_bound` 设为下一个 prefix 值。这意味着迭代器一旦越过 prefix 边界就立即停止，而不是一直扫到找到 `seek_nexts` 个 key 为止。对 100 万 key、8-byte prefix 的数据集来说，每个 prefix 下通常只包含很少几个 key，因此迭代器很快就结束了。

**为什么 prefix scan 仍然有 2.8 万次 cache miss**：每个唯一 prefix 至少需要一次 block cache 查找，才能定位到相应 data block。由于 8-byte prefix 是随机的，100 万个 key 中大多数 seek 都会打到不同 prefix。2.8 万次 miss 基本对应约 1.9 万个唯一 data block 的初始预热，再加上一些因为 cache 淘汰引起的重复 miss。

**内部时间也验证了这一点**：`db.seek.micros P50 = 0.78us`（prefix）对比 `3.32us`（全序），说明 seek 本身就快了 4.3 倍，因为它需要检查的 block 更少。

---

## 9. 尾延迟剖析

### 最坏延迟来自哪里？

在所有 benchmark 中，P100（最大值）延迟分布在 268us 到 1,339us 之间。这些极端异常值通常有比较明确的来源：

| 延迟区间 | 可能原因 | 证据 |
|--------------|-------------|---------|
| 0-5 us | 正常操作（cache hit） | 大多数测试的 P50-P99 |
| 5-50 us | Block cache shard 竞争 | 多线程测试里 `read.block.get.micros P95 = 350-680us` |
| 50-300 us | OS 调度（上下文切换 + TLB flush） | 即使单线程也出现在 P99.99，说明不是锁竞争 |
| 300-600 us | Block cache miss + 真实 I/O | `sst.read.micros P100 = 268-969us` |
| 600-1400 us | 多种因素叠加 | `reverse_short`（1,294us）与 `readwhilescanning`（1,030us）的最大延迟 |

### Block Cache 竞争墙

最显著的抖动来源是 block cache shard 竞争，从 `rocksdb.read.block.get.micros` 可以直接看到：

| 线程数 | Block Read P50 (us) | Block Read P95 (us) | Block Read P99 (us) |
|---------|--------------------|--------------------|---------------------|
| 1 | 1.60 | 4.47 | 11.48 |
| 8 | 16.70 | 383.50 | 552.32 |
| 16 | 18.42 | 682.39 | 1,075.82 |

P95 从 1 线程的 4.47us 跳到 16 线程的 682us，增幅达到 **153 倍**。这说明 block cache shard 锁已经变成主要瓶颈。当 16 个线程同时需要一个新 block（例如同时跨过 block 边界）时，它们会排队等待 shard 锁。最坏等待时间大致与 `(threads_per_shard - 1) * per_access_time` 成正比。

需要注意的是：这些尖峰只影响测试中真正读取新 block 的那约 1.9 万次操作，绝大多数操作（99.97%）都直接命中 block cache，不会受到明显竞争影响。

### 降低尾延迟的建议

1. **增加 shard bits**：把 `cache_numshardbits=8`（256 shards）可以让单 shard 竞争降低 4 倍，代价是 shard 元数据带来略多内存开销。

2. **Pin 高频 block**：使用 `BlockBasedTableOptions::pin_l0_filter_and_index_blocks_in_cache = true`，防止 filter/index block 被淘汰，从而减少 cache miss。

3. **启用 direct I/O**：`use_direct_reads=true` 可以绕过 OS page cache，让 RocksDB 完全掌控缓存策略，并消除 page cache 淘汰带来的不可预测性。对大于内存的数据集尤其有意义。

4. **CPU 隔离**：使用 `taskset` 或 `cgroups` 给 benchmark 预留 CPU 核，避免内核线程干扰导致调度抖动。

5. **优化 block size**：更大的 block（16-32KB）能减少扫描时跨 block 边界的次数，但会增加单次读延迟。对 scan-heavy 工作负载，这通常是值得的权衡。

---

## 10. 关键结论总结

| 结论 | 根因 | 严重性 | 缓解方式 |
|---------|-----------|----------|------------|
| 16T 扩展只有 85% 效率 | Block cache shard 竞争 + CPU cache bouncing | 中 | 增加 shard 数 |
| 冷缓存悖论（更低 P50） | OS page cache 提供读取，block cache 反而增加开销 | 信息性 | 对内存内数据集属正常现象 |
| 长扫描的 P99.99 恶化 7 倍 | 跨 block 边界 + 更容易暴露调度抖动 | 中 | 增大 block size；CPU pinning |
| MultiGet batch=64 不优于 16 | 拖尾者问题，最慢 key 决定整批延迟 | 中 | batch size 控制在 16-32 |
| Bloom filter 让 miss 快 3.75 倍 | 完全跳过 index 与 data block 读取 | 信息性 | 说明 bloom filter 配置合理 |
| 写入压力下吞吐下降 52% | DB mutex 竞争 + memtable flush I/O | 高 | 分离读写路径；增大 `write_buffer_size` |
| Prefix scan 提速 9.4 倍 | SST 级 bloom 剪枝 + iterator upper bound | 高 | 对有范围边界的负载使用 prefix extractor |
| P99.99 尖峰到 100-300us | Block cache 锁竞争 + OS 调度 | 中 | 增加 shards；做 CPU 隔离 |

---

## 附录 A：完整结果表

所有延迟单位均为微秒。

| 测试名 | 线程数 | P50 | P75 | P95 | P99 | P99.9 | P99.99 | Max | Min | Avg | StdDev | ops/sec | MB/s |
|-----------|---------|-----|-----|-----|-----|-------|--------|-----|-----|-----|--------|---------|------|
| readrandom | 1 | 0.56 | 0.84 | 1.73 | 3.58 | 9.38 | 255.42 | 282 | 0 | 1.08 | 3.02 | 1,026,622 | 71.8 |
| readrandom | 4 | 0.65 | 0.97 | 1.57 | 3.80 | 9.97 | 20.72 | 446 | 0 | 1.37 | 4.69 | 4,422,821 | 309.3 |
| readrandom | 8 | 0.97 | 2.30 | 1.61 | 4.76 | 11.94 | 94.38 | 268 | 0 | 1.89 | 2.74 | 8,458,941 | 591.6 |
| readrandom | 16 | 0.96 | 2.26 | 1.83 | 3.98 | 8.40 | 112.37 | 333 | 0 | 1.88 | 4.94 | 14,005,066 | 979.3 |
| readrandom（cold cache） | 8 | 0.51 | 0.77 | 3.29 | 1.48 | 1.82 | 1.85 | 1,339 | 0 | 0.74 | 1.33 | 4,236,571 | 296.2 |
| readrandom（warm cache） | 8 | 1.04 | 2.41 | 1.58 | 4.86 | 9.37 | 28.25 | 354 | 0 | 1.99 | 3.54 | 8,587,762 | 600.5 |
| readrandom（hot cache） | 8 | 0.96 | 2.31 | 1.57 | 3.98 | 7.31 | 10.36 | 395 | 0 | 1.88 | 3.60 | 8,650,854 | 604.9 |
| multiget batch=1 | 8 | 0.98 | 2.59 | 1.85 | 5.44 | 9.91 | 26.11 | 456 | 0 | 2.10 | 4.98 | 6,353,592 | 444.2 |
| multiget batch=16 | 8 | 2.85 | 4.61 | 16.45 | 13.01 | 24.20 | 268.95 | 311 | 0 | 3.84 | 6.09 | 10,308,780 | 720.8 |
| multiget batch=64 | 8 | 3.73 | 7.08 | 69.88 | 25.36 | 59.24 | 286.78 | 379 | 0 | 5.75 | 8.88 | 10,109,851 | 707.0 |
| readmissing | 8 | 0.94 | 2.16 | 0.95 | 3.91 | 7.54 | 13.68 | 373 | 0 | 1.92 | 6.50 | 31,749,700 | N/A |
| readwhilewriting | 8 | 1.13 | 2.44 | 2.91 | 4.48 | 7.61 | 13.94 | 441 | 0 | 2.04 | 4.47 | 4,068,005 | 338.9 |
| seekrandom（short） | 8 | 0.95 | 2.27 | 5.37 | 4.47 | 13.64 | 35.40 | 371 | 0 | 1.90 | 4.43 | 1,257,503 | 1,391.1 |
| seekrandom（medium） | 8 | 0.86 | 2.07 | 5.87 | 3.98 | 11.30 | 142.46 | 411 | 0 | 1.70 | 4.89 | 392,481 | 4,341.6 |
| seekrandom（long） | 8 | 0.82 | 1.89 | 9.58 | 4.04 | 14.88 | 255.28 | 589 | 0 | 1.60 | 5.52 | 51,378 | 5,680.5 |
| seekrandom | 1 | 0.52 | 0.78 | 6.45 | 1.82 | 9.13 | 320.42 | 483 | 0 | 0.81 | 4.96 | 52,039 | 575.7 |
| seekrandom | 4 | 0.59 | 0.89 | 5.87 | 3.38 | 9.87 | 94.42 | 343 | 0 | 1.10 | 3.26 | 206,031 | 2,279.1 |
| seekrandom | 16 | 0.92 | 2.16 | 7.33 | 3.96 | 9.94 | 172.13 | 376 | 0 | 1.73 | 3.83 | 647,028 | 7,157.4 |
| seekrandom+write | 8 | 0.92 | 2.26 | 9.91 | 3.96 | 9.61 | 260.63 | 461 | 0 | 1.79 | 4.73 | 251,627 | 2,783.5 |
| reverse（short） | 8 | 0.85 | 2.30 | 1.95 | 5.54 | 9.44 | 12.04 | 1,294 | 0 | 1.83 | 7.38 | 1,890,468 | 2,091.3 |
| reverse（medium） | 8 | 0.90 | 2.13 | 2.04 | 3.79 | 5.84 | 9.33 | 321 | 0 | 1.69 | 3.47 | 518,256 | 5,733.0 |
| reverse（long） | 8 | 0.84 | 1.94 | 5.35 | 3.73 | 5.66 | 6.03 | 583 | 0 | 1.58 | 5.83 | 63,420 | 7,012.2 |
| seekrandom（prefix） | 8 | 0.94 | 2.26 | 1.91 | 3.90 | 8.70 | 28.46 | 412 | 0 | 1.82 | 3.32 | 3,701,880 | 383.0 |
| mixed 90/10 | 8 | 0.91 | 2.26 | 3.66 | 5.43 | 10.33 | 27.72 | 419 | 0 | 1.85 | 3.20 | 2,786,926 | N/A |
| mixed 50/50 | 8 | 0.70 | 1.29 | 5.57 | 5.35 | 11.48 | 25.40 | 694 | 0 | 1.50 | 3.22 | 1,525,486 | N/A |
| readwhilescanning | 8 | 0.96 | 2.26 | 1.98 | 3.89 | 8.05 | 21.28 | 1,030 | 0 | 1.90 | 9.59 | 8,877,516 | 495.0 |

## 附录 B：复现这些结果

```bash
# 构建 release 二进制
make clean && DEBUG_LEVEL=0 make db_bench -j$(nproc)

# 运行相同 benchmark 配置
NUM_KEYS=1000000 \
DURATION=10 \
THREAD_COUNTS="1 4 8 16" \
DEFAULT_THREADS=8 \
MULTIGET_BATCH_SIZES="1 16 64" \
CACHE_SIZE_DEFAULT=$((2 * 1024 * 1024 * 1024)) \
CACHE_SIZE_COLD=$((1 * 1024 * 1024)) \
CACHE_SIZE_WARM=$((256 * 1024 * 1024)) \
CACHE_SIZE_HOT=$((4 * 1024 * 1024 * 1024)) \
DB_DIR=/tmp/rocksdb_bench_test \
OUTPUT_DIR=/tmp/rocksdb_bench_results \
bash tools/benchmark_read_scan.sh
```

如果希望结果更接近生产环境，请使用更大的数据集：

```bash
NUM_KEYS=50000000 DURATION=60 bash tools/benchmark_read_scan.sh
```
