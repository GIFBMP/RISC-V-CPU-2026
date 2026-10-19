# 本地开发环境

本项目使用两条开发路径：Mac 原生 Verilator 用于日常仿真，课程 Dockerfile 构建的 Linux ARM64 容器用于仿真、Yosys 综合与 OpenSTA 时序分析。入口为仓库中的 `tools/dev`，不修改官方 Makefile、脚本或 RTL 清单。

## 1. 日常仿真

Mac 需要 Python 3、Apple Clang、Verilator 和 GNU Make（`gmake`）。在项目目录运行：

```sh
tools/dev mac build
tools/dev mac test Case=correctness_add_to_100
tools/dev mac test
tools/dev mac perf LATENCY=10
```

入口自动选择 `config.macos.mk`：禁用 AppImage，使用 `clang++`、`gmake`、6 个构建任务，产物保存在 `build/macos/`，测试周期上限为 100,000,000。后续参数原样传给 Make，命令行赋值优先于配置文件。

正式 CPU 已加入 `verilog/filelist.f`，以上命令现在编译和验证 V5 CPU，实施结果见 [V5 记录](experiments/v5.md)，历史基线见 [V4](experiments/v4.md)、[V3](experiments/v3.md)、[V2](experiments/v2.md) 与 [V1](experiments/v1.md)。独立环境自检仍保留，用于区分工具安装问题与 CPU 功能问题。原生 Mac 环境不提供课程综合结果，综合使用下述 Linux 路径。

## 2. Linux 课程工具链

需要 Docker CLI、Docker Buildx 和 Colima。先初始化官方测试子模块，再显式启动专用虚拟机、构建镜像：

```sh
git submodule update --init --recursive
tools/dev start
tools/dev build-image
```

`start` 使用独立的 `cpu2026` 配置：Apple Virtualization、ARM64、6 个 CPU、8 GiB 内存、40 GiB 数据磁盘，只向该虚拟机共享本项目目录供读写。入口不切换全局 Docker context，不转发 SSH agent，不修改 SSH 客户端配置。若移动项目目录，应停止后用新目录中的入口重新启动，以更新挂载位置。

镜像名为 `cpu2026:arm64`，由仓库原有 Dockerfile 构建，构建并行度为 6。首次构建需要下载并编译工具；`.dockerignore` 排除本地构建产物和 Git 元数据，保留官方脚本与测试程序。

```sh
tools/dev linux build
tools/dev linux test
tools/dev linux perf LATENCY=10
tools/dev linux synth MODE=diagnose
tools/dev linux synth MODE=opt
tools/dev stop
```

Linux 命令显式使用 `colima-cpu2026` context，将本项目挂载到容器 `/work`；任务结束即删除临时容器，构建产物留在 `build/linux/`。`config.linux.mk` 使用容器 PATH 中的课程工具及 `/opt/asap7/lib`，禁用 AppImage，采用与 Mac 相同的并行度和周期上限。命令不会自动启动 Colima；`stop` 只停止该课程配置，保留镜像与缓存。

官方提交入口有一项例外：不带 Make 目标或显式使用 `code` 时，会更新共享的项目根目录 `code`；任一平台的 `clean` 也会删除它。因此日常优先显式使用 `build/test/perf/synth`。Mac 和本地 ARM64 容器生成的可执行文件不能视为适用于课程 Linux x86-64 评测机的提交产物，最终提交按课程说明在目标环境重新构建。

容器内路径以 `/work` 为项目根。传入 `PROGRAM`、`WAVE`、`LOG` 或 `SIM` 时优先使用项目相对路径，不传 Mac 上项目之外的路径。Mac 和 Linux 的仿真二进制不能交叉使用。ARM64 路径用于本机开发，最终仍应在课程指定评测环境复核。

## 3. 独立环境自检

```sh
tools/dev smoke mac
tools/dev smoke linux
```

自检使用 `verification/environment/filelist.f` 中的独立顶层：读取镜像中的一个字，经过同步 SRAM 写入与读出，再通过退出 MMIO 返回。两个不同镜像分别期待 `0x12345678` 和 `0xA5C37E91`。先构建一次，再通过 `SIM` 复用产物运行两次，默认 `LATENCY=10`、上限 200 周期。

Mac 产物位于 `build/environment-macos/`，Linux 产物位于 `build/environment-linux/`；Linux 自检还运行综合，报告位于 `build/environment-linux/synth/opt/`。这个顶层不执行 RISC-V 指令，自检成功仅表明对应工具流程及基础 SRAM/AXI 往返可用，不代表 CPU 正确性或性能达标。

复用自检模拟器导出波形和运行日志：

```sh
tools/dev mac run SIM=build/environment-macos/sim \
  PROGRAM=verification/environment/pattern_a.data EXPECTED=305419896 \
  MAX_CYCLES=200 LATENCY=10 \
  WAVE=build/environment-macos/pattern_a.vcd \
  LOG=build/environment-macos/pattern_a.log
```

已验证该命令可生成有效 VCD 与 PASS 日志。VCD 可按课程 README 的指引选择波形查看器；本次未额外安装图形查看器。

## 4. 安装与验证记录

2026 年 10 月 13 日在 Apple M5、24 GiB 内存的 Mac 上配置。已安装：

| 组件 | 版本或配置 |
| --- | --- |
| Mac Verilator | 5.052 |
| GNU Make | 4.4.1，以 `gmake` 调用 |
| Apple Clang | 21.0.0 |
| Python | 3.14.7 |
| Docker CLI | 29.8.1 |
| Docker Buildx | 0.37.1 |
| Colima / Lima | 0.10.3 / 2.2.0 |
| RISC-V GCC / Binutils | 16.2.0 / 2.47 |
| Linux 镜像 | `cpu2026:arm64`，Ubuntu 24.04 / ARM64 |
| Linux Verilator | 5.020 |
| Yosys / OpenSTA | 0.63 / 3.1.0，使用课程 Dockerfile 固定提交 |
| 官方测试 | 固定提交 `29f980727f7d99a1842a58f34091c7579ba3fe85`，已初始化 |

已通过 Mac 原生环境自检：两个镜像在 `LATENCY=1` 时均为 11 周期，在 `LATENCY=10` 时均为 29 周期；两种延迟的 OJ 输入输出协议校验也通过。仅框架 SRAM 模型产生两条非致命的阻塞赋值风格警告。

已通过 RISC-V 交叉编译检查：将简单乘法与 MMIO 退出汇编链接为入口 0 的 RV32IM/ILP32 ELF，导出的二进制与字节文本镜像一致。该检查不执行 CPU，产物位于 `build/environment-toolchain/`。

已通过 Linux 环境自检：两个镜像在 `LATENCY=10` 时均为 29 周期，与 Mac 一致。Yosys、ABC、ASAP7 映射和 OpenSTA 流程全部完成；样例报告总面积为 61.332 μm²，其中 SRAM 为 21.499 μm²，2 ns 时钟目标下最差建立时间裕量为 +1.3925 ns。五个 ASAP7 单元库文件均通过镜像自带 SHA256 校验。这里的数值仅用于确认环境可用，不能用于评估未来 CPU。

已通过 `tools/dev stop` / `tools/dev start` 重启检查：镜像、项目挂载与 DNS 保留，复用 Linux 模拟器仍为 PASS。首次启动时发现虚拟机 `/etc/resolv.conf` 指向不存在的解析服务，已仅在该课程虚拟机内修复为 `223.5.5.5` 和 `1.1.1.1`，原链接保存在 `/etc/resolv.conf.lima-original`；Mac 网络设置未改动。重新创建虚拟机后若出现相同 DNS 错误，需重新检查该文件。

完整入口说明可用 `tools/dev help` 查看。虚拟机当前可手动启停，不用 Linux 工具时执行 `tools/dev stop` 即可释放其运行资源。

本地测试子模块下载地址使用 HTTPS，仅修改 Git 本地配置，保留课程 `.gitmodules`。Docker Buildx 通过用户目录下的插件链接注册；没有设置开机自动启动服务。

## 5. 编写自己的 RISC-V 测试

已安装的编译器名称虽然包含 `riscv64`，但支持 `rv32im/ilp32` 多库目标。编译课程指令集时明确指定：

```sh
riscv64-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles \
  -Wl,-Ttext=0x0,-e,_start,--build-id=none \
  -o program.elf program.S
riscv64-elf-objcopy -O binary program.elf program.bin
riscv64-elf-objdump -d program.elf
```

这组命令适合入口为 `_start`、自行处理初始化的简单裸机汇编。C 程序还需要合适的启动代码、链接脚本及运行时支持；不能直接假定普通宿主机 C 程序可运行。后续生成正式测试时避免额外扩展指令，并按框架要求转换为 `program.data` 字节镜像。
