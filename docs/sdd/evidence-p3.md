# P3a 证据

核验日期：2026-10-03。目标：T-09 与 T-11 的纯策略、库 API 和生命周期子集。

## 自动化核验

- `moon check --target native`：通过。
- `moon test --target native`：50 项通过。
- 固定时钟测试覆盖 newest 按发布时间选择、成熟期严格小于边界、缺失发布时间的 `incomplete_release_times` 错误。
- `api_p3_test.mbt` 通过黑盒方式覆盖纯 `resolve`、固定回调顺序、`Selection::items()` 的公开访问边界和 `before_apply` 否决；回调否决在首个写入前返回 `callback_denied`。

## 已交付行为

- 新增 `ReleaseOptions`，以毫秒时间戳固定一次执行的时钟，并复制成熟期豁免选择器。
- 新增 `check_manifest_timed`、`check_manifest_timed_filtered` 和 `check_manifests_timed_filtered`，与原有非时间 API 共用检查计划和写回模型。
- `newest` 按发布时间选择更高版本；同一发布时间按 SemVer 和版本字符串稳定决胜。
- `next` 在没有已核验标签时复用 newest 规则，并产生 `next_tag_unavailable` 警告。
- 成熟期使用严格的 `published_at < now - days * 86400000`，缺失、未来或未成熟候选产生 `unknown_release_time` 并排除；豁免只绕过成熟期门槛。
- CLI 接受 `newest`、`next`、`--maturity-period`（裸参数为 7）和 `--maturity-period-exclude`，配置文件支持对应字段。
- Mooncakes 版本详情使用 `/{module}@{version}` 端点，严格校验请求模块/版本，并把 `metadata.created_at` 解析为 UTC 毫秒；缺失时间保留为未知，HTTP、JSON、版本不匹配分别报告错误。
- `--timediff` 显示目标减当前的时间差；JSON 固定输出 `currentPublishedAt`、`targetPublishedAt` 和 `timeDiffSeconds`，缺少任一时间为 `null` 并附 warning。
- `--sort time-asc/time-desc` 使用目标真实发布时间，未知时间稳定排在已知时间之后；详情请求在一次 CLI 执行内去重，并复用于成熟期、策略选择、展示和排序。
- CLI 白盒回归覆盖 `--timediff` 文本/JSON、详情请求去重、未知时间 warning 和真实发布时间排序。

## T-11 生命周期契约

- `Policy` 只包含版本策略和成熟期规则；`resolve` 只校验注入的 `ModuleMetadata` 并计算 `DependencyChange`，不执行 IO。
- `Callbacks` 的 check 事件按 `after_discovery`、`dependency_resolved` 顺序串行派发；apply 事件按 `before_apply`、`file_applied`、`after_run` 派发。
- 回调返回空字符串表示接受；非空消息在写前形成 `callback_denied` 并阻止写入，在写后形成 `callback_failed`，报告保留已写文件及部分状态。
- `Selection::items()` 返回副本；计划身份仍由内部引用绑定，跨计划或候选外目标继续在应用前拒绝。

TUI 仍未完成；交互终端及三平台终端验收继续属于 P3b/P4。
