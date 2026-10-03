# moon-taze：规格驱动开发文档

状态：P1a 只读闭环与 P1b 写回实现已核验；P2 的 T-06 工作区/递归/配置、T-07 版本化 TTL 缓存/有界重试与 Retry-After、T-08 JSON/CI 基础契约及文本排序/分组、T-12 非交互 verify 已接入。P3a 已接入固定时钟、发布时间选择、成熟期策略、Mooncakes 在线详情、timediff/time sort、纯 resolve、Selection 访问和 check/apply 生命周期回调；P3b 已接入行式 TUI、TTY 校验、依赖/候选选择、确认和取消。完整日志级别和平台验收仍待后续阶段。符号链接实机写入拒绝待权限环境复验。核验日期：2026-10-03。文档版本：0.5。证据见 [P1a](evidence-p1a.md)、[P1b](evidence-p1b.md)、[P2 首轮](evidence-p2.md)、[P3a](evidence-p3.md)、[P3b](evidence-p3b.md)。

本项目将 taze 的依赖检查与更新体验适配到 MoonBit：读取项目已有依赖，从 Mooncakes 查询版本，生成更新计划，由用户预览或选择后写回。这里的 SDD 指 **Specification-Driven Development（规格驱动开发）**；技术设计是其中一部分。

已交付 P0/P1a 基础及 P1b 单模块显式写回：私有检查快照、绑定计划的选择、版本区间补丁、锁与权限保护、原子替换、取消及部分失败报告。P2 已补充工作区、递归、缓存、JSON/CI 基础和非交互 verify；P3a 已接入固定时钟、发布时间详情、成熟期过滤、newest/next 诊断、timediff/time sort、纯 resolve 和统一生命周期回调；P3b 的 `-I/--interactive` 复用同一计划和 Selection，在确认后才写回，JSON 模式自动跳过交互。

## 阅读顺序

| 文档 | 读者与用途 |
| --- | --- |
| [需求规格](requirements.md) | 确认用户场景、行为、范围及 taze 功能映射 |
| [技术设计](design.md) | 实现 CLI、解析、版本选择、Registry、写回和库接口 |
| [验收规格](acceptance.md) | 将 Given/When/Then 场景转为确定性测试，查阅需求追踪矩阵 |
| [推进路径与实施任务](tasks.md#roadmap) | 阅读需求优先级、七个验收里程碑、风险与首轮执行切片，再按任务实施 |

确定的推进顺序为：**Native 基础验证 → 只读检查 → 可靠写回 → 仓库/CI/更新后验证 → 完整策略与库 API → TUI → 三平台发行**。P1b 常规 Windows x86_64 Native 验收已有证据；尚需有权限环境中的文件符号链接实测。下一功能阶段为 P2，三平台最终支持仍未声明。

## 已确认的决策

| 项目 | 决策 |
| --- | --- |
| 目标用户 | 维护 MoonBit 单模块项目、多模块仓库及 CI 的开发者 |
| 移植程度 | 完整规划适用于 Mooncakes 的 taze 能力，分阶段交付 |
| 查找新依赖的含义 | 检查已有依赖的新版本；不提供关键词搜索或新增模块 |
| 交付方式 | `moon-taze` Native CLI；Windows、Linux、macOS 是最终验收目标 |
| 清单 | 只更新 `moon.mod`；读取 `moon.work`；不迁移旧 JSON 格式 |
| 默认策略 | 保留 taze 模式习惯，裸版本默认参与兼容范围检查 |
| 写回 | 默认只读，显式 `--write` 或交互确认后应用；仅改版本文本 |
| 版本含义 | 显示的是清单声明版本，不冒充 MoonBit 依赖求解后的实际安装版本 |
| 生态边界 | 不更新 npm、JSR、Node.js、GitHub Actions、全局软件或 MoonBit 工具链 |
| 本次范围 | P1b 单模块非交互写回；多文件失败边界通过内部引擎验收，工作区/递归 CLI 延后 |

## SDD 工作流程

1. 从需求 ID 开始讨论行为；改变约定时先更新需求、设计和相关验收场景。
2. 按任务定义 MoonBit API 契约及黑盒测试；类型和接口保持 MoonBit 风格，不逐行翻译 TypeScript。
3. 实现对应功能，先通过离线验收，再做独立的集成验证。
4. 检查实现、帮助文本、示例、JSON 契约和文档是否一致；更新追踪矩阵及任务状态。
5. 使用 `moon check --target native`、`moon test --target native` 验证实现；最后依次执行 `moon info`、`moon fmt`，审查生成的 `.mbti` 差异。实施阶段会将模块默认目标改为 Native。

需求使用 `REQ-*`、非功能要求使用 `NFR-*`；设计锚点使用 `D-*`，验收场景使用 `AC-*`，任务使用 `T-*`。追踪矩阵的唯一维护位置是 [acceptance.md](acceptance.md#traceability)。新增需求必须同时关联设计、场景和任务。

只有声明的契约还没有实现时，不要求运行期测试通过；不得用更新快照掩盖未实现行为。稳定结果用断言，结构化诊断使用 `Debug`/`debug_inspect`。后续自行编写的自动化使用 `.mbtx`。

## 资料优先级与证据

1. 本文档集定义 moon-taze 的目标行为，已确认的产品决策优先。
2. [现有 taze 分析文档](../../taze/docs/README.md)用于建立功能地图；上游 [源码](../../taze/src/cli.ts)与[测试](../../taze/test/versions.test.ts)用于确认实际行为。
3. MoonBit 官方资料、安装的工具链和真实 Mooncakes 响应用于确认生态能力；核验记录及差异见 [D-12](design.md#d-12)。

本地参考 taze 的 `package.json` 版本为 **21.1.0**；本轮实测 MoonBit 工具链为 **0.1.20260920（914d7da）**。不将本地源码副本声称为未经核验的上游提交。外部服务和 latest 文档会变化，真实响应版本号仅是核验样本，不用于稳定测试断言。

## 完成与变更规则

- 文档基线完整意味着所有适用能力都有明确归属、行为、验收与实施阶段，不意味着功能已完成。
- 三平台运行、TLS、终端模式和文件替换能力必须通过阶段验证；尚未运行验证的能力不能标记为“已支持”。
- 不兼容的 CLI、JSON 或 API 变更必须同步修改契约版本及迁移说明。版本选择策略变化即使接口不变，也必须修改对应验收用例。
- 保留 `taze/` 作为参考，不在文档任务中改写其源码、分析文档或许可文件。后续直接借用上游代码时保留所需 MIT 声明。

2026-09-23 文档与实现检查：本地链接/显式锚点、JSON 示例、代码围栏和空白检查通过；24 项需求均进入追踪矩阵，58 个验收编号唯一，14 个实施任务均有追踪关联。P0/P1a 运行证据见 [evidence-p1a.md](evidence-p1a.md)，其余验收仍按阶段待执行。
