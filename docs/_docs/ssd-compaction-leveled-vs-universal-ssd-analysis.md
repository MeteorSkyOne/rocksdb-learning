---
docid: ssd-compaction-leveled-vs-universal
title: SSD 场景下 Leveled 与 Universal Compaction 分析
layout: docs
permalink: /docs/ssd-compaction-leveled-vs-universal.html
---

# SSD 场景下 Leveled 与 Universal Compaction 分析

本文分析了 2026 年 4 月 6 日在真实 SSD 环境上完成的一组 RocksDB compaction benchmark。对比对象是 `kCompactionStyleLevel` 和 `kCompactionStyleUniversal`。在很多用户语境里，后者通常就是“tiered compaction”最接近的 RocksDB 对应实现。

本文不只汇报吞吐和延迟数字，还会解释这些结果为什么会出现，以及它们在 SSD 部署里分别意味着什么样的取舍。

## 分析范围

本文覆盖的是已经实际跑完的 benchmark 切片：

- Profile: `kv128`
- Bundle: `ssd_bundle`
- Styles: `level`, `universal`
- Workloads: `readrandom`, `overwrite`, `readwhilewriting`
- Repeats: `1`

原始结果文件位于：

- `/home/meteorsky/ssd-compaction-results/real-slice-20260406-1/results/summary.csv`
- `/home/meteorsky/ssd-compaction-results/real-slice-20260406-1/results/interval.csv`
- `/home/meteorsky/ssd-compaction-results/real-slice-20260406-1/results/levelstats.csv`

## 测试环境

| 参数 | 值 |
| --- | --- |
| 宿主文件系统 | `/dev/sdd` 上的 `ext4` |
| DB 路径 | `/home/meteorsky/ssd-compaction-db` |
| 构建方式 | release 风格 `db_bench` |
| 数据集 | `200,000,000` keys |
| Key / Value 大小 | `20B / 128B` |
| live user data | 约 `27.6 GiB` |
| Compression | `none` |
| Block size | `4 KiB` |
| Bloom filter | `10` bits/key |
| Block cache | `0` |
| 读路径 | `use_direct_reads=1` |
| Flush / compaction direct I/O | `use_direct_io_for_flush_and_compaction=0` |
| Write buffers | `256 MiB * 4` |
| Background jobs | `16` |
| Subcompactions | `4` |

这里有两个细节对结果解释非常关键：

1. `cache_size=0` 加上 `use_direct_reads=1`，使 benchmark 更接近于测 SSD 和 LSM 本身，而不是主要在测 block cache。
2. `use_direct_io_for_flush_and_compaction` 被刻意保持为 `0`。因为在当前环境里，一旦启用它，在 `200M` key 的 base build 阶段就复现过 checksum corruption，所以这次稳定可跑的配置是“direct read 开启，compaction direct I/O 关闭”。

## 被测配置

本次共享的 SSD 优化 bundle 为：

- `target_file_size_base=256 MiB`
- `max_bytes_for_level_base=2 GiB`
- `level_compaction_dynamic_level_bytes=1`
- `level0_file_num_compaction_trigger=8`
- `max_compaction_bytes=4 GiB`

其中 universal 额外带了：

- `universal_size_ratio=10`
- `universal_min_merge_width=4`
- `universal_max_merge_width=8`
- `universal_max_read_amp=8`
- `universal_max_size_amplification_percent=50`
- `universal_incremental=1`
- `universal_allow_trivial_move=1`
- `universal_reduce_file_locking=1`

这些参数不是装饰项，而是和结果直接相关的行为控制项：

- `compaction_style` 和 `compaction_options_universal` 定义在 `include/rocksdb/advanced_options.h`
- universal compaction 里 `size_ratio`、`max_size_amplification_percent`、`max_read_amp`、`allow_trivial_move`、`incremental`、`reduce_file_locking` 的语义定义在 `include/rocksdb/universal_compaction.h`
- universal picker 在 `db/compaction/compaction_picker_universal.cc` 中包含了显式降低 write-stop 压力的逻辑
- leveled picker 在 `db/compaction/compaction_picker_level.cc` 中则围绕层级容量和 overlap 展开选取

## 执行摘要

对于这一组 SSD benchmark 切片，`universal` 在三个已完成 workload 上都优于 `level`：

- `readrandom`: 吞吐略高，tail latency 略低
- `overwrite`: 吞吐略高，tail latency 更低，compaction 成本显著更低，但最终空间放大更高
- `readwhilewriting`: 吞吐略高，tail latency 更低，compaction 成本更低，而且最终空间放大也更低

这里最重要的观察点不是 `2%` 到 `3%` 的吞吐差距，而是 `universal` 显著降低了后台 compaction 工作量：

- `overwrite`: `compaction_write_gb` 从 `449.28` GiB 降到 `287.71` GiB，`compaction_seconds` 从 `1324.7` 降到 `480.7`
- `readwhilewriting`: `compaction_write_gb` 从 `154.21` GiB 降到 `119.78` GiB，`compaction_seconds` 从 `526.5` 降到 `207.1`

这才是这次 SSD workload 中 `universal` 看起来更优的主因：它节省下来的 rewrite 工作量，足以覆盖“sorted run 更多”带来的复杂度成本。

## Workload 开始前的 LSM 形态

在初始加载和 compaction 完成后，LSM 形态如下：

| Style | 总文件数 | 总大小 | 形态 |
| --- | ---: | ---: | --- |
| level | 124 | 29,784 MB | `L0: 4`, `L4: 6`, `L5: 9`, `L6: 105` |
| universal | 197 | 29,782 MB | `L4: 33`, `L5: 63`, `L6: 101` |

这已经把核心 trade-off 暴露出来了。

Leveled compaction 更激进地把数据压到底层。Universal 则保留了更多上层 sorted run。这意味着：

- leveled 一开始就拥有更简单的底层读路径
- universal 一开始就有更多 file/run metadata，也可能有更高的 read fanout
- universal 同时也减少了把字节不断往最底层重写的压力

后面大部分现象，基本都可以从这个初始结构差异推导出来。

## 只读 workload：`readrandom`

### 结果

| 指标 | level | universal | 差异 |
| --- | ---: | ---: | ---: |
| ops/sec | 125,257 | 128,827 | `+2.85%` |
| avg us | 255.378 | 248.306 | `-2.77%` |
| P50 us | 233.43 | 231.78 | `-0.71%` |
| P95 us | 424.56 | 373.53 | `-12.02%` |
| P99 us | 564.90 | 533.37 | `-5.58%` |
| P99.9 us | 839.22 | 787.93 | `-6.11%` |
| P99.99 us | 1587.04 | 1297.09 | `-18.27%` |
| read_amp_proxy | 1.0477 | 0.9968 | `-4.86%` |
| 最终 DB 大小 | 29.10 GiB | 29.10 GiB | 基本相同 |

### 为什么 universal 仍然赢了

直觉上，leveled 应该有更干净的读路径。它的 base LSM 更偏向底层，文件总数也更少，上层 sorted run 也更少。计数器表明，这个直觉只对了一半。

`readrandom` 期间，last-level read share 为：

- level: `80.5%` 的读字节来自最后一层
- universal: `68.4%`

`readrandom` 期间，non-last-level read share 为：

- level: `19.5%`
- universal: `31.6%`

也就是说，universal 确实更多地访问了非底层数据。但它仍然拿到了更低的 `read_amp_proxy` 和更好的 tail latency。结合计数器，最合理的解释是：

1. 一部分 key 在 universal 的较新 sorted run 中就命中了，不必一路走到底层
2. 这类额外 run check 的成本没有大到主导总时延，因为这个 benchmark 是 hit-heavy 的，而且启用了 bloom filter
3. 在 SSD 场景下，少读一些最深层的数据，收益大于多查几层上层 run 的代价

这里是根据 counters 做出的推断，不是直接来自内部 trace。但关键结论是：universal 理论上的主要缺点，也就是更高的 read fanout，在这次 workload 里被控制在了一个不至于翻盘的范围内，因此更早命中的收益保住了。

### 这个测试暴露出的 trade-off

只读 workload 的结果对 universal 有利，但不能把它误读成 universal 永远是更好的读策略。

这次 workload 具有几个特征：

- 只有 point lookup，没有 scan
- 更偏 hit-heavy，而不是 miss-heavy
- 跑在相对紧凑的 `kv128` profile 上
- 数据库处于预先准备好的 base DB 状态

这些条件都会弱化“sorted run 增多”的坏处。如果换成 miss-heavy workload、更大的 value、更大的 profile 或更深的 fanout，优势可能会回到 leveled 这一侧。

## 重写压力 workload：`overwrite`

### 结果

| 指标 | level | universal | 差异 |
| --- | ---: | ---: | ---: |
| ops/sec | 716,115 | 732,819 | `+2.33%` |
| P50 us | 14.39 | 14.26 | `-0.93%` |
| P95 us | 43.52 | 41.99 | `-3.53%` |
| P99 us | 127.04 | 109.69 | `-13.65%` |
| P99.9 us | 742.21 | 720.15 | `-2.97%` |
| P99.99 us | 1079.69 | 977.69 | `-9.45%` |
| compaction read GB | 442.98 | 277.01 | `-37.47%` |
| compaction write GB | 449.28 | 287.71 | `-35.96%` |
| compaction seconds | 1324.7 | 480.7 | `-63.71%` |
| total_lsm_wa | 7.295 | 4.565 | `-37.42%` |
| 最终 DB 大小 | 35.43 GiB | 39.89 GiB | `+12.61%` |
| space_amp | 1.285 | 1.447 | `+12.61%` |

### LSM 形态发生了什么变化

`overwrite` 完成后的最终形态是：

| Style | 总文件数 | 总大小 | 形态 |
| --- | ---: | ---: | --- |
| level | 151 | 36,253 MB | `L0: 7`, `L4: 9`, `L5: 15`, `L6: 120` |
| universal | 283 | 40,751 MB | `L3: 17`, `L4: 31`, `L5: 119`, `L6: 116` |

这是整个 benchmark 切片里，leveled 和 universal 差异最清楚的一组结果。

Leveled 更积极地 compact，最终 DB 更小，文件数更少。Universal 则重写了更少的字节，但代价是保留了更多中间层 sorted run。

### 根因

Leveled compaction 天然倾向于把 overlap 一层一层往下清理。一旦 update 积累起来，字节就会随着跨层下推而反复被读和重写。compaction counters 正好就是这种模式：

- compaction read bytes 更高
- compaction write bytes 更高
- compaction 总 wall-clock 时间也高得多

Universal compaction 的核心思路是：只要 read amplification 和 size amplification 还在可接受范围内，就允许保留多个 sorted run 并推迟完全归并。在本次配置下：

- `max_read_amp=8` 对 sorted-run fanout 设了上限
- `max_size_amplification_percent=50` 明确允许比 fully compacted leveled tree 更高的空间放大
- `incremental=1` 避免形成过大的单次 compaction burst
- `reduce_file_locking=1` 则让 picker 更倾向于规避 write-stop 压力

这组参数在 SSD 的 overwrite-heavy 负载下其实非常合适。因为 SSD 不像 HDD 那样依赖严格的顺序写，真正主要的成本变成了后台 rewrite 总量，以及 compaction 对前台读写的干扰，而不是磁头 seek。

### interval 行为证据

`overwrite` 期间的 interval compaction 行为如下：

| 指标 | level | universal |
| --- | ---: | ---: |
| avg interval ops/sec | 44,894.54 | 45,728.78 |
| interval ops CV | 0.0243 | 0.0314 |
| avg interval compaction write MB/s | 681.73 | 460.97 |
| max interval compaction write MB/s | 773.61 | 532.91 |
| max pending compaction bytes | 17.94 GiB | 0 GiB |
| write delays / stops | 0 / 0 | 0 / 0 |

这里有两个点尤其关键：

1. 两种 style 都没有 stall，所以这次 benchmark 不是“谁先挂掉”的饱和型结果
2. Level 累积了接近 `18 GiB` 的 pending compaction debt，而 universal 始终是 `0`

这就是为什么在两边都没有正式 write stall 的情况下，universal 仍然能保持略高吞吐和更好 tail latency。差别来自后台债务积累，而不只是来自“有没有 stall”。

### trade-off

这一组 workload 几乎把 universal compaction 的典型交易关系完整展示出来了：

- 如果目标是尽量少 rewrite，并降低 SSD 后台 compaction 压力，那么 universal 明显更优
- 如果目标是把最终 on-disk shape 控得更紧、文件数更少，那么 leveled 更优

这不是一个小 trade-off。Universal 把 `total_lsm_wa` 降低了约 `37%`，但代价是最终 DB 大小增加了约 `13%`，live file 数也接近翻倍。

## 混合 workload：`readwhilewriting`

### 结果

| 指标 | level | universal | 差异 |
| --- | ---: | ---: | ---: |
| ops/sec | 108,485 | 111,234 | `+2.53%` |
| avg us | 285.72 | 278.66 | `-2.47%` |
| P50 us | 252.70 | 250.48 | `-0.88%` |
| P95 us | 501.64 | 469.38 | `-6.43%` |
| P99 us | 840.53 | 766.79 | `-8.77%` |
| P99.9 us | 2920.66 | 2621.22 | `-10.25%` |
| P99.99 us | 6525.52 | 6256.47 | `-4.12%` |
| compaction read GB | 148.21 | 118.68 | `-19.93%` |
| compaction write GB | 154.21 | 119.78 | `-22.33%` |
| compaction seconds | 526.5 | 207.1 | `-60.66%` |
| total_lsm_wa | 6.814 | 5.244 | `-23.04%` |
| 最终 DB 大小 | 35.31 GiB | 30.38 GiB | `-13.96%` |
| space_amp | 1.281 | 1.102 | `-13.96%` |
| read_amp_proxy | 1.0565 | 1.0400 | `-1.56%` |

### 为什么这组结果比 `overwrite` 更值得注意

`overwrite` 呈现的是预期中的 universal trade-off：更低的 write amplification，但更高的空间放大。

`readwhilewriting` 则没有出现这个经典 trade-off。Universal 不仅 compaction 成本更低，最终空间放大也更低。

这是整个 benchmark 切片里最值得注意的细节。

### 可能的解释

这个 mixed workload 的写入流强度明显低于 `overwrite`。`readwhilewriting` 在 `db_bench` 中是大量 reader 加一个 writer，而 `overwrite` 则用了 `16` 个 writer 线程。

在较轻的写入压力下：

1. Universal 依然保留了“每单位写入触发更少 rewrite”的优势
2. 后台 compaction 还有足够余量去消化重复历史，而不至于让 sorted run 数量和空间放大继续膨胀
3. Level 仍然要承担它本来的跨层 rewrite 成本，但已经拿不到“最终布局更紧凑”这个补偿优势

这里同样是基于 workload 结构和 counters 的推断。数字本身已经足够支持这个判断：

- universal 的 compaction read 更低，compaction write 更低，compaction 时间也低得多
- universal 最终 on-disk 大小不是更大，而是更小
- universal 的 read amplification proxy 和 tail latency 也更低

换句话说，当写入强度低于 `overwrite` 那个“用空间换 rewrite”的阈值后，universal 就不需要再用更高的 size amplification 来换取更低的 write amplification 了。

### interval 行为证据

`readwhilewriting` 期间的 interval 行为如下：

| 指标 | level | universal |
| --- | ---: | ---: |
| avg interval ops/sec | 164,596.17 | 166,120.70 |
| steady-state interval ops/sec | 164,669.91 | 166,775.82 |
| interval ops CV | 0.0403 | 0.0437 |
| avg interval compaction write MB/s | 171.10 | 124.18 |
| max interval compaction write MB/s | 228.10 | 225.65 |
| max pending compaction bytes | 18.06 GiB | 0 GiB |
| write delays / stops | 0 / 0 | 0 / 0 |

两边的 throughput CV 很接近，所以不能简单说 universal “波动明显更小”。它真正的稳定性优势来自别的方面：

- universal 没有积累 pending compaction debt
- universal 平均后台 compaction 带宽更低
- P95、P99、P99.9 全都更低

这比单纯“ops/sec 曲线更平”更有价值，因为它说明前台请求没有被后台 rewrite 明显拖累。

## 跨 workload 综合结论

对于这次已经完成的 SSD benchmark 切片，有四个规律是稳定出现的。

### 1. Universal 显著减少了 compaction 工作量

这一点在两个带写 workload 里都成立，而且不是边缘改进，而是足以改变读写干扰关系的量级。

### 2. Compaction 工作量下降，直接换来了更低的 tail latency

吞吐提升并不大，但 tail-latency 改善是重复出现的：

- `readrandom`: P95/P99/P99.99 更低
- `overwrite`: P95/P99/P99.99 更低
- `readwhilewriting`: P95/P99/P99.9/P99.99 更低

这和 SSD 上的常识是对齐的。当后台 rewrite 压力降低时，前台读就不需要再和 compaction traffic 激烈争抢。

### 3. Universal 的空间 trade-off 是 workload 相关的，不是恒定不变的

在 `overwrite` 上它更差，在 `readwhilewriting` 上却更好。

所以真正的问题不是“universal 会不会增加空间放大”，而是：

> 在当前写入速率和 merge 策略下，系统是否处在一个 universal 还能跟上、而不会让 sorted run 持续膨胀的区间里？

对于重 overwrite，这次答案是“不能完全跟上”，所以 universal 用空间换了 rewrite。
对于 mixed read/write，这次答案是“可以跟上”，所以 universal 同时节省了 rewrite 和空间。

### 4. Leveled 的主要结构优势，在这次切片里没有主导最终性能

Leveled 的目标优势本来是更紧凑、更偏底层的 LSM，以及更低的 read fanout。这个优势在 LSM 形态上是看得见的，但没有主导最终的端到端性能。

为什么？

- 这是 SSD workload，不是 HDD workload
- 读是 point lookup，不是 scan
- 数据规模属于中等，不是超大档
- universal 节省下来的 compaction 工作量很大

在这些条件下，“减少 rewrite 成本”的价值比“极致压缩 sorted run 数量”的价值更高。

## 实际建议

仅根据这次已经跑完的切片，可以得到下面的使用建议。

### 更适合优先考虑 universal 的情况

- 部署环境是 SSD
- workload 以 update-heavy 或 mixed read/write 为主
- 你关心 write amplification 和 compaction 带宽
- 你可以接受一定程度的 sorted run 增多或空间放大

### 更适合优先考虑 leveled 的情况

- 你更关注最终 on-disk shape 的紧凑性，而不是 rewrite 成本
- 持续 overwrite 压力很高，universal 容易留下过多中间 sorted run
- 环境对 read fanout 的敏感度高于对 compaction traffic 的敏感度

### 这次切片对当前环境的具体指向

对于这个 host、这个 `ssd_bundle`、这个 `kv128` profile，`universal` 是更值得作为默认起点的 compaction policy。

因为它在这次实测里赢在了：

- 只读吞吐和 tail latency
- overwrite 吞吐和 tail latency
- mixed read/write 吞吐和 tail latency
- write amplification
- compaction time
- pending compaction debt

它唯一明确输掉的点，是在最重的 overwrite workload 下，最终数据库大小更大。

## 局限性

这篇分析不能被理解成“所有 RocksDB SSD workload 都应当选择 universal”。

这次切片存在明确限制：

- 只完成了一个 profile：`kv128`
- 只跑了 `1` 次 repeat
- 只测了 `ssd_bundle`，没有测 `default_bundle`
- 只测了 point lookup 和 update-heavy workload，没有测 scan 或 miss-heavy read
- 没有采集 OS 侧设备遥测，因此分析主要依赖 RocksDB counters 和 `db_bench` 输出
- flush/compaction direct I/O 因当前环境下复现 checksum corruption 而保持关闭

因此更严谨的结论应该是：

> 在当前这台 SSD 主机、这个 profile、这套 tuning bundle 下，universal 是这次已完成 benchmark 切片里的更优 compaction policy。

这是一个强烈的本地结论，但不是对所有 RocksDB 部署的普遍推荐。

## 建议的下一步验证

如果这次结果将被用于推动生产决策，那么信息价值最高的后续补充测试是：

1. `kv1k` 跑同样的矩阵，并把 `repeats` 提到 `3`
2. `kv4k` 跑同样的矩阵，并把 `repeats` 提到 `3`
3. 加一组 miss-heavy point-read workload
4. 同样的切片在 `default_bundle` 下再跑一遍

这四组补充测试能回答当前最大的未决问题：

当前看到的 universal 优势，到底主要是 `kv128 + ssd_bundle` 的局部现象，还是能推广到更大 value 和更少人工调优的配置中。
