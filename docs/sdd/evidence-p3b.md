# P3b 证据

核验日期：2026-10-03。目标：T-10 行式交互终端子集。

## 已交付行为

- `-I/--interactive` 在参数解析后校验标准输入 TTY；非 TTY 返回稳定的 `interactive_requires_tty` 错误，且在查询 Registry 前退出。
- 交互界面列出所有可更新依赖，支持用编号或 `a` 选择；每个依赖可按编号或版本字符串切换候选。
- 最终确认只接受 `y/yes`（大小写不敏感的常用形式）；`q`、EOF、空确认和其他输入都会取消，取消不会写入。
- 交互选择构造正式 `Selection`，继续由统一 `apply` 校验计划身份、候选归属、锁和原子写回。
- `--json` 清除交互提示，保持 JSON stdout 单行契约；显式 `--write` 仍按非交互推荐选择执行。

## 自动化核验

- `moon check --target native`：通过。
- `moon test --target native`：50 项通过。
- 现有 CLI 回归继续覆盖 `--interactive` 非 TTY 错误路径、无网络查询副作用和写入保护。

滚动/resize、视觉宽度以及 Linux/macOS 终端实测归入 P4。
