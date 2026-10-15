# 执行模块单元验证

在仓库根目录执行 `verification/unit/run_execute.sh`。需要 Icarus Verilog（`iverilog`、`vvp`），产物与编译日志位于 `build/unit/execute/`。可用 `CPU2026_UNIT_BUILD` 指定其他输出目录；测试平台不加入 CPU 的 `verilog/filelist.f`。

- `execute_decode_alu_tb.sv`：4035 次译码检查，包括全部 R 类 `funct7/funct3` 组合、移位立即数保留位、访存/分支/JALR 合法性、未支持操作码、随机立即数及边界；6628 次 ALU 检查，包括有符号比较、溢出和移位量截断。
- `execute_muldiv_tb.sv`：2257 次 M 扩展运算，覆盖 9 个边界值的两两组合、200 对固定种子随机输入、全部 8 种操作、除零和有符号溢出；每次运算检查完成背压、输入锁存及忙时禁止新请求。另检查 9 种 flush 场景和 reset 取消。

验证平台中的乘、除、余运算仅用于数学参考；可综合 `muldiv_unit` 使用移位累加和恢复除法。

## 接口约定

`decoder` 的 `rs1/rs2/rd/funct3` 始终输出指令对应字段。`writes_rd` 表示指令具有写回语义，`rd=0` 仍可能置 1，实际写 x0 应由寄存器堆或核心屏蔽。非法指令输出 `op=31`、`illegal=1`，关闭全部操作数/写回标志，并清零立即数。FENCE 和 SYSTEM/CSR 类指令按本版本约定视为非法。

分支的 `use_rs1/use_rs2=1`、`use_imm=0`，比较两个寄存器；PC 位移从 `immediate` 读取。移位立即数指令的 `immediate` 是零扩展的 5 位移位量。LOAD/STORE/JALR 的 `immediate` 是符号扩展的 12 位偏移。

`alu` 支持 op 0..11，其他编码输出 0；分支判断、访存地址和跳转链接值由核心处理。

`muldiv_unit` 在 `req_valid && req_ready` 的上升沿锁存标准 M 扩展 `funct3` 和两个操作数。正常运算在之后 32 次迭代完成；除零直接生成规定结果。结果通过 `result_valid/result_ready` 握手保持，尚未消费时不接受新请求，也不支持消费结果同拍接受下一请求。`reset`、`flush` 高有效、同步取消所有状态，并在有效时屏蔽两侧握手。该模块不带 ROB 标签。

## 已执行检查

单元测试全部通过。三个 RTL 模块分别通过 Verilator 5.052 `--lint-only -Wall`，无警告。课程容器的 Yosys SystemVerilog 读取、层次检查、过程转换、优化和 `check -assert` 通过；进一步确认不存在 `$mul`、`$div`、`$mod` 或锁存器。完整 CPU 的标准单元映射、时序和程序回归应由集成流程完成。
