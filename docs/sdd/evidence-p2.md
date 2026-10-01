# P2 证据

核验日期：2026-10-01。目标：T-06～T-08 与 T-12 非交互部分。

## 自动化核验

- `moon check --target native`：通过。
- `moon test --target native`：40 项通过。
- `moon run --target native tools/cli_smoke.mbtx`：7 项进程级退出码场景通过。
- 工作区测试覆盖 `moon.work` 注释、显式成员、成员间 `local_workspace` 跳过及跨清单 Registry 请求去重。
- CLI 测试覆盖 `--recursive`、`moon-taze.json` 的 include/all 配置与命令行 include 覆盖，以及 `--json` 输出可解析为单个 JSON 对象。
- CLI 测试覆盖瞬时 HTTP 失败的有界重试、同一进程缓存命中与 `--force` 绕过。
- `--write --verify` 测试覆盖验证结果进入 JSON、验证失败返回 2，以及 `moon` 子进程输出不污染 JSON stdout。

## 已交付行为

- 工作区根按 `moon.work` 显式成员建立完整模块名集合；成员依赖不访问 Registry。
- `check_manifests_filtered` 在一个计划中合并多个清单并共享请求结果。
- `--recursive` 使用有界串行目录遍历，跳过 `_build`、`.git` 和 `.mooncakes` 子树，并按路径去重。
- `moon-taze.json` 只加载调用范围根的一份，支持 `mode`、`recursive`、`all`、`include`、`exclude`；CLI 数组和标量优先。
- `--json` 输出 schemaVersion=1 的项目、依赖状态、诊断和应用文件结构；已识别的 CLI 错误也返回固定 JSON 外形。
- Registry 的超时、408、429、5xx 和明确的请求超时可重试；元数据 schema 错误不重试。生产 CLI 使用有界指数退避，测试可用 `--no-retry`。
- 进程内缓存按模块共享结果；`--force` 忽略旧条目并刷新，仍保留本次检查计划内的请求去重。
- `--verify` 仅在应用成功且实际写入文件后运行：工作区根只运行一次，普通范围按写入文件父目录排序去重；任何验证失败返回 2。

持久化版本化 TTL 缓存、全局限流、Retry-After、完整重复键校验和三平台运行证据仍属于后续 P2/P4 工作，未在本证据中宣称完成。
