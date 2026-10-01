# P3a 证据

核验日期：2026-10-01。目标：T-09 的纯策略与库 API 子集。

## 自动化核验

- `moon check --target native`：通过。
- `moon test --target native`：43 项通过。
- 固定时钟测试覆盖 newest 按发布时间选择、成熟期严格小于边界、缺失发布时间的 `incomplete_release_times` 错误。

## 已交付行为

- 新增 `ReleaseOptions`，以毫秒时间戳固定一次执行的时钟，并复制成熟期豁免选择器。
- 新增 `check_manifest_timed`、`check_manifest_timed_filtered` 和 `check_manifests_timed_filtered`，与原有非时间 API 共用检查计划和写回模型。
- `newest` 按发布时间选择更高版本；同一发布时间按 SemVer 和版本字符串稳定决胜。
- `next` 在没有已核验标签时复用 newest 规则，并产生 `next_tag_unavailable` 警告。
- 成熟期使用严格的 `published_at < now - days * 86400000`，缺失、未来或未成熟候选产生 `unknown_release_time` 并排除；豁免只绕过成熟期门槛。
- CLI 接受 `newest`、`next`、`--maturity-period`（裸参数为 7）和 `--maturity-period-exclude`，配置文件支持对应字段。

在线 Mooncakes 详情时间字段、`--timediff` 的 JSON/文本展示、基于真实发布时间的时间排序和 TUI 仍未完成，不在本证据中宣称通过。
