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
| `prediction_btb_alias` | 相差 256 B 的两个控制流地址冲突于默认 64 项 BTB，禁止借用另一条指令的目标 |
| `pipeline_completion` | V2 寄存 EX 被 Load/MDU 完成抢占写回端口后保持且仅执行一次；IQ 插入与源写回同拍 |
| `memory_order_wrap` | 97 轮 Store/Load/部分字节更新，验证 ROB 槽位反复复用后的 older-store 位清理 |
| `cache_conflict_dirty` | 7 个相差 4 KiB 的同组地址、5 轮脏行替换、部分写与全字重读 |
| `cache_partial_allocate` | 冷 SB/SH 写分配，保留未写字节；冲突替换后逐字节核对 |
| `cache_exit_dirty` | 写脏 256 行，最后更新后直接 MMIO；CPU 层核对架构数据，外存实际排空由存储单测核验 |
| `flush_dirty_store` | 错路 SB 命中预先写入的驻留行，必须发射后被杀且原数据保持 |
| `flush_writeback_load` | 错路 uncached Load 触发脏行排空后被杀；配合专用注入器验证写回失败后的重试 |

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
CPU_TRACE MEM_RESPONSE id=44 cycle=220 pc=00000048 write=1 killed=0
CPU_TRACE STORE_RETIRE id=44 cycle=221 pc=00000048
```

- `seq` 是从 0 连续递增的架构退休序号；`id` 是分配时的唯一动态指令编号，冲刷后允许留空号。
- 没有寄存器写回时 `rd=0 value=0`；写 x0 也按无写回处理。
- Store 使用对齐 4 字节的 `addr`、左移到正确 byte lane 的 `data` 和 `strb`。比较器忽略未使能 byte lane 的数据。
- Store 的 COMMIT 可在 ROB 头且不可撤销地交给存储系统时打印。最终退出 Store 必须先记录，因为官方仿真器在退出 B 响应握手时立即结束。不能在 B 响应时重复打印。
- 默认逐条检查 PC、指令、目的寄存器、结果和 Store 副作用；漏提交、重复提交和过早退出均失败。
- OoO 探针要求匹配最终已提交的动态 `id`：年轻独立 ADD 的 ISSUE 周期早于更老依赖 ADD，而 COMMIT 序号晚于它。仅与长操作重叠执行不算发射乱序；错误路径上的同 PC 发射也不算证据。
- 错误路径探针先预热关键指令和恢复目标。默认必须观察错误指令 DISPATCH、ISSUE 先于指定分支 FLUSH，且从不 COMMIT。Load/MDU 还必须从不 COMPLETE；Load 必须在 FLUSH 时仍 `load_pending=1`，后来出现保留原始 `id/pc` 的 DROP_LOAD。
- `flush_load` 额外强制检查恢复路径最终提交的指令，在旧响应到来前复用了被杀 Load 的同一个 `pdst`。`flush_bad_load` 要求杀死与错误响应排空；最短外部延迟下错误响应会很快返回，因此不额外要求它的目的寄存器也提前复用。
- V2 预测测试要求指定控制流次数发生对应目标的 FLUSH，同时要求训练后的部分控制流无需 FLUSH。`pipeline_completion` 要求 Load（`source=1`）和 MDU（`source=2`）都实际阻塞过普通 EX 指令，且这些指令随后只 ISSUE/COMPLETE 一次并最终提交；RENAME_BYPASS 的 `source` 分别表示 rs1、rs2、两者同拍命中写回。
- `--no-ooo` 和 `--no-speculation-coverage` 供小队列参数的纯功能回归或定位问题使用，只跳过对应计时覆盖，始终保留逐条提交对比。后者也跳过依赖默认 BTB 布局和默认流水窗口的 V2 预测/写回争用覆盖；报告记录实际启用的检查。`--result-only` 同时跳过全部轨迹检查，不能用于完整 CPU 验收。

默认生成 **31 组**（23 组定向、8 个随机种子；V2 冻结版本为 26 组）。完整运行示例：

```sh
python3 verification/directed/generate.py --out build/verification/v2-cases
python3 verification/runners/build_trace.py --out build/verification/v2-trace
python3 verification/runners/run_cpu.py --sim build/verification/v2-trace/sim \
  --cases build/verification/v2-cases --latencies 1,10,31
python3 verification/runners/run_faults.py --sim build/verification/v2-trace/sim \
  --out build/verification/v2-faults --latencies 1,10,31
```

非 2 的幂小参数配置的纯功能回归示例：

```sh
python3 verification/runners/build_trace.py --out build/verification/v2-trace-small \
  --param ROB_DEPTH=5 --param PRF_SIZE=37 --param IQ_DEPTH=3 --param LSQ_DEPTH=3 \
  --param ICACHE_BYTES=128 --param DCACHE_BYTES=128 --param CACHE_LINE_BYTES=8 \
  --param FETCH_QUEUE_DEPTH=5 --param FETCH_OUTSTANDING=3 --param BTB_ENTRIES=5
python3 verification/runners/run_cpu.py --sim build/verification/v2-trace-small/sim \
  --cases build/verification/v2-cases --latencies 1,10 --no-ooo --no-speculation-coverage
```

参考模型只覆盖本课要求的用户态 RV32IM，自然对齐访问；不模拟特权、异常处理、CSR、FENCE、ECALL/EBREAK 或周期性能。它不会把架构路径上非法指令、越界访问静默跳过。随机总线背压需要总线单元测试环境支持；官方仿真器延迟扫描只能覆盖不同响应延迟和其固定的从机行为，不能声称等价于任意独立通道背压测试。

## 从逐提交轨迹测量瓶颈

先运行六个性能程序并逐提交核对，再把输出中的时间戳目录传给分析器：

```sh
python3 verification/runners/run_cpu.py --sim build/verification/trace/sim \
  --cases testcases --case 'perf_*' --latencies 10 --out build/verification/perf-trace
python3 verification/runners/analyze_trace.py \
  --runs build/verification/perf-trace/TIMESTAMP \
  --sim build/verification/trace/sim --out build/verification/perf-analysis.json
```

分析器统计已提交 Load 的 ISSUE→COMPLETE 延迟分布、分配到发射等待、Store 发射到请求等待、控制流恢复比例、FLUSH 到下一次提交的间隔及写回冲突事件。Store 的 COMMIT 早于真实 ROB 退队，因此 V2 轨迹不能直接给出精确 B 等待或 Store 占据 ROB 头的周期数。分析器报告全部 Store 后的提交空档，以及其中后继指令早已完成的保守下界；两者之间还可能包含后继自身的等待。V3 新增 MEM_RESPONSE/STORE_RETIRE 后，还可准确统计请求握手→CPU 接收响应、请求握手→ROB 退队的间隔；这仍不包含请求前已在 ROB 头的等待，最终退出 Store 也可能因官方框架立即停机而没有这两个事件。Load 延迟、恢复间隔和提交空档会重叠，不能相加当成 CPI 分解。预测率仅统计已提交控制流，Load 延迟仅统计最终提交的动态指令身份。

## CPU 级写回错误注入

下面是独立的验证专用构建，普通回归继续使用未修改的官方 `sim.cpp`。注入器复用官方镜像加载、RAM 和读服务代码，在指定地址首次写回时返回 SLVERR，并在退出 AW 握手前检查架构 Store 的外存字节与先前 B 响应已经完成。它不改变 RTL，也不用于课程性能数字。

```sh
python3 verification/runners/build_trace.py --out build/verification/writeback-fault-trace \
  --harness verification/runners/writeback_fault_sim.cpp
python3 verification/runners/run_writeback_faults.py \
  --sim build/verification/writeback-fault-trace/sim --latencies 1,10,31
```

两条合法路径分别要求当前触发 Load/退出 Store 的准确 fault 编号和 PC；错误不能伪装成更早已退休 Store 的精确异常。错路测试先把一行写脏，再让年轻 uncached Load 触发排空，向第二个写回字注入错误。它必须在恢复后以原动态 `id` 出现唯一 `MEM_RESPONSE killed=1` 与 `DROP_LOAD`，不 COMPLETE/COMMIT；最终 MMIO 必须重试脏行并成功，退出前核对 16 个已提交 RAM 字节。每次仍逐条对比成功路径的架构提交。注入器通过环境变量选择故障地址与外存核对文件，运行器统一配置并保存日志，避免把单纯超时或任意 abort 当成成功。
