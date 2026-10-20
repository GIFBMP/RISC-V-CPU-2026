# 文档索引与版本演进

**当前生产版本为 V10：Booth/CSA 乘法与前导零除法。** 完整结构见 [arch.md](arch.md)，改动和验证范围见 [V10 实施记录](experiments/v10.md)，精确测量与源码摘要见 [V10 验收 JSON](experiments/v10-results.json)。

## 阅读入口

| 内容 | 文档 |
| --- | --- |
| 当前 CPU 结构、数据流、时序、参数与验证 | [V10 架构](arch.md) |
| Mac 仿真、Linux 综合、官方构建与本地加速 | [本地开发环境](local-environment.md) |
| AXI4-Lite 接口和握手 | [总线接口](axi4-lite.md) |
| 同步 SRAM 接口与配置 | [SRAM](sram.md) |

## 正式版本

每个版本的说明与主结果分别使用 `experiments/vN.md`、`experiments/vN-results.json`。版本号按已采用的实现演进递增，设计方案、候选和未采用实验归属对应版本。

| 版本 | 主要变化 | 实施记录 | 主结果 |
| --- | --- | --- | --- |
| V1 | RV32IM 单发射乱序 CPU，功能与验证基线 | [V1](experiments/v1.md) | [JSON](experiments/v1-results.json) |
| V2 | 解耦取指、分支预测与时序优化 | [V2](experiments/v2.md) | [JSON](experiments/v2-results.json) |
| V3 | 写回 Cache、并行写回与关键路径收敛 | [V3](experiments/v3.md) | [JSON](experiments/v3-results.json) |
| V4 | 访存吞吐、Store 转发与提前取指 | [V4](experiments/v4.md) | [JSON](experiments/v4-results.json) |
| V5 | 选择性分支恢复与低延迟完成通路 | [V5](experiments/v5.md) | [JSON](experiments/v5-results.json) |
| V6 | 成对取指与非对称双发射 | [V6](experiments/v6.md) | [JSON](experiments/v6-results.json) |
| V7 | 两条可共享整数运算的执行通路、解耦访存 | [V7](experiments/v7.md) | [JSON](experiments/v7-results.json) |
| V8 | 保持 IPC 与流水拍数，完成 500 MHz 时序优化 | [V8](experiments/v8.md) | [JSON](experiments/v8-results.json) |
| V9 | 乘法提前结束、商余数复用，转发与 MQ 时序调整 | [V9](experiments/v9.md) | [JSON](experiments/v9-results.json) |
| **V10（当前）** | **两拍 Booth/CSA 乘法、除法前导零跳过，保留商余复用** | [V10](experiments/v10.md) | [JSON](experiments/v10-results.json) |

“正式版本”表示已采用的实现；各阶段是否达到当时的课程性能目标，以对应验收记录为准。V7 及之后的六项 IPC 几何平均均为 **1.1002013686**。V8、V9、V10 的频率分别为 **504.185130、501.469148、506.429278 MHz**，总面积分别为 **32,287.898、33,800.573、34,170.191 μm²**，均为各自源码的课程 STA/面积结果。

## V7 之后的旧名对应

| 旧名称 / 文件前缀 | 统一编号 | 现在的文件 |
| --- | --- | --- |
| V7-500MHz、S23；`v7-500mhz-*` | **V8** | `v8.md`、`v8-results.json`、`v8-plan.md`、`v8-analysis.json`、`v8-experiments.json`、`v8-s1.patch`、`v8-s2.patch` |
| 提前结束/商余复用；`v7-mdu-speed*` | **V9** | `v9.md`、`v9-results.json` |
| Booth/CSA 与前导零；`v7-mdu-slides*` | **V10** | `v10.md`、`v10-results.json` |
| 加法器对照；`v7-adder-reference*` | **V10 的未采用实验** | `v10-adder-reference.md`、`v10-adder-reference-results.json`、`v10-adder-reference/` |

原 `v7.md` 中的“500 MHz 优化验收”已拆到 [v8.md](experiments/v8.md)。V7 现在只记录首次双通路发布。S1、S2、S23 等是 V8 内部的候选编号，不是独立发布版本。加法器三个候选未通过 500 MHz，因此仍归档在 V10，没有分配 V11。

## 设计、候选与补充测量

- V6 工具配置复测：[上游工具变更](experiments/v6-upstream-302f0cf-results.json)、[统一 ABC 配置](experiments/v6-abc-config-results.json)。
- V7 设计阶段：[结构方案](experiments/v7-design.md)、[原型结果](experiments/v7-design-results.json)、[原型补丁](experiments/v7-prototype.patch)。
- V8 时序优化：[实施前方案](experiments/v8-plan.md)、[关键路径分析](experiments/v8-analysis.json)、[28 个候选](experiments/v8-experiments.json)、[S1 补丁](experiments/v8-s1.patch)、[S2 补丁](experiments/v8-s2.patch)。
- V10 加法器对照：[结论与范围](experiments/v10-adder-reference.md)、[实验 JSON](experiments/v10-adder-reference-results.json)。三份未采用补丁从实验说明中进入。

## 版本名与复现口径

本次整理只调整文档组织、版本标签和文档引用，不代表新一轮硬件修改或重新测量。各版本的源码摘要、提交、测试结果、约束、运行时间以及原始日志目录保留原记录。复现历史版本时，先使用与其验收摘要匹配的独立副本；在当前工作树执行测试得到的是 V10 的结果。

`verification/runners/run_v7_linux.py`、`--target v7-500` 和 `--recovery-mode v7` 是沿用的工具接口名；V8～V10 的 500 MHz 验收仍使用这些接口。它们与文档版本号分开管理。`build/v7-500/`、`build/v7-mdu-speed/`、`build/v7-mdu-slides/` 等记录的是原始产物位置，查证时仍按原路径读取。

重编号的 JSON 以顶层 `version` 标识 V8、V9 或 V10，以 `documentation_versioning.role` 区分正式验收、分析与失败实验。`documentation_versioning.original_document` 保存迁移前文件名、摘要及原版本字段。报告间的文档引用已更新路径和 SHA-256，并用 `original_path` / `original_sha256` 保存原引用；日志和 RTL 的摘要没有变更。历史 `build/` 汇总辅助脚本仍保留原文作为存证，重新汇总旧文档引用时需按上表映射。
