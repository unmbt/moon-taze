# P1b 写回核验记录

日期：2026-09-24。环境：Windows x86_64、MoonBit `0.1.20260920 (914d7da)`、async `0.21.3`、MSVC 14.44 / Windows SDK 10.0.26100.0。工具链及依赖版本未升级。

## 结果与边界

P1b 单模块 `-w/--write` 已实现；36 个常规 Native 测试通过，另有 1 个文件符号链接实机场景需要权限，未计入通过数。多文件准备、提交及部分失败由同一内部应用引擎测试；没有开放工作区或递归 CLI。

| 场景 | 证据 | 结果 |
| --- | --- | --- |
| AC-040 字节保真、幂等 | `apply_test.mbt`：多段 import、多个不同长度版本、BOM、中文/emoji、CRLF、LF、无末尾换行、未选依赖与字符串中的伪版本 | 目标字节精确匹配；重新检查再应用时 mtime 不变、写入数为 0 |
| AC-041 过期清单 | 公开 apply 前修改；内部提交前钩子修改第一个清单 | 零提交、保留新内容，`stale_plan` 定位到真正变化的清单 |
| AC-042 准备失败 | 第二个临时文件创建失败或部分写入后失败 | 三份原清单均不变；本次锁和临时文件清理 |
| AC-043 提交失败 | 第二次原子替换注入失败 | 第一份 written、第二份 failed、第三份 not_attempted；partial、退出 2，无回滚 |
| AC-044 锁与权限 | 重叠运行持锁竞争、第二个锁被占用、只读目标、显式禁止继承的 Windows ACL | 不接管他人锁；自己已取得的锁释放；只读目标拒绝；成功替换前后 `icacls` 输出一致 |
| AC-044 不安全目标与替换能力 | 重叠区间、注入符号链接目标、不支持原子替换 | 明确失败、原文件保持完整 |
| AC-044 文件符号链接实机 | Windows `@fs.symlink(..., force_symlink=true)` | 系统返回 `A required privilege is not held by the client`；当前环境未验收通过 |
| AC-035 查询/解析错误 | CLI 的一个依赖成功、另一个失败；重复依赖；错误计划加空选择 | 全部阻止写入；保留成功依赖的预览与错误诊断 |
| 选择与快照隔离 | 非候选、降级、重复项、额外路径、跨计划选择；修改访问器返回数组 | 不影响私有计划，不产生未授权补丁；相对路径锚定检查时 cwd |
| 取消与资源所有权 | 提交前取消、首个提交后取消、真实 async Task.cancel、资源路径被他人替换 | cancelled/0 或 partial/2；未提交文件不更新；清理拒绝删除不同文件身份的资源 |
| CLI 行为 | `cmd/main/main_wbtest.mbt` 使用 FakeRegistry；独立进程冒烟 | 默认预览、筛选写回、重复运行、错误零写入；7 个进程退出码场景通过 |

AC-041 的 `moon.work`/公开回调变体留待 P2/P3a。AC-051 此处只验证非交互写回取消，不宣称 TUI/CI 组合已完成。AC-044 整体仍有实机符号链接验收缺口。

## 复现命令

```sh
moon check --target native
moon test --target native
moon build --target native
moon run --target native tools/cli_smoke.mbtx
moon info
moon fmt
```

常规测试不联网。CLI 冒烟启动真正的 Native 产物，只使用临时的零依赖/非法依赖清单，验证 0/2 退出码、只读和无更新 mtime。临时项目均隔离，不写仓库根清单。

需要文件符号链接权限的场景保留 `#skip` 注解，显式执行如下命令（当前环境已尝试并记录权限失败）：

```sh
moon test --target native write_native_wbtest.mbt --filter "Native rejects symlink*" --include-skipped
```

## C 适配层 ASan

`tools/write_native_asan.c` 对生产 C 适配层执行 200 轮独占创建、冲突、身份查询、权限复制、已有文件替换、缺失路径及非法 UTF-8 路径场景。`tools/validate_write_native.mbtx` 在临时目录编译和运行，不改全局 MoonBit 运行时。

结果：`native adapter ASan: 200 replacement/error-path cycles passed`，退出 0，无 ASan 错误。

编译器为 LLVM clang 22.1.3；使用动态 ASan 运行时。测试替身以受 ASan 跟踪的 malloc 实现返回 Bytes 的分配，检查范围是 C 适配层，不是完整 MoonBit GC/运行时；Windows 下关闭 leak detection，不能将结果表述为完整 LSan 通过。

标准编译环境中运行：

```sh
moon run --target native tools/validate_write_native.mbtx
```

本机为便携 MSVC 安装，实际复现命令如下；`MOON_HOME` 使用已配置的 `D:/devenv/moonbit`，其余路径按本机工具链调整：

```powershell
$env:ASAN_RUNTIME_DIR = 'D:/devenv/llvm/lib/clang/22/lib/windows'
moon run --target native tools/validate_write_native.mbtx -- `
  -fuse-ld=lld `
  -isystem D:/devenv/msvc/VC/Tools/MSVC/14.44.35207/include `
  -isystem 'C:/Program Files (x86)/Windows Kits/10/Include/10.0.26100.0/ucrt' `
  -isystem 'C:/Program Files (x86)/Windows Kits/10/Include/10.0.26100.0/shared' `
  -isystem 'C:/Program Files (x86)/Windows Kits/10/Include/10.0.26100.0/um' `
  -L D:/devenv/msvc/VC/Tools/MSVC/14.44.35207/lib/x64 `
  -L 'C:/Program Files (x86)/Windows Kits/10/Lib/10.0.26100.0/ucrt/x64' `
  -L 'C:/Program Files (x86)/Windows Kits/10/Lib/10.0.26100.0/um/x64'
```

## 接口和平台限制

- `CheckPlan` 字段迁移为访问器，新增 `Selection`、`ApplyReport`、`apply`；完整库 API 稳定承诺仍在 P3a。公共类型归属根包，IO 端口与 FFI 保持私有。
- Windows 已实测普通及受保护 ACL 的替换，旧系统不支持所需替换原语时直接失败，不回退到删除或截断原文件。
- POSIX 分支已提供 owner/group/mode 与扩展权限复制，但 Linux/macOS 未实机运行，尚不声明支持。
- Windows owner/group/DACL 的保留不意味着审计 SACL、附加数据流、所有属性和时间戳都保留。替换仅承诺文件内容完整，不承诺跨文件事务或断电持久性。
- 编译器仍提示既有保留字、冗余修饰符、隐式 trait promotion 等 warning；依赖 C 代码亦有既有 `EINVAL` 宏重定义 warning。测试及构建均无错误。
