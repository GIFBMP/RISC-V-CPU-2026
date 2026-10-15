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
```

- `seq` 是从 0 连续递增的架构退休序号；`id` 是分配时的唯一动态指令编号，冲刷后允许留空号。
- 没有寄存器写回时 `rd=0 value=0`；写 x0 也按无写回处理。
- Store 使用对齐 4 字节的 `addr`、左移到正确 byte lane 的 `data` 和 `strb`。比较器忽略未使能 byte lane 的数据。
- Store 的 COMMIT 可在 ROB 头且不可撤销地交给存储系统时打印。最终退出 Store 必须先记录，因为官方仿真器在退出 B 响应握手时立即结束。不能在 B 响应时重复打印。
- 默认逐条检查 PC、指令、目的寄存器、结果和 Store 副作用；漏提交、重复提交和过早退出均失败。
- OoO 探针要求匹配最终已提交的动态 `id`：年轻独立 ADD 的 ISSUE 周期早于更老依赖 ADD，而 COMMIT 序号晚于它。仅与长操作重叠执行不算发射乱序；错误路径上的同 PC 发射也不算证据。
- 错误路径探针先预热关键指令和恢复目标。默认必须观察错误指令 DISPATCH、ISSUE 先于指定分支 FLUSH，且从不 COMMIT。Load/MDU 还必须从不 COMPLETE；Load 必须在 FLUSH 时仍 `load_pending=1`，后来出现保留原始 `id/pc` 的 DROP_LOAD。
- `flush_load` 额外强制检查恢复路径最终提交的指令，在旧响应到来前复用了被杀 Load 的同一个 `pdst`。`flush_bad_load` 要求杀死与错误响应排空；最短外部延迟下错误响应会很快返回，因此不额外要求它的目的寄存器也提前复用。
- `--no-ooo` 和 `--no-speculation-coverage` 供小队列参数的纯功能回归或定位问题使用，只跳过对应计时覆盖，始终保留逐条提交对比；报告记录实际启用的检查。`--result-only` 同时跳过全部轨迹检查，不能用于完整 CPU 验收。

参考模型只覆盖本课要求的用户态 RV32IM，自然对齐访问；不模拟特权、异常处理、CSR、FENCE、ECALL/EBREAK 或周期性能。它不会把架构路径上非法指令、越界访问静默跳过。随机总线背压需要总线单元测试环境支持；官方仿真器延迟扫描只能覆盖不同响应延迟和其固定的从机行为，不能声称等价于任意独立通道背压测试。
