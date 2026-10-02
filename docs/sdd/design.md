# 技术设计与接口契约

版本：0.3。以下包含已实现的 P1a/P1b 与后续阶段目标。公开 Services/Callbacks 接口代码块仍是文档级草案；当前可用接口以生成的 `.mbti` 为准。阶段实现边界以 [推进路径](tasks.md#roadmap) 为准。

<a id="d-01"></a>
## D-01 架构与实现边界

```mermaid
flowchart LR
    CLI[CLI / JSON 配置] --> Engine[检查引擎]
    Engine --> Manifest[清单发现与解析]
    Manifest --> Inputs[依赖与文件快照]
    Inputs --> Resolve[纯版本策略]
    Registry[Mooncakes 适配器] --> Resolve
    Infra[HTTP / 缓存 / 并发] --> Registry
    Resolve --> Plan[CheckPlan]
    Plan --> Output[文本 / JSON / TUI]
    Output --> Apply[应用选中变更]
    Apply --> Writer[校验快照与保真写回]
    Writer --> Verify[显式 moon check]
```

清单层负责从哪里读取、写入，Registry 层负责版本数据，策略层决定候选。CLI 不自行选择版本或拼装替换字符串。检查引擎先完成整个输入范围的解析和查询，再进入应用阶段，不沿用 taze 并行检查单个项目时立即写回的执行方式。

对外根包拥有公共具体类型与 API；版本解析、清单扫描、HTTP/文件/终端适配可放在内部包。CLI 保持薄入口。依赖注入显式传递，不复刻 Node.js 的 AsyncLocalStorage。

实施候选为已核验存在的 `moonbitlang/core/argparse` 和 `moonbitlang/async` 的 HTTP、FS、process 等能力；业务 SemVer 与 DSL 源码区间解析放在本项目。具体依赖版本须经 T-01 Native 构建验证后锁定，不把核验样本版本当作最新或最低兼容保证。不依赖 shell、curl 或 Node 来执行日常查询。

<a id="d-02"></a>
## D-02 项目发现与清单解析

### 发现规则

1. `--cwd/-C` 相对调用目录解析并规范化；未指定则使用进程工作目录。
2. 起点恰为 `moon.work` 所在目录时，检查其全部显式成员；根目录模块只有也被列为成员才自动纳入。起点是成员模块目录或其子目录时，只检查该模块，但向上读取最近工作区以判断本地依赖。
3. 普通目录向上寻找最近的 `moon.mod` 或 `moon.work`，到文件系统根或 Git 边界为止；遇到只有旧清单的项目返回不支持错误。开启 `--recursive` 时，以起点为额外向下扫描边界，即使起点没有清单也可发现子模块。
4. 默认跳过目录 `.git`、`.moon`、`.mooncakes`、`_build`、`target`、`node_modules`、`dist`、`public`、`fixture`、`fixtures`。路径忽略规则再追加用户配置。版本控制、依赖下载、构建产物目录不作为发现来源。
5. 递归默认不进入带 `.git` 文件/目录或独立 `moon.work` 的子树；`--no-ignore-other-workspaces` 才允许进入并按独立工作区处理。不会跟随目录符号链接或 Windows junction 递归。
6. `moon.work` 成员采用相对工作区根的显式目录路径，不扩展 glob。显式成员不受默认 fixtures 等发现忽略影响，但仍受用户 `ignorePaths` 影响。不存在的成员、重复模块名、嵌套工作区成员歧义均报错。成员路径可含 `..`；这是清单明确授权的成员，不由递归扫描扩大。
7. 先构建完整成员名集合，再施加检查范围和用户路径过滤。因此即使某个成员未被检查，其他成员对它的引用仍标记 `local_workspace`。递归发现但未在同一工作区的同名模块不触发此规则。
8. 文件按规范化真实路径去重；Windows 使用系统路径大小写语义。稳定展示使用相对调用根的 `/` 路径，外部显式成员保留 `../`。没有找到任何清单报 `no_manifest`；找到零依赖清单则成功。

### 解析与位置

输入为 UTF-8；允许 BOM、LF、CRLF 和文件末尾无换行。词法层识别字符串转义、标识符、注释和括号结构，只把顶层普通 `import { "user/module@1.2.3", ... }` 中的字符串当作依赖，不能用全局正则替换。

采用最右侧 `@` 分开模块名和具体版本；模块名允许多个 `/` 分段，不能为空、包含路径遍历分段或查询/片段分隔符。完整版本必须通过 SemVer 校验。`^`、`~`、URL、缺版本等非本版本支持的依赖形式返回 `unsupported_dependency_spec`，不猜测其含义。

所有普通 import 合并检查；同一个模块出现多次，即使版本相同也报 `duplicate_dependency`。`import ... for ...` 中非普通依赖类别识别后跳过并警告 `unsupported_dependency_kind`，不能误更新其中内容。顶层未知元数据字段保留；若发现会改变依赖来源的未知声明形式，则报不支持，不忽略后继续写入。

扫描器必须理解被跳过表达式的字符串、注释和配对括号，防止其中的 `import` 被识别为依赖；不执行任何清单表达式，也不承担完整 MoonBit 编译器的语义检查。无法确定语法结构边界时返回解析错误。

每项依赖保存 UTF-8 **字节**半开区间 `[start, end)`、解码后的模块名和版本、原始版本切片及行列。不得将 MoonBit String 的 UTF-16 索引当成 UTF-8 字节位置。依赖字符串含转义时维护解码与原始字节位置映射；无法唯一定位可替换版本区间时拒绝写入该清单。不重新序列化整个文件。

同目录新旧清单并存报 `ambiguous_manifest`；不自动迁移。`moon.work` 只读，其注释、成员顺序和其他字段不写回。

<a id="d-03"></a>
## D-03 数据模型与库 API

P1b 实施说明：保留 `check_manifest[_filtered]`、`check_path[_filtered]`；`CheckPlan` 改为私有字段，只通过 `changes()`、`diagnostics()`、`has_errors()` 访问，数组及嵌套数组均复制。原始字节直接用于最终比较，当前无需摘要。新增 `recommended_selection()`、`selection(Array[(清单路径, 依赖名, 目标版本)])` 及 `apply(plan, selection)`。选择带计划身份，应用报告保留全部提交结果；本轮 IO 端口、批次组装及提交前钩子保持内部，不提前开放下文完整 Services/Callbacks。此为实验性 API 的显式迁移。

| 类型 | 必需信息 / 不变量 |
| --- | --- |
| `Dependency` | 所属模块、清单路径、依赖模块名、声明版本、来源类别、原始文本区间；实例 ID 由相对清单路径与依赖名组成 |
| `VersionMetadata` | 模块名、具体版本、撤回状态/原因、可选 UTC 发布时间；未知时间与零时间不同 |
| `ModuleMetadata` | 模块名、可选 latest 指针、去重后的版本集、来源端点和获取时间 |
| `DependencyChange` | 依赖、有效模式、状态、可选目标版本、候选列表、diff、跳过原因、诊断；错误项不可选 |
| `ManifestSnapshot` | 规范化路径、原始字节、用于快速比较的摘要、修改区间；写前最终核对原始字节 |
| `CheckPlan` | 不可由外部任意构造的检查结果；包含清单/工作区快照、选项快照、冻结的当前时间、全部状态和候选 |
| `Selection` | 被选实例 ID 与目标版本；目标必须来自该实例候选，不能注入额外文件或任意版本 |
| `ApplyReport` | 每个文件的 written / unchanged / failed / not_attempted，变更数、验证结果、诊断 |
| `Diagnostic` | 稳定 `code`、warning/error、消息、可选路径/行列/依赖/重试信息；不暴露认证信息 |

检查状态为 `update_available / up_to_date / no_candidate / skipped / error`。有合格的更高版本为 update_available；注册表存在更高、未撤回版本但全部被本次策略排除时为 no_candidate；其余成功检查为 up_to_date。后两者均不代表全局最新或源码兼容。默认文本展示更新、no_candidate、警告和错误；JSON 永远保留全部状态。

`DiffKind` 分为 `major / minor / patch / prerelease`：按数字三元组变化分类，三元组相同但预发布变化归入 prerelease。0.x 的兼容边界由策略计算，不仅靠颜色推断风险。

拟定公开入口如下；所引用类型在实施时由根包定义，`Services` 提供可替换的 IO 端口，实际方法明细按下表形成正式契约。

```mbt nocheck
declare pub type CheckPlan
declare pub type Services
declare pub type Callbacks
declare pub type Selection
declare pub type ApplyReport

declare pub async fn check(
  services : Services,
  cwd~ : String,
  mode? : UpdateMode = Default,
  recursive? : Bool = false,
  config? : Config,
  callbacks? : Callbacks,
) -> CheckPlan

declare pub fn resolve(
  dependency : Dependency,
  metadata : ModuleMetadata,
  policy : Policy,
  now~ : Int64,
) -> DependencyChange raise ResolveError

declare pub async fn apply(
  plan : CheckPlan,
  selection : Selection,
  services : Services,
  verify? : Bool = false,
  callbacks? : Callbacks,
) -> ApplyReport
```

`check` 返回收集了逐项错误的计划；参数、全局配置及无法开始检查的环境错误通过错误通道返回。`resolve` 是无 IO 的纯函数。`apply` 拒绝含 error 的计划，报告已发生的部分写入后不得仅抛出丢失上下文的异常。`CheckPlan` 提供只读访问器和从合格候选构造 `Selection` 的方法，不能通过修改数组绕过验证。此阶段不提供计划文件的保存/重放协议，JSON 报告不是可执行计划。

P3a 已先交付不暴露内部写入器的根包子集：`Policy` 与 `resolve` 已公开；现有 `check_manifest*`/`check_manifests*` 接受可选 `Callbacks`；`apply` 接受同一回调集合；`Selection::items()` 返回副本。回调函数返回空字符串表示接受，非空消息分别形成 `callback_failed` 或 `callback_denied` 诊断。完整 `Services` 注入入口、验证参数和终端适配仍按 T-10/T-12 后续切片实施，不能将当前 Native writer 误称为可替换公共端口。

| 可注入接口 | 责任 |
| --- | --- |
| Manifest | 发现、读取、提取依赖与区间、构造补丁；统一写入器控制落盘 |
| Registry | 获取模块及指定版本元数据；不选择版本、不写清单 |
| Http、Clock、FileSystem、Terminal、Process | 网络、墙上/单调时钟、文件快照与替换、TTY/输入输出、无 shell 子进程 |
| Cache | 成功元数据的缓存；不保存依赖选择结果 |

回调事件包括 `after_discovery`、`dependency_resolved`、`before_apply`、`file_applied`、`after_run`。解析完成事件可能并发到达，但都带实例 ID；文档化为串行派发给消费者，消费者不得依赖发现顺序。`before_apply` 在任何落盘前调用一次，接收完整选择并可否决。其他回调不修改计划；回调异常在写前中止，在写后保留应用报告并返回错误，不重放写入或回调。

<a id="d-04"></a>
## D-04 Mooncakes 协议

默认 API 根为 `https://mooncakes.io`。`registry` 配置或 `--registry` 可替换根地址；模块名逐路径分段编码、版本单独编码，不用用户输入直接拼接可改变主机的 URL。不读取 moon 的凭据、Registry 索引或 `MOONCAKES_REGISTRY`，也不上传清单。

| 请求 | 用途 | 使用的响应字段 |
| --- | --- | --- |
| `GET /api/v0/modules/{module}` | 所有检查都需要的模块概览 | `module`、`latest_version`、`versions[].version`、`versions[].yanked`、`versions[].yanked_reason` |
| `GET /api/v0/modules/{module}@{version}` | 某版本的发布时间及状态复核 | `module`、`version`、`yanked`、`metadata.created_at` |

`created_at` 位于 metadata 内，不假设版本列表每项带时间。概览顶层 `version` 只是当前响应所描述的版本，不用它替代完整版本集。输入数组可能倒序，策略不可依赖顺序。

模块名、版本必须与请求对应；缺版本列表、错误类型、非法版本、重复版本冲突、详情版本不匹配均报 `invalid_metadata`。允许未知附加字段；空数组合法。列表撤回字段缺失时必须获取详情确认，仍不明确则报错，不默认当成未撤回。

latest 指针为空或缺失时保留 None；指针指向列表以外的版本视为 `invalid_metadata`，不私自补齐一个可更新候选。HTTP 404 对已声明依赖是错误，不是空版本集。顶层或详情确认撤回可加强列表结果；任一数据源认为撤回就不选该版本，并记录不一致警告。

时间按 RFC 3339 解析为 UTC；同一执行固定 `now`。时间仅在 newest/next、成熟期、时间展示/排序需要时查询：先应用无需时间的过滤，再请求相关候选；timediff 另取当前与目标版本时间。不同消费者共享版本详情请求。缺字段与 HTTP 失败分开处理，见 D-05/D-07。

本次核验的最小摘录（2026-09-23；不是稳定测试数据）：

```json
{
  "module": "moonbitlang/async",
  "version": "0.22.1",
  "latest_version": "0.22.1",
  "versions": [{"version": "0.22.1", "yanked": false, "yanked_reason": null}]
}
```

```json
{
  "module": "moonbitlang/async",
  "version": "0.21.3",
  "yanked": false,
  "metadata": {"created_at": "2026-09-08T10:08:48.490590+00:00"}
}
```

以上摘录省略了无关字段及其他版本，不表示接口只返回这些信息。详情端点使用 `@version`；不得使用已验证无效的 `/versions/{version}` 路径，也不能假设 `?version=` 改变版本。

<a id="d-05"></a>
## D-05 版本选择

### 共同规则

采用 SemVer 2.0.0，要求完整 `major.minor.patch`；不接受前导 `v`、省略段、数字前导零。数字预发布段按数值比较，数字段低于非数字段；稳定版高于相同三元组的预发布。build metadata 不影响优先级，禁止为 build metadata 的变化单独更新。元数据存在多个等优先级候选时按完整版本字符串字典序作为确定性 tie-break。

首先判断工作区本地依赖、名称包含/排除与 `ignore` 策略；被跳过的依赖不请求 Registry。其余候选依次经撤回过滤、候选版本排除、模式范围/预发布资格、成熟期过滤和不降级过滤，再选择目标。成熟期豁免仅绕过时间门槛，不能绕过撤回、排除或降级规则。

候选集合仅包含严格高于声明版本的版本；没有更高版本时不写入。当前版本已撤回会发出警告，但仍允许升级到合格新版本。当前版本不在列表中时发出 `current_version_missing` 警告，以清单版本作比较基准，不降级到列表中的旧版本。

caret 上界：`^1.2.3` 为 `<2.0.0`，`^0.2.3` 为 `<0.3.0`，`^0.0.3` 为 `<0.0.4`；tilde 上界为同 major、minor 的下一 minor。对于普通稳定版本，default 因而不会更新 `0.0.3` 到 `0.0.4`，显式 patch 则允许。

### 模式表

| 模式 | 合格范围与选择 |
| --- | --- |
| `default` | 裸版本视为 caret 下限；在合格版本内选择 SemVer 最大值 |
| `minor` | 同 default 的 caret 规则，包括 0.x 边界；不简化成“任何同 major 版本” |
| `patch` | 从当前版本起的 tilde 范围内选择 SemVer 最大值 |
| `major` | 同一模块名下不设兼容上界，选择合格的 SemVer 最大值；不改模块路径 |
| `stable` | 当前版本的 caret 范围内，只选稳定版的 SemVer 最大值 |
| `latest` | 优先选择合格的 `latest_version`；如因撤回、排除、成熟期等失去资格，回退至不高于该指针的最高合格 SemVer；无指针时在全部合格版本中选最高值 |
| `newest` | 不受兼容范围约束，在更高版本中按发布时间选最新，包含预发布；时间相同先选 SemVer 高者，再用字符串 tie-break |
| `next` | 当前适配器没有已核验的 next 标签能力，因此与 newest 使用同一回退规则；输出 `next_tag_unavailable` 警告 |

default/minor/patch/major 从稳定版出发时排除预发布；从预发布出发时允许当前数字三元组的预发布和范围内稳定版，不自动进入另一个三元组的预发布轨道。stable 始终排除所有预发布。latest 允许预发布的条件是当前版本或 latest 指针本身为预发布；不能把 latest 一概称为稳定版。

default/minor/patch/major 若 latest 指针满足其范围和预发布条件，则额外以该指针为上限，保留 taze 的 latest cap 习惯；否则不施加该上限。不发明 Mooncakes 未提供的 beta/rc 通道标签。stable/newest 不施加此 cap。

newest/next 所有可能胜出的候选都需要可靠时间；任何一项时间缺失或非法时，该依赖返回 `incomplete_release_times` 错误，不能猜测真正最新版本。未来时间属于非法元数据。latest/default 等无需时间的模式不因无关的缺时间而失败。

### 成熟期

未开启为 0 天；裸参数为 7 天，显式值接受非负整数。合格条件严格为 `published_at < now - days * 86400 秒`，恰好到边界仍不放行，与参考 taze 的严格小于一致。配置 0 时不查时间。

开启后，缺少/非法时间的候选记 `unknown_release_time` 并排除，允许其他已知成熟候选参与；若同时运行 newest/next，采用上面的严格完整性规则。网络失败属于查询错误而非缺字段，阻止应用整个计划。豁免支持整模块或指定版本范围，仅该部分无需成熟期时间。

### 过滤语法

名称选择支持完整模块名和 `*`（匹配任意长度，可跨 `/`），大小写敏感、整串匹配；逗号分隔及重复 CLI 参数合并为数组。`--include` 只接受名称，`--exclude` 与成熟期豁免接受 `name@range`。完整排除与 `packageMode=ignore` 优先，版本排除只移除匹配候选，不移除整个依赖。

范围支持精确三段版本、`^`、`~`、`>`/`>=`/`<`/`<=` 比较器、空格连接的 AND、`||` OR、`*`/`x` 段及 `1`/`1.2` 简写；不支持连字符区间、括号表达式或正则。比较过滤使用 include-prerelease 语义，随后由模式决定候选预发布资格。非法规则在发起网络前报错；不把无效规则当作不匹配。

逐依赖配置是有顺序的规则数组，第一条匹配生效，避免 JSON 对象顺序的隐含优先级。它覆盖合并后的全局模式；这是相对 taze `mergeMode` 的明确简化，不声称逐项兼容其冲突时忽略行为。

<a id="d-06"></a>
## D-06 CLI 与配置

```text
moon-taze [default|major|minor|patch|latest|newest|stable|next] [options]
moon-taze minor -C ./project
moon-taze major -r --include "acme/*" --exclude "acme/lib@2" --json
moon-taze patch -w --verify
moon-taze -I --maturity-period 7
```

| 选项 | 默认 / 行为 |
| --- | --- |
| `--cwd, -C <dir>` | 进程目录 |
| `--recursive, -r` | false |
| `--ignore-paths <patterns>` | 额外忽略；相对扫描根，`*` 不跨 `/`、`**` 可跨，整条匹配；目录匹配排除子树 |
| `--ignore-other-workspaces` / `--no-ignore-other-workspaces` | true |
| `--include, -n <selectors>` / `--exclude, -x <selectors>` | 空；含义见 D-05 |
| `--write, -w` | false；选择所有合格目标 |
| `--interactive, -I` | false；手动选择并确认才应用 |
| `--all, -a` | false；显示无更新和跳过项 |
| `--json` | false；有此参数强制禁用交互 |
| `--fail-on-outdated` | false；按初始计划是否存在可更新项计算 |
| `--sort <value>` | `diff-asc`；接受 diff/name/time 的 asc/desc |
| `--group` / `--no-group` | true；按所属模块分组 |
| `--timediff` | false；显示目标发布时间减当前发布时间 |
| `--include-locked, -l` | 接受但不改变结果，帮助文本明确说明裸版本本已参与 |
| `--force, -f` | false；忽略旧缓存，仍做本次请求去重 |
| `--registry <url>` | `https://mooncakes.io`；不带 query、fragment 或 userinfo 的绝对 HTTP(S) 根；HTTP 只用于显式本地测试服务 |
| `--concurrency <n>` | 10，正整数 |
| `--request-timeout <ms>` | 5000，正整数，单次请求含读取完整响应 |
| `--retry [n]` / `--no-retry` | 4 次重试；裸参数 4，0 等同禁用 |
| `--retry-factor <n>` | 2，至少 1 |
| `--retry-min-timeout <ms>` | 1000，非负整数 |
| `--retry-max-timeout <ms>` | 不设上限；显式值不得小于 min |
| `--retry-randomize` | false；开启后乘以 `[1,2)` 随机因子，测试可注入随机源 |
| `--maturity-period [days]` | 未传 0；裸参数 7 |
| `--maturity-period-exclude <selectors>` | 空 |
| `--loglevel <level>` | info；接受 debug/info/warn/error/silent |
| `--silent, -s` | false；无普通文本输出，仍保留明确请求的 JSON 输出与退出码 |
| `--verify` | false；要求显式 `-w` 或交互模式；`--json -I --verify` 仍须 `-w` |
| `--help` / `--version` | 不加载配置、不读清单、不联网 |

P1 只开放当阶段已经实现的选项和模式；其他已规划选项必须报不支持，不能接受后忽略。`-i/-u/-g/--peer/--nodecompat` 等原工具选项不复用为新的隐式行为。未知选项退出 2。

P1a 只开放只读检查，`-w` 到 P1b 才可用。P1 尚未实现工作区语义时，发现当前模块作用域内有 `moon.work` 就返回 `workspace_not_supported_yet`，不把本地成员引用当作远端依赖。有限请求超时、取消、TLS 证书验证和错误阻止写回从 P1a 起就必须成立：早期查询串行、无持久缓存和自动重试；P2 的 T-07 完成后才开放调度/缓存/重试参数及最终默认值。

配置文件为调用范围根下的 `moon-taze.json`：在工作区根运行时读工作区配置，在单模块内运行时读该模块配置；无模块的递归运行读扫描根配置。每次只加载一份，不向父目录层层合并。配置不存在使用默认值；存在但非法为错误。

```json
{
  "mode": "default",
  "recursive": true,
  "include": ["acme/*"],
  "exclude": ["acme/experimental", "acme/lib@^2.0.0"],
  "ignorePaths": ["examples/**"],
  "packageMode": [
    {"match": "acme/compiler", "mode": "major"},
    {"match": "acme/legacy", "mode": "ignore"}
  ],
  "maturityPeriod": 7,
  "maturityPeriodExclude": [],
  "concurrency": 10
}
```

配置键使用上表选项的 camelCase，另加 `packageMode`；禁止 `cwd`、`write`、`interactive`、`verify`、`json`、`silent`、`help`、`version` 和 `includeLocked`。CLI 数组值整体覆盖配置数组，同一 CLI 选项多次出现按顺序追加；标量重复以最后一次为准。显式 false/0 有效。未知键、重复 JSON 键、错误类型或超出数值范围均报错。配置不得通过自定义 shell 命令或插件执行代码。

可配置的布尔项均支持对应 `--no-*`，包括 recursive、all、group、ignore-other-workspaces、timediff、retry-randomize、fail-on-outdated 和 force，使 CLI 可以覆盖配置中的 true。retry 配置值为非负整数，CLI `--no-retry` 归一化为 0；其他数值项不接受布尔值。

<a id="d-07"></a>
## D-07 网络、缓存与并发

默认值核验来源是 taze CLI、constants 和 cache 源码。并发上限覆盖模块概览和版本详情的全部实际请求；请求在退避等待时不占用 HTTP 并发槽，但同资源后续消费者仍等待同一任务。

对网络中断、超时、HTTP 408/429/5xx 重试；404、其他 4xx、TLS 证书验证失败和响应 schema 错误不重试。最多执行 `1 + retry` 次。第 k 次重试（从 1 开始）基础延迟为 `min(max, minTimeout * factor^(k-1))`，可选随机因子在其后乘入；默认延迟为 1、2、4、8 秒。有效 Retry-After 作为额外的最小等待要求，优先于本地 max；用户取消立即终止等待。

同资源 key 包括规范化 API 根、模块名、资源种类和可选版本。进行中的请求共享成功或失败结果并可靠清理；只缓存通过验证的成功元数据。不同端点的同名模块不能命中同一缓存。

缓存路径由平台用户缓存目录决定：Windows 为 `%LOCALAPPDATA%/moon-taze`，macOS 为 `~/Library/Caches/moon-taze`，Linux 为 `$XDG_CACHE_HOME/moon-taze` 或 `~/.cache/moon-taze`。使用版本化文件名 `cache-v1.json` 和同目录临时文件替换。无法确定可写用户缓存目录时只用内存缓存。

TTL 为获取完成后的 30 分钟，恰好达到 TTL 视为过期；时间倒退导致未来获取时间的项失效。缓存损坏、版本不兼容或写失败给警告并继续联网；不能转成依赖不存在，也不能回退到过期成功数据。多进程缓存竞争允许丢失部分缓存命中，但不得破坏清单或返回未经验证的数据；不承诺跨进程请求去重。

`--force` 不读取旧磁盘/内存条目，仍共享本次请求结果并刷新缓存。查询所有未跳过依赖后统一收集错误；不因某项失败自动取消其他项，除非用户主动取消。整个检查有任一 error 时，所有自动写回均被阻止。

只读检查允许更新工具自己的缓存，不更改项目文件。HTTP 校验证书，不向重定向后的不同主机传播认证信息；不读取用户发布 token。日志不包含完整网络响应和本机敏感环境。

<a id="d-08"></a>
## D-08 展示、交互与 JSON

### 文本与交互

表格包含所属模块、依赖名、声明版本、目标版本、变化类型和状态/原因。差异着色只影响视觉，不影响排序或机器输出；非 TTY 或 `NO_COLOR` 非空时无 ANSI。可显示宽度必须考虑中文、组合字符、全角和 emoji，不按 UTF-16 长度填充。

模块按相对路径排序。组内 diff-asc 顺序为 prerelease、patch、minor、major，desc 反转；name 使用模块名 Unicode 标量字典序；time 使用目标发布时间从旧到新，desc 从新到旧。未更新时间的行永远在已知时间之后，其他相等项以依赖名、清单路径作 tie-break。up_to_date/skipped/error 等无变更项排在变更之后，不受 diff-desc 反转影响。

`--timediff` 为目标发布时间减当前发布时间，可能为负（版本优先级不等于发布时间）；文本用天/小时摘要，JSON 使用秒，未知为 null。展示所需详情查询失败仍是 error；字段缺失只警告并显示未知。

交互要求 stdin/stdout 都是 TTY。方向键移动，Space 切换选择，`a` 全选/清空合格项，`v` 展开当前依赖的策略合格候选，Enter 进入确认页；确认页列出精确版本和文件，`y` 应用，`n` 返回选择。Esc 或 Ctrl-C 取消并退出，不写文件。候选不含当前版本，取消选择即保持原声明。默认预选每项推荐目标，不能在 TUI 中绕过撤回、成熟期或版本排除规则。

窗口变化重新计算可见区域；错误、取消与正常退出均恢复光标、输入模式和颜色。`--json` 优先禁用交互，包括配置或 `-I` 请求；只有同时显式 `-w` 才写回。最终确认前发生 error 时确认操作不可用。

### JSON v1

stdout 恰好输出一个 JSON 对象并以换行结束；即使参数错误（已识别 `--json`）也用同一顶层结构。所有字段固定存在；无值用 null 或空数组。文本诊断按日志级别输出到 stderr，JSON 内完整保留 warning/error，不受 silent 过滤。

```json
{
  "schemaVersion": 1,
  "mode": "default",
  "status": "ok",
  "projects": [
    {
      "manifest": "moon.mod",
      "module": "demo/app",
      "dependencies": [
        {
          "name": "demo/lib",
          "current": "1.2.0",
          "target": "1.3.0",
          "mode": "default",
          "status": "update_available",
          "diff": "minor",
          "reason": null,
          "selected": false,
          "applied": false,
          "currentPublishedAt": null,
          "targetPublishedAt": null,
          "timeDiffSeconds": null
        }
      ]
    }
  ],
  "summary": {"checked": 1, "updates": 1, "skipped": 0, "errors": 0, "writtenFiles": 0},
  "diagnostics": [],
  "apply": {"status": "not_requested", "files": [], "verification": []},
  "exitCode": 0
}
```

顶层 status 为 ok/error/cancelled；mode 是全局模式，无法解析时为 null，各依赖 mode 是有效模式。summary.checked 是尝试解析的依赖数，不含 skipped，含查询错误；updates 是原始计划可更新项数，写完也不归零；errors 是 error 诊断条数。`selected` 表示本次应用意图，预览时 false；`applied` 只有确认已落盘时为 true。

诊断对象固定字段为 `severity / code / message / manifest / dependency / line / column`，不适用的定位为 null。apply.status 为 not_requested/succeeded/failed/partial/cancelled；files 元素含 `manifest / status / changedDependencies`，verification 元素含 `cwd / status / exitCode`。未尝试的数值 exitCode 为 null。apply 失败原因在 diagnostics 中用文件定位关联。

JSON 项目和依赖按路径、名称稳定排序，不随 `--sort` 改变；`--all` 不影响 JSON 完整性。消费者忽略未来新增字段；删除字段、改变类型或状态语义需要提升 schemaVersion。JSON 不包含原始文件字节、内部摘要、绝对缓存路径或可直接重放的补丁。

<a id="d-09"></a>
## D-09 应用计划与文件完整性

P1b Native 实施：Windows 通过 `SetFileInformationByHandle(FileRenameInfoEx)` 同目录替换，显式复制 owner/group/DACL；没有 copy/delete 降级。POSIX 适配复制 owner/group/mode 及扩展权限元数据后 rename，尚未实机验收。临时内容写入前限制权限，写入后再次恢复权限并同步。锁和临时文件记录本次运行 ID/文件身份，清理时核对身份；遗留文件不按时间自动接管，未知临时文件保留。此处的权限保留不意味着保留所有文件属性、附加数据流或审计 SACL。

应用输入必须来自本次 `check` 的有效计划，不支持反序列化任意 JSON 作为计划。逐项验证选择属于候选、没有重复实例、没有降级、没有重叠修改区间。空选择成功且零 IO 写入；整体检查错误仍不能通过空选择掩盖。

步骤固定如下：

1. 所有清单和参与本地依赖判断的 `moon.work` 快照重新读取并逐字节比较。任意变化报 `stale_plan`，本次不写任何文件。交互等待期间也适用。
2. 每个文件聚合全部选中补丁，按字节位置从后向前应用，避免前面替换长度改变后面位置。重新解析结果，确认模块名/依赖集合不变，且只有目标版本改变。
3. 对所有将变更文件先创建同目录临时文件并写入完整内容，关闭并按平台能力同步，保留权限。任何准备失败发生在正式替换前，清理临时文件并零清单写入。
4. 调用 `before_apply` 后再次检查所有源快照；按规范化路径顺序提交。每个文件提交前重新比较，使用平台原子的替换原语，不采用“删除旧文件再重命名”。平台不支持可靠替换时报错，不退化为截断原文件。
5. 单文件成功后记录 written 并回调。后续文件失败则停止，剩余记 not_attempted，返回完整部分成功报告和退出 2；不自动回滚已经写入的文件。

只承诺单文件替换的完整性，不承诺跨文件事务或断电后全仓库一致。初始预检可避免已知冲突；外部编辑器在最终比较与原子替换间仍可能竞争，不能声称有跨程序 compare-and-swap 保证。

正式准备前，按规范化路径顺序在每个将写入文件旁独占创建 `moon.mod.moon-taze.lock`；任一锁已存在则释放本次已取得的锁，报 write_conflict，不等待。锁覆盖读取预检到提交结束，记录本次运行标识，正常退出只删除本次拥有的锁。因此重叠扫描范围也不会让两个工具实例同时提交。崩溃留下的锁不按时间自动抢占；错误提示其路径，由用户确认原进程已结束后清除。锁不约束外部编辑器，也不将锁文件作为将来扫描的输入。

写入器拒绝以符号链接文件作为清单的写入目标，报告 `unsafe_write_target`；只读检查可以读取并标明此限制。无需更新时不重写文件、不改变 mtime。正文不得自动运行 `moon fmt`，因为它可能迁移或重排用户清单。

中途 Ctrl-C 在原子替换边界停止：若尚无提交则 cancelled，若已有提交返回 partial 并退出 2。任何时刻不得声称未提交文件已更新。程序异常留下的自有临时文件可在下一次应用时识别并清理；不会删除未知临时文件。

Registry 状态属于检查时的快照，缓存 TTL 不代表写入瞬间仍未撤回。默认应用不额外刷新网络；需要最新检查可重新运行 `--force`。文档不承诺锁住远端发布状态。

<a id="d-10"></a>
## D-10 错误、退出码与更新后验证

| 类别 | 示例代码 | 行为 |
| --- | --- | --- |
| 参数/配置 | invalid_option、invalid_config、unsupported_option | 不联网，不写项目，退出 2 |
| 发现/解析 | no_manifest、ambiguous_manifest、duplicate_dependency、invalid_manifest、unsupported_dependency_spec | 收集可定位错误，整个应用被阻止 |
| Registry | module_not_found、request_timeout、http_error、invalid_metadata、incomplete_release_times | 保留其他查询结果，整个应用被阻止 |
| 可解释的非致命状态 | local_workspace、excluded、mode_ignore、current_version_missing、unknown_release_time、next_tag_unavailable | 记录跳过/警告，不伪装成执行失败 |
| 写回 | stale_plan、invalid_selection、unsafe_write_target、write_conflict、write_failed | 返回未写/已写文件清单，退出 2 |
| 验证/回调 | moon_unavailable、verification_failed、callback_failed | 保留已写结果，不自动回滚，退出 2 |

优先级：有 error 或部分写入 → 2；否则 `--fail-on-outdated` 且初始计划 updates > 0 → 1；否则 → 0。因此 `-w --fail-on-outdated` 即使写入成功仍返回 1。交互取消且没有 error 时也按此规则计算；取消状态单独可见，不能把退出 0 解读成已经应用。

`--verify` 必须与允许应用的 CLI 选项一起出现；无需更新或最终选择为空时不启动子进程。准备写入前先检查 PATH 中的 moon 是否可执行，缺失则零写入退出 2。全部文件成功提交后，对有变更的独立模块分别执行一次 `moon check`，同一工作区只在工作区根执行一次；顺序稳定，不追加 `--target native`，从而遵循用户项目配置。

使用可执行文件及参数数组启动，绝不拼接 shell 命令。进程输出转至 stderr，JSON stdout 仍干净。`moon check` 可能同步依赖及生成构建产物，这是用户显式请求验证的效果；moon-taze 本身不解析或重写其依赖安装目录。任一次验证非零即记录错误，但继续记录其他已更新根的验证结果。

不开启验证时，不调用 `moon install`、`moon add` 或 `moon update`。只有部分写入时不执行验证，报告需要用户检查的已更新清单及可手动运行的命令。

<a id="d-11"></a>
## D-11 测试与交付边界

核心使用纯函数版本梯测试；Registry 用注入响应和本地假 HTTP 服务；IO 测试用唯一临时目录及隔离缓存；回调、时间、重试、排序不依赖真实时钟。文本断言与少量结构快照分开，不能用快照代替版本选择正确性断言。

Native 候选库已有 HTTP/FS/process 接口和平台实现文件；P0 已在 Windows x86_64 编译运行隔离探针并记录 HTTPS、系统证书、文件替换、进程和终端结果。尚未证明三平台可分发。T-13 自 P1a 起逐步运行三平台已有功能子集，P4 完成构建/运行/终端的最终验收。失败时修复适配层或显式更新设计，不能暗改为 Node 包装或宣称测试通过。

具体场景和追踪矩阵见 [acceptance.md](acceptance.md)，任务完成门槛见 [tasks.md](tasks.md)。真实网络冒烟只核对响应结构和只读检查，不断言“今天最新版本固定为某值”，也不更新开发者项目。

<a id="d-12"></a>
## D-12 核验记录、差异和来源

核验日期为 **2026-09-23**；以下结论只陈述已取得的证据。在线 latest 文档不视为对安装版本的无条件保证。

| 事实 | 证据 | 限制 |
| --- | --- | --- |
| 参考 taze 21.1.0 的 CLI、默认值和模式 | [package.json](../../taze/package.json)、[cli.ts](../../taze/src/cli.ts)、[constants.ts](../../taze/src/constants.ts) | 本地副本，无已核实上游 commit |
| Manifest / Registry 双轴架构 | [分析](../../taze/docs/architecture.md)、[Manifest](../../taze/src/manifests/types.ts)、[Registry](../../taze/src/registries/types.ts)、[检查流程](../../taze/src/api/check.ts) | 采用边界，改为先全量检查再应用 |
| 裸版本与 `includeLocked` | [npm registry](../../taze/src/registries/npm/registry.ts) 中 targetMode 与 updateTargetVersion | moon-taze 默认参与，是明确适配 |
| stable/next/newest 实际算法 | [versions.ts](../../taze/src/utils/versions.ts)、[版本测试](../../taze/test/versions.test.ts)、[元数据转换](../../taze/src/utils/packument.ts) | newest 上游取列表末项，不在该函数中按时间排序 |
| 并发/超时/重试/缓存参数 | [CLI](../../taze/src/cli.ts)、[缓存](../../taze/src/registries/cache.ts) | 损坏缓存和错误分类采用本设计契约 |
| MoonBit 本地版本 | `moon version` → `0.1.20260920 (914d7da 2026-09-20)` | 发行最低版本在 T-13 实测确定 |
| 新 DSL 清单与工作区 | [模块配置](https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html)、[工作区](https://docs.moonbitlang.com/en/latest/toolchain/moon/workspace.html) | 只承诺这里列出的依赖/成员输入形式 |
| 最小版本选择 | [包管理说明](https://docs.moonbitlang.com/en/latest/toolchain/moon/package-manage-tour.html#semantic-versioning-convention) | 不把声明当作实际安装版本 |
| 概览 API | [async 概览](https://mooncakes.io/api/v0/modules/moonbitlang/async) | 实际返回 0.22.1 及 versions/yanked 字段，服务可能变化 |
| 详情 API | [async 0.21.3](https://mooncakes.io/api/v0/modules/moonbitlang/async@0.21.3) | 实际返回对应版本及 metadata.created_at |
| 当前命令含义 | `moon add --help`、`moon install --help`、`moon check --help`、`moonx --help` | install 无参数已标 deprecated；update 刷新索引；不用于模拟升级 |
| CLI 与 IO 候选依赖 | `moon ide doc '@argparse'`；本地 async 0.21.3 归档中的 HTTP 文档、Windows IO/TLS 文件；[async 文档](https://mooncakes.io/docs/moonbitlang/async/) | 包存在和源文件存在不等于集成运行验证 |
| SemVer 比较基准 | [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html) | caret/tilde 是本工具选择策略，不是清单新语法 |

### 与分析文档或上游行为的显式差异

| 主题 | 核对结果与本项目决策 |
| --- | --- |
| stable | 分析文档描述为全局最高稳定版；上游源码仍满足 current range。本项目采用兼容范围内稳定版。 |
| newest | 分析文档说按发布时间；上游 getMaxSatisfying 直接取版本列表末项，packument 转换未提供独立排序保证。本项目明确按 created_at 排序，不依赖数组顺序。 |
| next | 上游无 next tag 时取列表末项；本项目无已核验 tag 时按 newest 的时间排序回退并警告。不是凭 `-next` 后缀猜标签。 |
| 默认裸版本 | 上游默认不更新；本项目将其视为兼容范围下限，保持写回裸版本。 |
| 当前版本撤回 | 参考 npm 实现可能直接保持；本项目警告后仍允许向未撤回的新版本升级。 |
| 成熟期缺时间 | 上游放行缺时间候选；本项目开启成熟期时排除并警告，newest 时间不完整时失败。 |
| 逐依赖模式 | 上游 mergeMode 可能因显式全局模式冲突而忽略依赖；本项目第一条匹配规则覆盖全局模式。 |
| 格式保真 | 分析文档用“100% 保真”概括；上游 JSON 写回还涉及重新序列化。本项目明确承诺版本区间以外字节不变，并独立验收。 |
| 多文件写回 | 上游单项目检查可立即写入；本项目全量查询成功才开始提交，提交中仍可能部分失败。 |
| 范围/平台 | JS 配置、正则选择器与多生态集成不移植；Native 三平台是待完成验收目标，不是现状。 |

文档修改者应同时更新行为、差异说明及对应测试，不能仅用“与 taze 一致”覆盖已经明确的生态适配决策。
