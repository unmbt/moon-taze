# P0 / P1a 核验记录

核验日期：2026-09-23。工具链：`moon 0.1.20260920 (914d7da 2026-09-20)`；目标：Windows x86_64 Native。

## T-01 Native 探针

命令：`moon run --target native tools/native_probe.mbtx`

结果：

- `fs_read=probe`，临时文件读回成功；`atomic_rename=true`。
- `https=HTTP 200`，Mooncakes HTTPS 请求成功并使用系统证书验证。
- `process=exit=0`，通过参数数组启动 `moon version`，未拼接 shell 命令。
- `terminal=stdin-available=true`，标准输入 FD 能力可用。

探针通过 `@fs.tmpdir` 创建隔离目录，只读/写临时目录；未读取或改写开发者项目文件。探针依赖 `moonbitlang/async@0.21.3`。

2026-09-24 补充：这里的 `atomic_rename=true` 仅验证重命名到尚不存在的路径，不作为覆盖已有清单的证据；已有文件替换与权限保留由 [P1b 验收](evidence-p1b.md) 单独验证。

## T-02 / T-03 / T-04

命令：`moon test --target native`

结果：17 个测试通过。覆盖 SemVer 预发布数字比较（含超长数字标识）、build metadata、0.x 边界、latest cap、非法前导零、UTF-8 字节 span、BOM/注释/伪 import/重复声明、表达式内 import、旧 JSON 与未闭合结构诊断，以及 FakeRegistry 请求去重、元数据校验、过滤前置与候选过滤、no-candidate 和错误聚合。

## T-05 只读 CLI

命令：

- `moon run --target native cmd/moon-taze -- --help`
- 直接运行 Native 产物并传入未知选项，退出码为 2；`--write`、工作区、递归、JSON、时间模式等阶段性选项也返回 2。
- `--include/--exclude` 在 Registry 查询前应用；名称过滤显示 `skipped`，非法选择器退出 2。
- 临时 `moon.mod` fixture 上执行 `major -C <fixture>`，真实 Mooncakes 输出 `moonbitlang/async 0.21.3 -> 0.22.1 (major)`；响应中的 `yanked_reason: null` 已按 JSON null 正确解码。

只读冒烟未产生项目写入。`--write`、工作区、递归、JSON、缓存、时间策略和 TUI 仍明确返回不支持，写回保留到 P1b。

## 已知限制

- 编译器仍报告若干冗余 modifier、隐式 trait promotion 和保留字 warning；不影响 Native check/test，但后续应按 MoonBit 工具链演进清理。
- 当前 CLI 只实现串行概览查询；P1a 仅开放 default/minor/patch/major/latest/stable，`newest/next`、P2 的缓存/重试/并发和 P3 的时间策略尚未开放。
