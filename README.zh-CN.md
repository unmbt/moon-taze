# `unmbt/moon-taze`

> 面向 **MoonBit**（`moon.mod` / `moon.work`）与 **GitHub Actions**（`.github/workflows/*.yml`、`action.yml`）的可靠、无损依赖检查与更新工具，灵感源自 [taze](https://github.com/antfu-collective/taze)。

[English](README.md) | **简体中文**

---

## 核心特性

- **一站式检查 MoonBit 与 GitHub Actions** — 自动查询 [mooncakes.io](https://mooncakes.io) 中的 `moon.mod` 依赖以及 GitHub API 中的 `.github/workflows/*.{yml,yaml}` / `action.{yml,yaml}` 的 `uses:` 引用。
- **字节级无损写回** — `moon.mod` 委托给 [`unmbt/moon-manifest`](https://github.com/unmbt/moon-manifest)（官方 `moon_config` AST）进行精确区间替换；GitHub Actions 使用零依赖无损 YAML 扫描器。完整保留 BOM、CRLF/LF、注释、引号、缩进与无关字段。
- **原子安全写入** — 旁置排他锁、写前快照字节复核、权限/ACL 保留与同目录原子替换（无删除原文件或原地截断的降级路径）。
- **完整更新策略** — 支持 `default`、`minor`、`patch`、`major`、`latest`、`stable`、`newest`、`next`，以及 `--maturity-period` 成熟期冷却、`--timediff` 发布时间差、发布年龄展示与 `--github-actions-style auto | tag | sha`（支持 SHA Pin 安全加固）。
- **工作区与 CI 友好** — 识别 `moon.work` 本地成员依赖，支持 `-r/--recursive` 递归发现、`moon-taze.json` 静态配置、30 分钟 TTL 持久化缓存（`cache-v2.json`）、`--json` 机器可读输出、`--fail-on-outdated` 以及 `-w --verify`（写入后自动执行 `moon check`）。
- **原生适配 MoonBit `v1.0.0-rc1`** — 基于 `moonbitlang/core/async` 与 [`unmbt/cac`](https://github.com/unmbt/cac) 构建，精简干净、零不可用第三方依赖。

> [!NOTE]
> 交互式 TUI 模式（`-I` / `--interactive`）因第三方终端 UI 依赖尚未适配 MoonBit `v1.0.0-rc1`，当前暂时关闭。传入 `-I` 或 `--interactive` 将直接返回 `not_implemented` 错误（退出码 `2`）。

---

## 安装

### 通过 MoonBit 包管理器（推荐）

```sh
moon install unmbt/moon-taze/cmd/moon-taze
moon-taze --help
moon-taze -V
```

请确保 `~/.moon/bin` 已加入环境变量 `PATH`。

### 预编译原生二进制

```sh
# Linux / macOS
curl -fsSL https://raw.githubusercontent.com/unmbt/moon-taze/master/scripts/install.sh | bash

# Windows PowerShell
irm https://raw.githubusercontent.com/unmbt/moon-taze/master/scripts/install.ps1 | iex
```

---

## 命令行用法

```sh
# 默认只读预览兼容更新
moon-taze

# 递归检查工作区/子模块的大版本更新并按文件分组
moon-taze major -r --group

# 无损写回推荐更新，并在写入后运行 `moon check` 验证
moon-taze -w --verify

# 将 GitHub Actions 引用固定为 40 位 Commit SHA（附带 `# vX.Y.Z` 注释）
moon-taze --github-actions-style sha -w

# 关闭 GitHub Actions 检查（仅检查 MoonBit 清单）
moon-taze --no-github-actions

# CI 模式：输出 JSON 报告，发现可更新依赖时返回退出码 1
moon-taze --json --fail-on-outdated
```

### 常用参数

| 参数 | 说明 |
| :--- | :--- |
| `[mode]` | `default` \| `major` \| `minor` \| `patch` \| `latest` \| `stable` \| `newest` \| `next` |
| `-C, --cwd <dir>` | 指定扫描起点目录 |
| `-w, --write` | 应用所有推荐更新 |
| `-a, --all` | 同时显示已是最新和被跳过的依赖 |
| `-r, --recursive` | 递归扫描子目录中的 `moon.mod` 与 GitHub Actions 文件 |
| `-n, --include <deps>` | 仅检查匹配的选择器（逗号分隔，支持 `*` 通配） |
| `-x, --exclude <deps>` | 排除匹配的选择器（支持版本范围如 `foo/bar@1`） |
| `--no-github-actions` | 禁用 GitHub Actions 检查 |
| `--github-actions-style <style>` | Actions 写回风格：`auto`（默认保持原风格） \| `tag` \| `sha` |
| `--sort <type>` | 排序方式：`name-asc` \| `name-desc` \| `diff-asc` \| `diff-desc` \| `time-asc` \| `time-desc` |
| `--group` | 按清单路径分组显示 |
| `--timediff` | 显示当前版本与目标版本的发布时间差 |
| `--maturity-period [days]` | 忽略发布不满 `days` 天的版本（裸标志默认 `7` 天） |
| `--maturity-period-exclude <deps>` | 成熟期过滤豁免选择器 |
| `--retry [times]` / `--no-retry` | 瞬时网络错误重试次数（默认 `4`） |
| `-f, --force` | 忽略并刷新 30 分钟本地磁盘缓存 |
| `--verify` | 成功写入 `moon.mod` 后执行 `moon check`（需配合 `-w`） |
| `--json` | 输出机器可读 JSON v1 报告 |
| `--fail-on-outdated` | 存在可用更新时返回退出码 `1` |
| `-s, --silent` | 静默输出文本诊断 |
| `-V, --version` | 输出裸版本号（便于 CI 校验） |

### 配置文件（`moon-taze.json`）

可在项目或工作区根目录放置静态配置 `moon-taze.json`（命令行参数始终优先）：

```json
{
  "mode": "minor",
  "recursive": false,
  "exclude": ["legacy/*"],
  "maturityPeriod": 3,
  "githubActions": {
    "style": "auto"
  }
}
```

查询 GitHub Actions 标签时，工具会自动按 `GITHUB_TOKEN` → `GH_TOKEN` → `gh auth token` 顺序读取认证 Token，避免匿名 API 限流。

---

## 作为 MoonBit 库使用

在你的项目中添加 `unmbt/moon-taze` 即可复用离线可测的依赖解析、计划生成与原子写回能力（完整可执行示例见 [README.mbt.md](README.mbt.md)）：

- **纯策略解析**：`parse_version`、`choose_version`、`select_version`、`select_action_target`、`resolve`。
- **清单解析**：`parse_manifest`、`parse_github_actions_manifest`、`read_workspace`、`read_config`。
- **统一检查与写回**：`CheckOptions`、`check`、`check_manifests`、`check_path`、`apply` 与 `Callbacks`。

---

## 架构设计与本地验证

详细架构图、清单/注册表契约与原子写回不变量见 [docs/DESIGN.md](docs/DESIGN.md)。

```sh
moon check --target native
moon test --target native
moon build --target native
moon run --target native tools/cli_smoke.mbtx
moon run --target native tools/release_check.mbtx
```

## 许可证

[MIT](LICENSE)
