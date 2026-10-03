# P4 证据

核验日期：2026-10-03。目标：T-13 Native 平台验证与 T-14 发行前检查。

## 可复现检查

`tools/p4_release_check.mbtx` 顺序执行 `moon version`、Native build/check/test 和 CLI smoke；追加 `--online` 时再执行 HTTPS、进程和终端探针。脚本通过参数数组启动子进程，不写入项目清单。

Windows x86_64 本机结果：

```text
P4 Native release validation
[moon-version] exit=0
[moon-build-native] exit=0
[moon-check-native] exit=0
[moon-test-native] exit=0
[cli-smoke] exit=0
P4 Native release validation: passed
```

在线探针结果：

```text
https=HTTP 200
process=exit=0, stdout=moon 0.1.20260920 (914d7da 2026-09-20)
terminal=stdin-available=true
```

`moon test --target native` 为 50/50；`moon run --target native tools/cli_smoke.mbtx` 通过。非 TTY 交互冒烟通过：`--interactive` 返回 `interactive_requires_tty`，退出码 2；`--interactive --json` 保持 JSON 错误对象格式。

## 平台与环境边界

- 本轮执行环境为 Windows x86_64；Linux 和 macOS 已加入 `.github/workflows/native-matrix.yml`，尚未取得真实 runner 输出，因此不标为已支持。
- `tools/validate_write_native.mbtx` 的 ASan harness 在当前 Windows 环境返回 `-1073741515`，对应缺少 ASan 运行库；常规 Native 写回测试已通过，ASan 结果不能替代发布验证，需在带运行库的环境重跑。
- 文件符号链接写入仍受当前 Windows 账户权限限制；该场景继续保持待验证。
- 当前发布候选架构仅记录 Windows x86_64；Linux x86_64、macOS arm64 需 CI 实跑后追加证据，其他架构不作支持承诺。

因此 P4 已完成可复现检查器、发布矩阵和 Windows 首轮证据；三平台最终放行仍未完成。
