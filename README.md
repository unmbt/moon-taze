# unmbt/moon-taze

检查 MoonBit 项目已有依赖的新版本，并按需更新 `moon.mod`。当前为 **P3a 实验版**：已支持显式 `moon.work` 成员、递归发现、静态配置、跨模块本地依赖识别、JSON v1、Mooncakes 版本详情时间、固定时钟发布时间策略、timediff/time sort 和正式库生命周期回调；Windows x86_64 已验证常规写回，Linux/macOS 尚未运行验收。

## 使用

```sh
moon run --target native cmd/main -- --help
moon run --target native cmd/main -- patch -C "path/to/project"
moon run --target native cmd/main -- patch -C "path/to/project" --write
```

`moon build --target native` 生成独立 CLI；Windows 默认产物为 `_build/native/debug/build/cmd/main/main.exe`。

- 模式：`default`、`minor`、`patch`、`major`、`latest`、`stable`、`newest`、`next`，沿用 [版本策略](docs/sdd/design.md#d-05)。显示的是清单声明版本。
- `-C/--cwd` 指定起点，向上寻找单模块清单；`-a/--all` 显示无更新和跳过的依赖。
- `-n/--include`、`-x/--exclude` 过滤已有依赖；排除优先。`-l/--include-locked` 保留兼容用法，裸版本默认已参与检查。
- `-w/--write` 应用所有推荐更新；不传时仅预览。`-r/--recursive` 扫描当前范围内的 `moon.mod`；工作区根目录按 `moon.work` 显式成员检查。`moon-taze.json` 可提供 `mode`、`recursive`、`all`、`include` 和 `exclude`，命令行值优先。不运行安装命令或 `moon fmt`，不会自动升级工具链。

缓存支持用户缓存目录中的版本化 `cache-v1.json`，TTL 为 30 分钟；`--force` 会绕过并刷新，损坏或过期缓存会回退到联网查询。瞬时 Registry 错误支持有界重试、指数退避和可解析的 `Retry-After`。文本输出支持 `--silent`、`--group/--no-group` 和 `--sort`；`time-asc/time-desc` 使用版本详情的真实发布时间。P3 新增 `newest`、`next`、`--maturity-period`、`--maturity-period-exclude` 和 `--timediff`，通过 Mooncakes 详情的 UTC 发布时间按固定时钟选择候选并输出 JSON 时间字段；缺少可靠发布时间时会返回明确诊断。`-w --verify` 会在实际写入后按模块运行 `moon check`，失败返回 2 并保留应用报告。TUI 仍未开放。旧 `moon.mod.json` 不自动迁移；工作区成员依赖标记为 `local_workspace`，不会访问 Registry。

## 写回与恢复

只替换版本区间，保留 BOM、LF/CRLF、注释、未知字段和末尾换行状态。无更新时不重写文件，mtime 不变。解析或查询存在错误时，整个计划不能应用。

写入前取得旁置 `moon.mod.moon-taze.lock`，复核检查时的原始字节，然后准备同目录临时文件、保留权限、同步并原子替换。符号链接清单禁止写入。Windows 使用文件重命名系统原语，不支持时直接失败；没有删除原文件或截断写入的降级路径。

正常清理根据文件身份只处理本次取得的资源。锁冲突不等待、不按时间抢锁；残留锁应在确认原进程已结束后手动清除。未知临时文件不会被自动删除。

成功退出 0；执行失败或部分提交退出 2。提交前取消报告 `cancelled`，退出 0；已有提交后取消报告 `partial`，退出 2。报告区分实际写入、失败和未尝试文件；已写入内容不自动回滚。只承诺单文件替换完整性，不承诺跨文件事务或外部编辑器的 compare-and-swap。

## 实验性库接口

根包提供 `Policy`、纯 `resolve`、`Callbacks`、`Selection`、`ApplyReport` 和 `apply(plan, selection, callbacks?)`。`plan.recommended_selection()` 选择全部推荐更新；`plan.selection([(manifest, dependency, target)])` 选择具体依赖，空数组表示不选择。`Selection::items()` 返回副本，路径使用该计划结果中的 `dependency.manifest`。check 回调按 `after_discovery`、`dependency_resolved` 顺序执行；apply 回调按 `before_apply`、`file_applied`、`after_run` 执行。回调返回空字符串表示接受，返回非空消息会生成 `callback_failed` 或 `callback_denied` 诊断，并保留已发生的写入报告。

P1a 调用方需将 `plan.changes`、`plan.diagnostics`、`plan.has_errors` 改为 `plan.changes()`、`plan.diagnostics()`、`plan.has_errors()`。数组访问器返回副本；计划保存私有源码快照，选择绑定其所属计划，不能用 JSON 重放。`check_manifest` 会重新解析源码，因此无法通过修改 `Manifest.dependencies` 丢弃解析错误。完整可替换 Services 端口和 TUI 仍留待后续阶段；当前正式回调契约不暴露内部写入类型。

`CheckPlan` 不再直接派生 `Eq`/`Debug`；需要比较或调试时使用访问器返回的公开结果，避免暴露私有源码快照。

## 验证

```sh
moon check --target native
moon test --target native
moon build --target native
moon run --target native tools/cli_smoke.mbtx
```

常规测试使用 FakeRegistry、可注入文件操作和隔离临时目录，不请求真实 Mooncakes、不改仓库清单。符号链接实机测试需要相应系统权限，单独运行：

```sh
moon test --target native write_native_wbtest.mbt --filter "Native rejects symlink*" --include-skipped
```

当前 Windows 账户缺少创建文件符号链接权限，该实机场景尚未通过。测试结果、ASan 复现命令与平台限制见 [P1b 证据](docs/sdd/evidence-p1b.md)；后续路线见 [实施任务](docs/sdd/tasks.md#roadmap)。
