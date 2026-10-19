# 全 CPU 定向与随机验证

这些测试是开发用补充测试，不修改官方 `scripts/` 或 `testcases/`。生成器、RV32IM 参考模型和回归运行器只依赖 Python 标准库。生成文件放在 `build/verification/`，失败镜像会复制到该次运行的日志目录，后续重新生成测试不会覆盖失败证据。

```sh
python3 verification/directed/generate.py
python3 -m unittest discover -s verification/runners -p 'test_*.py'
python3 verification/runners/audit_cases.py --cases testcases
```

已安装 GNU RISC-V 工具时，还可独立核对机器码编码器：

```sh
python3 verification/runners/audit_cases.py \
  --cases build/verification/cases --assembler
```

每组生成 `program.data`、可审阅的 `program.S`、逐字编码 `program.words`、`expected.txt`、`metrics.json`、逐条架构提交 `reference.jsonl` 和 `meta.json`。`program.S` 包含指令部分；初始化数据以 `program.data` 为准。期望结果由独立的按序功能模型执行机器码得到，而不是根据测试名称指定。

## 当前 V7 验收配置

生成器默认 `--recovery-mode v7`，对应生产目录 `verilog/`。共 **63 个程序：55 组定向、8 个随机种子**，外存延迟 1/10/31 下共 **189 次**严格验收。正式 Linux 结果与性能、面积、频率见 [V7 实施记录](../../docs/experiments/v7.md)。

```sh
python3 verification/directed/generate.py --out build/verification/v7-cases --recovery-mode v7
python3 verification/runners/build_trace.py --out build/verification/v7-trace
python3 verification/runners/run_cpu.py --sim build/verification/v7-trace/sim \
  --cases build/verification/v7-cases --latencies 1,10,31
```

V7 保留之前各类覆盖义务，并按双选择、8 个检查点、32 KiB D Cache 调整刺激。`cache_conflict_dirty` / `cache_partial_allocate` 使用 **8 KiB 同组间隔**，`cache_exit_dirty` 以 **256 B 行步长**写脏 256 行。错误路径长操作用预热取指和真实数据依赖保证请求在取消前已经接受；检查点饱和要求 8 项占满后第 9 个分支等待释放。

新增 11 个程序覆盖：

| 测试 | 必须实际出现的证据 |
| --- | --- |
| `late_store_*` | SB/SH/SW 各自的别名与非别名对照；Store 地址先完成、数据生产者仍未发射；非别名 Load 越过，别名 Load 重试后前进 |
| `v7_lane_pairs` | 同拍双访存分配、双整数选择、Store+控制流选择，以及第二位置 Load/Store 提交 |
| `v7_mixed_retire` | 整数+MDU、Store+控制流真正同拍退休 |
| `v7_second_checkpoint` | 第二位置 JALR 检查点包含第一条映射和自身 link，包含同组 RAW/WAW |
| `v7_retry_recovery` | 更老的阻塞 Load 跨年轻分支恢复保留动态身份，之后只接受、完成、提交一次 |
| `v7_cancel_late_store` | 错路 Store 已有地址但没有数据；取消后 ROB 槽位先复用，老生产者才完成，旧 Store 不得捕获晚到数据 |

`v7_checks.py` 总是核验实际选择宽度、唯一执行、重试身份、Store 数据源归属和逐字节最年轻旧写转发。`--no-ooo --no-speculation-coverage` 只供兼容配置跳过依赖默认窗口的计时义务，仍保留上述不变量、全部架构提交、访存身份和恢复守恒检查；默认发布验收不使用这些开关。

总入口还在五组兼容配置上各执行 189 次回归。其中单独关闭并行完成、保留提前恢复的配置，要求 `selective_response_collision` 在三种延迟下都真实触发 `EX_KEEP`，并证明该旧身份之后唯一执行、完成和提交；两个单完成口配置另做 Yosys 组合环路检查。

在课程 Linux 容器的 `/work` 中，一次运行全部官方、定向、兼容参数、故障、单元、形式等价及综合检查：

```sh
python3 verification/runners/run_v7_linux.py --jobs 3
```

该入口创建独立时间戳输出目录并检查运行前后的源码摘要；任意步骤失败立即退出。`collect_v7_results.py` 核对完整矩阵、源码、镜像摘要、性能周期以及三项门槛后生成结果 JSON。

| 测试 | 覆盖目标 |
| --- | --- |
| `integer_isa` | 所有 RV32I 整数运算、正负边界、移位量、x0、AUIPC |
| `memory_lanes` | LB/LBU/LH/LHU/LW、SB/SH/SW、每个字节 lane、符号扩展、重叠写、负偏移、未初始化数据 |
| `m_extension` | 全部 8 条 M 指令、符号组合、除零、INT_MIN/-1、高位乘法 |
| `dependencies_wrap` | RAW/WAW/WAR、同源/同目标、96 轮持续分配释放、队列回绕 |
| `jumps_branches` | 全部条件分支、正负与无符号比较、后向循环、JAL/JALR link、JALR rd=rs1、清最低位 |
| `ooo_mdu` / `ooo_load` | 年轻独立指令先于更老依赖指令发射，按程序顺序提交 |
| `flush_*` | 预热后的错误路径 Store、MMIO、非法指令确实进入窗口并发射；合法/越界 Load 与 MDU 在途被杀；合法 Load 旧响应回来前已复用物理目的寄存器 |
| `random_*` | 固定种子的整数/M/访存/分支混合，默认 8 个种子，每个 250 个随机操作 |
| `prediction_loop_exit` | taken 循环训练后的正确预测，以及最后一次 not-taken 恢复 |
| `prediction_jalr_switch` | 同一 JALR 的目标 A→B 变化、目标恢复、每次调用的 link |
| `prediction_btb_alias` | PC 0x100/0x4100 同时冲突于 64 项低位索引和 XOR 折叠索引，强制替换后恢复；legacy 模式保留原 256 B 间隔 |
| `pipeline_completion` | 单写回模式强制 Load/MDU 抢占后 EX 保持；双完成模式分别强制 Load+EX、MDU+EX 同拍完成，均仅执行/提交一次；IQ 插入与源写回同拍 |
| `memory_order_wrap` | 97 轮 Store/Load/部分字节更新，验证 ROB 槽位反复复用后的 older-store 位清理 |
| `cache_conflict_dirty` | 7 个同组地址（V7 间隔 8 KiB，V5/V6 为 4 KiB）、5 轮脏行替换、部分写与全字重读 |
| `cache_partial_allocate` | 冷 SB/SH 写分配，保留未写字节；冲突替换后逐字节核对 |
| `cache_exit_dirty` | 写脏 256 行，最后更新后直接 MMIO；CPU 层核对架构数据，外存实际排空由存储单测核验 |
| `flush_dirty_store` | 错路 SB 命中预先写入的驻留行，必须发射后被杀且原数据保持 |
| `flush_writeback_load` | 错路 uncached Load 触发脏行排空后被杀；配合专用注入器验证写回失败后的重试 |
| `lsu_forward_youngest` / `lsu_forward_partial` | 长 DIV 阻止旧 Store 退休时，SW/SB/SH 逐字节按年龄转发；完整覆盖与部分覆盖合并，以及符号扩展 |
| `lsu_nonalias_bypass` | 已知地址的旧 Store 尚未退休，年轻非别名 Load 已进入 LSU，转发 mask 必须为 0 |
| `lsu_unknown_address` / `lsu_unknown_data` | 年轻 Load 已分配但必须等旧 Store 的未知地址/数据就绪；41 轮覆盖 ROB 回绕 |
| `lsu_younger_store_age` | 年轻 Store 地址/数据先就绪，仍不能转发给等待 DIV 地址的旧 Load，也不能先于它退休 |
| `lsu_multiple_loads` | 至少两笔已被 Cache 接收且尚未响应的 Load；之后连续冷 miss 验证顺序和目的寄存器身份 |
| `lsu_killed_hits` / `lsu_killed_reuse` | 同一 flush 杀死至少两个 Load 上下文；前者要求两笔请求已接受，后者要求冷 miss 旧响应前复用物理目的寄存器 |
| `lsu_committed_store_flush` | 已退休、尚未响应的缓冲 Store 跨 redirect 仍存活；错路 Store 不得改写其值 |
| `early_older_override` | 年轻分支先请求提前取指，延迟执行的老分支随后以精确动态身份覆盖它 |
| `early_commit_collision` | 老分支重定向提交与年轻分支解析同拍，必须阻止年轻提前取指覆盖老分支目标 |
| `selective_keep_mdu` / `selective_keep_load` | 选择恢复时老长操作确实在途，保留原身份且仅完成/提交一次；恢复目标的独立指令先于老结果执行 |
| `selective_keep_store` / `selective_keep_jalr` | 老 Store 尚在 IQ 等待操作数时跨恢复保留（V7 等基址）；JALR rd=rs1 的 checkpoint 保留自身 link，错误路径 WAW 不得遮蔽老映射 |
| `selective_wrap_mdu` | ROB 环绕窗口按年龄保留老 MDU，禁止用槽位数值比较年龄 |
| `selective_response_collision` | 有限间隔扫描，必须实际观察老 Load 与 MDU 响应恰在恢复拍被保持，后来唯一完成且无取消 |
| `selective_checkpoint_full` | 老 DIV 未完成时已执行分支占满 checkpoint，下一分支等待首次提交释放后才重命名；V7 为 8+1，V5/V6 为 4+1 |

## 历史 V6 双宽配置

复现 V6 时使用冻结提交 `a661936` 的独立 checkout，并以 `--recovery-mode wide` 生成验收集；当前默认 RTL 已是 V7：

```sh
python3 verification/directed/generate.py --out build/verification/v6-cases --recovery-mode wide
python3 verification/runners/build_trace.py --out build/verification/v6-trace
python3 verification/runners/run_cpu.py --sim build/verification/v6-trace/sim \
  --cases build/verification/v6-cases --latencies 1,10,31
verification/unit/run_wide_fetch.sh
```

该配置共 52 个程序，延迟 1/10/31 下执行 156 次。原 `selective`、`legacy` 生成模式继续用于历史版本，不改变其默认行为。双宽模式调整三项 LSU 用例和恢复响应碰撞的指令间隔，使双发射下仍实际触发旧有严格覆盖要求；没有降低已接受在途请求数、取消数量或恢复拍保持要求。

- `wide_rename_retire`：同组 RAW/WAW、x0、PRF 回收、ROB 回绕；轨迹必须出现真正存活并提交的双分配、双发射、双提交。
- `wide_checkpoint_pair`：同拍 JAL 链接寄存器重命名与年轻 WAW，恢复必须保留 JAL 自身映射、取消同组年轻指令和错路 Store。
- 双取指单测覆盖 7 组 FIFO/在途/直通/重定向参数、请求和译码背压、部分消费、第二位置预测、取消及共享错误。另以 8/128 B I 行、两种响应模式检查两字数据与行尾错误重试。

宽度证据由 `wide_checks.py` 检查并记录于 `summary.json` 的 `wide_evidence`。兼容配置可关闭与默认结构有关的覆盖要求，但不能以兼容结果替代默认配置的严格验收；架构逐提交、顺序与请求身份检查仍保留。

## 对接仿真器

运行器直接使用官方仿真器位置参数协议：`sim IMAGE EXPECTED MAX_CYCLES LATENCY`，不修改框架。正常的非 trace 构建可使用 `--result-only` 检查最终结果；完整验收需要顶层 `TRACE=1` 构建，必须提供逐条提交轨迹。默认周期上限为 100,000,000，避免把长正确性程序误判为超时。

```sh
python3 verification/runners/build_trace.py --out build/verification/trace
python3 verification/runners/run_cpu.py --sim build/verification/trace/sim --latencies 1,10,31
python3 verification/runners/run_cpu.py --sim build/verification/trace/sim --case 'flush_*'
python3 verification/runners/run_cpu.py --sim build/verification/trace/sim --cases testcases --case correctness_naive
python3 verification/runners/run_cpu.py --sim build/macos/sim --result-only
```

`build_trace.py` 使用官方 `scripts/sim.cpp`，默认添加顶层 `TRACE=1`。可重复传入 `--param NAME=VALUE` 覆盖参数，并用独立输出目录避免覆盖其他构建；例如 `--param ROB_DEPTH=15 --param PRF_SIZE=47`。每次保存工具命令、参数与源码 SHA-256；具体参数名和合法范围以当前 `student_top` 为准。该入口需要本机 Verilator/C++/Make，也可在已配置课程工具链的 Linux 容器内运行。

扩展随机规模时保留种子，便于复现：

```sh
python3 verification/directed/generate.py \
  --seeds 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16 --random-count 1000
```

## 轨迹约定与严格验收

RTL 在不可撤销提交时打印以下格式；十六进制字段可带或不带 `0x`：

```text
CPU_TRACE COMMIT seq=0 id=0 cycle=7 pc=00000000 insn=123450b7 rd=1 value=12345000 store=0 addr=00000000 data=00000000 strb=0
CPU_TRACE ISSUE id=0 cycle=5 pc=00000000 insn=123450b7
CPU_TRACE COMPLETE id=0 cycle=6 pc=00000000 insn=123450b7
CPU_TRACE DISPATCH id=0 cycle=4 pc=00000000 insn=123450b7 rd=1 pdst=32
CPU_TRACE FLUSH id=22 cycle=692 pc=00000054 target=00000060 load_pending=1
CPU_TRACE DROP_LOAD id=23 cycle=767 pc=00000058
CPU_TRACE WB_STALL id=42 cycle=200 pc=00000040 source=1
CPU_TRACE RENAME_BYPASS id=43 cycle=201 pc=00000044 source=3
CPU_TRACE LOAD_QUEUE id=44 cycle=203 pc=00000048 mask=e depth=2
CPU_TRACE MEM_REQUEST id=44 cycle=204 pc=00000048 write=0 addr=00010000 killed=0
CPU_TRACE MEM_RESPONSE id=44 cycle=220 pc=00000048 write=0 killed=0
CPU_TRACE STORE_RETIRE id=45 cycle=221 pc=0000004c
CPU_TRACE EARLY_FETCH id=46 cycle=222 pc=00000050 target=00000060 prev_id=47 override=1
CPU_TRACE EARLY_BLOCK id=47 cycle=223 pc=00000054 head_id=46
CPU_TRACE CONFIG id=0 cycle=0 pc=00000000 early_recovery=1 dual_wb=1
CPU_TRACE FLUSH id=22 cycle=692 pc=00000054 target=00000060 load_pending=1 prepared=0 selective=1 head_id=20 kept=3 killed=4
CPU_TRACE DROP_MDU id=23 cycle=692 pc=00000058
CPU_TRACE RECOVERY_HOLD id=20 cycle=692 pc=0000004c source=2
CPU_TRACE WB_PAIR id=42 cycle=200 pc=00000040 load_id=40 ex_id=42 memory=1
CPU_TRACE CONFIG id=0 cycle=0 pc=00000000 early_recovery=1 dual_wb=1 version=7 select_width=2 rename_width=2 commit_width=2 checkpoints=8 select_load=1 execute_redirect=1
CPU_TRACE SELECT id=44 cycle=201 pc=00000048 insn=0000a283 lane=0 fast=0
CPU_TRACE LOAD_RETRY id=44 cycle=202 pc=00000048 hazard=1 space=1
CPU_TRACE STORE_ADDR id=43 cycle=200 pc=00000044 addr=00010000 strb=f ready=0 psrc=35
CPU_TRACE STORE_DATA id=43 cycle=203 pc=00000044 data=12345678 late=1 psrc=35
CPU_TRACE LOAD_QUEUE id=44 cycle=204 pc=00000048 mask=f depth=2 addr=00010000 data=12345678 fast=1
CPU_TRACE EX_KEEP id=40 cycle=202 pc=00000038 insn=00108093
```

- `seq` 是从 0 连续递增的架构退休序号；`id` 是分配时的唯一动态指令编号，冲刷后允许留空号。
- 没有寄存器写回时 `rd=0 value=0`；写 x0 也按无写回处理。
- Store 使用对齐 4 字节的 `addr`、左移到正确 byte lane 的 `data` 和 `strb`。比较器忽略未使能 byte lane 的数据。
- Store 的 COMMIT 可在 ROB 头且不可撤销地交给存储系统时打印。最终退出 Store 必须先记录，因为官方仿真器在退出 B 响应握手时立即结束。不能在 B 响应时重复打印。
- V4 普通 RAM Store 在 ROB 头进入不可撤销队列时 COMMIT/STORE_RETIRE，可能早于 Cache 的 MEM_REQUEST；uncached Store 仍在请求握手时 COMMIT、响应后退队。MEM_REQUEST/MEM_RESPONSE 必须读取独立上下文保存的原始身份，不能读取已复用 ROB 槽位。
- 默认逐条检查 PC、指令、目的寄存器、结果和 Store 副作用；漏提交、重复提交和过早退出均失败。
- OoO 探针要求匹配最终已提交的动态 `id`：年轻独立 ADD 的 ISSUE 周期早于更老依赖 ADD，而 COMMIT 序号晚于它。仅与长操作重叠执行不算发射乱序；错误路径上的同 PC 发射也不算证据。
- 错误路径探针先预热关键指令和恢复目标。默认必须观察错误指令 DISPATCH、ISSUE 先于指定分支 FLUSH，且从不 COMMIT。Load/MDU 还必须从不 COMPLETE；Load 必须在 FLUSH 时仍 `load_pending=1`，后来出现保留原始 `id/pc` 的 DROP_LOAD。
- `flush_load` 额外强制检查恢复路径最终提交的指令，在旧响应到来前复用了被杀 Load 的同一个 `pdst`。`flush_bad_load` 要求杀死与错误响应排空；最短外部延迟下错误响应会很快返回，因此不额外要求它的目的寄存器也提前复用。
- V2 预测测试要求指定控制流次数发生对应目标的 FLUSH，同时要求训练后的部分控制流无需 FLUSH。`pipeline_completion` 要求 Load（`source=1`）和 MDU（`source=2`）都实际阻塞过普通 EX 指令，且这些指令随后只 ISSUE/COMPLETE 一次并最终提交；RENAME_BYPASS 的 `source` 分别表示 rs1、rs2、两者同拍命中写回。
- V4 LSU 探针区分 LOAD_QUEUE 与真正接受的 MEM_REQUEST；`depth` 是十进制，`mask` 是十六进制。逐事务检查接受/响应身份、FIFO 顺序、取消后禁止 COMPLETE/COMMIT，以及退出时不能遗留更老事务。转发探针还要求对应旧 Store 在 Load 进入队列时均已完成地址/数据计算但仍未 COMMIT。多取消探针按动态分支 `id` 排除预热时同 PC 的已提交 Load，并要求原上下文 DROP_LOAD。
- 提前取指检查要求具体 EARLY_FETCH 覆盖事件的 `prev_id`，以及正确的老分支目标和 `FLUSH prepared=1`。同拍竞争检查要求 EARLY_BLOCK 的 `head_id` 精确对应该拍提交的老分支，且年轻分支该拍没有 EARLY_FETCH、以后没有 COMMIT。仅通过最终结果不能满足这些要求。
- V5 选择恢复按全部 DISPATCH/COMMIT/STORE_RETIRE 重建 ROB 活跃身份，在每次 FLUSH 检查 head、保留数、取消数和年龄边界；任何被杀动态 id 后续 ISSUE/COMPLETE/COMMIT 均失败。uncached Store 的早期架构 COMMIT 不等于 ROB 退队，直到 STORE_RETIRE 才从活跃集合移除。该守恒检查在小参数回归中也不跳过。
- V5 的 `early_older_override` 要求年轻分支先真实选择恢复，随后更老分支再次恢复并取消年轻分支；`early_commit_collision` 的边界提前到 EX，要求年轻就绪分支已分配、在老分支检测恢复时不能被选入 EX，之后从未 ISSUE/COMMIT。按 FLUSH 的 `selective` 字段选择对应机制，不根据测试是否失败猜测模式。
- V5 双完成检查由 CONFIG 的 `dual_wb` 显式选择。两个不同动态 id 必须各有同拍 COMPLETE，两个最终都提交且只有一次 ISSUE/COMPLETE；Load 对应真实未取消 MEM_RESPONSE，MDU 对应 M 指令完成。旧单写回配置仍要求两种真实 WB_STALL。`slot/selective/kept/killed/load_id/ex_id` 均按十进制解析。
- V7 以 `SELECT` 检查真正的双选择宽度和 A/B 通路约束；`ISSUE` 表示执行接受，提前 Load 与上一拍 A/B 指令可能在同拍接受三条，但每个动态身份只接受一次。`LOAD_RETRY` 必须先于重新选择，接受后禁止重试。`STORE_ADDR/STORE_DATA` 核对数据源、生产者完成拍、字节偏移和退休载荷；`LOAD_QUEUE` 的 `data` 是逐字节转发快照，按当时全部存活旧 Store 的年龄重新计算。`EX_KEEP` 记录恢复拍保留的老 EX 身份。
- `--no-ooo` 和 `--no-speculation-coverage` 供小队列参数的纯功能回归或定位问题使用，只跳过对应计时覆盖，始终保留逐条提交对比。后者也跳过依赖默认 BTB 布局和默认流水窗口的 V2 预测/写回争用覆盖；报告记录实际启用的检查。`--result-only` 同时跳过全部轨迹检查，不能用于完整 CPU 验收。

## 历史 V5/V4 配置

`--recovery-mode selective` 生成 V5 的 **50 组**（42 组定向、8 个随机种子），`wide` 为 V6 的 52 组，当前默认 `v7` 为 63 组。`legacy` 保留 V4 原始 **43 组**时序刺激；V3 冻结版本为 31 组。V5 刺激让分支等待真实 producer，证明错误路径的在途取消、排空和复用；还用预热 Store 命中队列制造端口背压，证明多笔 Load 在途以及恢复拍的旧 Load/MDU 响应保持。复现历史硬件须采用相应实施记录标明的冻结 checkout。以下是 V5 的历史运行命令：

```sh
python3 verification/directed/generate.py --out build/verification/v5-cases --recovery-mode selective
python3 verification/runners/build_trace.py --out build/verification/v5-trace
python3 verification/runners/run_cpu.py --sim build/verification/v5-trace/sim \
  --cases build/verification/v5-cases --latencies 1,10,31
```

复现 V4 必须先在独立 checkout 中切到冻结提交 `98d4abd`，再执行该版本自己的生成器与构建脚本。当前默认硬件是 V7，`--recovery-mode legacy` 仅保留 V4 刺激，不能把当前默认构建当成 V4 硬件。以下命令在 `98d4abd` 的 checkout 中执行：

```sh
python3 verification/directed/generate.py --out build/verification/v4-cases
python3 verification/runners/build_trace.py --out build/verification/v4-trace
python3 verification/runners/run_cpu.py --sim build/verification/v4-trace/sim \
  --cases build/verification/v4-cases --latencies 1,10,31
python3 verification/runners/run_faults.py --sim build/verification/v4-trace/sim \
  --out build/verification/v4-faults --latencies 1,10,31
```

V5 非 2 的幂小参数配置的历史功能回归示例（在 V5 checkout 中先生成上述 cases；D 行宽必须独立覆盖为 8 B）。V7 的完整参数组以 `run_v7_linux.py` 中的 `PROFILES` 为准：

```sh
python3 verification/runners/build_trace.py --out build/verification/v5-trace-small \
  --param ROB_DEPTH=5 --param PRF_SIZE=37 --param IQ_DEPTH=3 --param LSQ_DEPTH=3 \
  --param MEM_QUEUE_DEPTH=3 --param BRANCH_CHECKPOINTS=3 --param RAS_DEPTH=3 --param DCACHE_WAYS=1 \
  --param ICACHE_BYTES=128 --param DCACHE_BYTES=128 --param CACHE_LINE_BYTES=8 \
  --param DCACHE_LINE_BYTES=8 \
  --param FETCH_QUEUE_DEPTH=5 --param FETCH_OUTSTANDING=3 --param BTB_ENTRIES=5
python3 verification/runners/run_cpu.py --sim build/verification/v5-trace-small/sim \
  --cases build/verification/v5-cases --latencies 1,10 --no-ooo --no-speculation-coverage
```

V5 当时的旧恢复/单完成参数分支也单独做功能回归，不能用冻结 V4 二进制代替该检查。以下历史命令保留逐提交、全部访存身份与恢复后取消身份守恒；只跳过依赖默认机制与窗口的计时证据。V7 总入口在当前 RTL 上重测对应参数分支：

```sh
python3 verification/runners/build_trace.py --out build/verification/v5-trace-legacy \
  --param EARLY_RECOVERY=0 --param PARALLEL_COMPLETION=0
python3 verification/runners/run_cpu.py --sim build/verification/v5-trace-legacy/sim \
  --cases build/verification/v5-cases --latencies 1,31 --no-ooo --no-speculation-coverage
```

参考模型只覆盖本课要求的用户态 RV32IM，自然对齐访问；不模拟特权、异常处理、CSR、FENCE、ECALL/EBREAK 或周期性能。它不会把架构路径上非法指令、越界访问静默跳过。随机总线背压需要总线单元测试环境支持；官方仿真器延迟扫描只能覆盖不同响应延迟和其固定的从机行为，不能声称等价于任意独立通道背压测试。

课程 Linux 容器包含 Verilator，未安装 Icarus。可在容器 `/work` 内运行 `verification/runners/run_linux_units.sh`，用 `--timing --assert` 编译相同的 decoder/ALU、MDU 与前端测试台；前端组合和执行单元配置以该脚本当前列表为准；脚本遇到断言错误必须返回失败。`CPU2026_LINUX_UNIT_BUILD` 控制独立输出目录，`CPU2026_UNIT_JOBS` 控制构建并行数，逐配置保存编译与执行日志。

## 从逐提交轨迹测量瓶颈

先运行六个性能程序并逐提交核对，再把输出中的时间戳目录传给分析器：

```sh
python3 verification/runners/run_cpu.py --sim build/verification/trace/sim \
  --cases testcases --case 'perf_*' --latencies 10 --out build/verification/perf-trace
python3 verification/runners/analyze_trace.py \
  --runs build/verification/perf-trace/TIMESTAMP \
  --sim build/verification/trace/sim --out build/verification/perf-analysis.json
python3 verification/runners/analyze_dependencies.py \
  --runs build/verification/perf-trace/TIMESTAMP \
  --out build/verification/dependency-analysis.json
python3 verification/runners/analyze_backend.py \
  --runs build/verification/perf-trace/TIMESTAMP \
  --out build/verification/backend-analysis.json
```

分析器统计已提交 Load 的 ISSUE→COMPLETE 延迟分布、分配到发射等待、Store 发射到请求等待、控制流恢复比例、FLUSH 到下一次提交的间隔及写回冲突事件。Store 的 COMMIT 早于真实 ROB 退队，因此 V2 轨迹不能直接给出精确 B 等待或 Store 占据 ROB 头的周期数。分析器报告全部 Store 后的提交空档，以及其中后继指令早已完成的保守下界；两者之间还可能包含后继自身的等待。V3 新增 MEM_RESPONSE/STORE_RETIRE 后，还可准确统计请求握手→CPU 接收响应、请求握手→ROB 退队的间隔；这仍不包含请求前已在 ROB 头的等待，最终退出 Store 也可能因官方框架立即停机而没有这两个事件。Load 延迟、恢复间隔和提交空档会重叠，不能相加当成 CPI 分解。预测率仅统计已提交控制流，Load 延迟仅统计最终提交的动态指令身份。

V4 优先使用显式 MEM_REQUEST 作为服务起点，另列 Store COMMIT→REQUEST、COMMIT→ROB 退队和 Load 入队→请求、请求→响应；已经先退休的 Store 不计入 REQUEST→RETIRE 分布，避免用负值误称等待时间。Store 后提交空档只是程序退休间隔，不能归因于 Store 头阻塞。依赖分析器通过已提交动态身份重建最近源寄存器生产者，统计生产者 COMPLETE→消费者 ISSUE、分支 ISSUE→FLUSH，并按下一条指令的状态分配提交空档；同样不是互斥的微架构停顿归因。方向预测回放采用已提交结果即时训练，只有理想化算法比较意义，不能作为预测 IPC。

V5 的 FLUSH 可早于自身分支提交，而且年轻恢复分支可能随后被更老分支取消；统计控制流类别必须在收齐提交后匹配动态身份，未提交恢复单列。`flush_to_next_commit` 仍只是字面的下一次提交（可能是保留的老指令），`post_mispredict_branch_retirement_idle` 才表示该误预测分支退休后到架构后继的空拍。后端分析器另按指令编码统计 MUL/DIV 各操作数量、真实服务时长和处于下一退休位置的 MDU 等待区间；不能根据性能程序的名字推断用了乘除单元。

`compare_recovery.py --baseline BASELINE_RUN --candidate CANDIDATE_RUN --out recovery.json` 比较相同流水级：仅对最终退休、且有 EARLY_FETCH/FLUSH 的控制指令，测量 EX 检出误预测到其下一条架构指令 DISPATCH 的间隔，并核对后继 PC 等于实际恢复目标。报告按事件加权平均及每程序分布，排除后来被取消的控制指令；这个区间同样不能直接折算可节省的 CPI。

## CPU 级写回错误注入

下面是独立的验证专用构建，普通回归继续使用未修改的官方 `sim.cpp`。注入器复用官方镜像加载、RAM 和读服务代码，在指定地址首次写回时返回 SLVERR，并在退出 AW 握手前检查架构 Store 的外存字节与先前 B 响应已经完成。它不改变 RTL，也不用于课程性能数字。

```sh
python3 verification/runners/build_trace.py --out build/verification/writeback-fault-trace \
  --harness verification/runners/writeback_fault_sim.cpp
python3 verification/runners/run_writeback_faults.py \
  --sim build/verification/writeback-fault-trace/sim --latencies 1,10,31
```

两条合法路径分别要求当前触发 Load/退出 Store 的准确 fault 编号和 PC；错误不能伪装成更早已退休 Store 的精确异常。错路测试先把一行写脏，再让年轻 uncached Load 触发排空，向第二个写回字注入错误。它必须在恢复后以原动态 `id` 出现唯一 `MEM_RESPONSE killed=1` 与 `DROP_LOAD`，不 COMPLETE/COMMIT；最终 MMIO 必须重试脏行并成功，退出前核对 16 个已提交 RAM 字节。每次仍逐条对比成功路径的架构提交。注入器通过环境变量选择故障地址与外存核对文件，运行器统一配置并保存日志，避免把单纯超时或任意 abort 当成成功。

V4 额外加入 `buffered_ram_store_fault`：四路同组填满后，已退休 RAM Store 触发脏行替换错误。专用故障 B 额外延迟 256 周期，确保发生 redirect 和至少 16 条年轻退休；必须仍用上下文保存的原 Store PC 诊断 `buffered_store=1`，逐条核对所有实际提交，禁止在更老错误前发送退出请求。它是异步错误合同，不改变前述两类 uncached 错误的精确前缀要求。默认总计 **4×3=12** 次错误注入运行。
