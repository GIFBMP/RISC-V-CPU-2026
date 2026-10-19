# 工具链环境自检

这里的 `student_top.sv` **不是 CPU，不执行 RISC-V 指令，也不能用于课程功能或性能验收**。它只检查 SystemVerilog 编译、框架 AXI4-Lite 从机、同步 SRAM 仿真与综合接口能否串通。

流程：从 AXI 地址 `0` 读取一个 32 位数，写入框架提供的 `16 × 32` 位 `sram_fakeram`，同步读回，然后完整写入退出 MMIO `0x80000000`，等待 B 响应握手。AW 与 W 分别记录握手，可先后或同时完成。SRAM 内容不依赖初始值。

| 输入镜像 | 小端字节 | 预期退出值 |
| --- | --- | --- |
| `pattern_a.data` | `78 56 34 12` | `0x12345678` / `305419896` |
| `pattern_b.data` | `91 7e c3 a5` | `0xA5C37E91` / `2781052561` |

两个 `.data` 文件是数据镜像，不是指令程序。独立的 `filelist.f` 只列本例，完全不影响正式 CPU 的 `verilog/filelist.f`。框架 SRAM 源码由课程脚本自动添加。

## 原生 macOS 手动运行

在项目根目录、安装好 Verilator 和 GNU Make 后执行：

```sh
gmake build APPIMAGE= CXX=clang++ BUILD_MAKE=gmake \
  FILELIST=verification/environment/filelist.f BUILD=build/environment-macos

gmake run APPIMAGE= SIM=build/environment-macos/sim \
  PROGRAM=verification/environment/pattern_a.data EXPECTED=0x12345678 \
  MAX_CYCLES=200 LATENCY=10

gmake run APPIMAGE= SIM=build/environment-macos/sim \
  PROGRAM=verification/environment/pattern_b.data EXPECTED=0xA5C37E91 \
  MAX_CYCLES=200 LATENCY=10
```

`SIM` 使两个运行命令复用刚编译的环境自检程序。可将 `LATENCY` 改为 `1` 或 `31` 检查等待响应的行为。需要波形时添加 `WAVE=build/environment-macos/trace.vcd`。

## Linux 综合验收

在已配置课程 Yosys、ABC、OpenSTA 和 ASAP7 库的 Linux 环境中，从项目根目录执行：

```sh
make synth APPIMAGE= FILELIST=verification/environment/filelist.f \
  SYNTH_OUT=build/environment-linux/synth MODE=opt
```

若使用 AppImage，按环境配置设置 `APPIMAGE`，不要传空值。综合报告应包含 SRAM 实例和非零 SRAM 面积。此样例的面积与频率只能用于检查工具链，不代表未来 CPU 的结果。

## ABC 参数与报告核对

项目的三个 Make 配置入口都包含 [config.synth.mk](../../config.synth.mk)，默认使用上游示例的 `BUFx2_ASAP7_75t_R / 1 fF` 映射参数。`tools/dev smoke linux` 自动沿用该配置。需要官方默认对照时，覆盖参数并使用独立输出目录：

```sh
tools/dev linux synth FILELIST=verification/environment/filelist.f \
  SYNTH_OUT=build/environment-linux/synth-upstream MODE=opt \
  ABC_DRIVING_CELL=INVx1_ASAP7_75t_R ABC_LOAD_FF=5.0
```

核对 `abc.constr` 与 `report.json` 的 `abc_constraints`，以及实际综合命令包含 `-constr`。两种映射配置的 `timing.output_load_ff` 都应为 5.0，时钟与 I/O 验收约束保持一致。默认值和命令行覆盖已在三个 Make 配置入口验证，项目配置和官方默认对照均已通过独立样例综合；Mac/Linux 的两个输入样例均为 29 周期。
