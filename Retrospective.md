# 事故与改进记录

本文件记录本项目实际发生的事故、原因和后续防范措施。

稳定项目约束维护在 [AGENTS.md](AGENTS.md)，架构与设计维护在 [docs](docs/README.md)。

## 2026-09-25: Immediate restart could leave the proxy offline

- Native restart verification found Falcon running without a listener. An isolated HTTP fixture reproduced `Address already in use` when rebinding immediately after a completed request; restarting after the TCP wait interval had hidden this failure.
- ProxyServer explicitly disabled Hummingbird's default address reuse. It now uses the library default, with regressions for immediate same-port restart and rejection of a second live listener. Fixture teardown drains the service and closes SQLite before deleting its marked directory.
- Validate service readiness immediately after restart. A successful process launch and preserved database alone do not establish a working proxy.

## 2026-09-25: Source editing opened the creation sheet

- The owner selected Edit source and saw Add source. Presentation used separate Boolean and optional-source state; the lazy sheet closure could capture the earlier empty source during its first presentation.
- One identifiable presentation item now carries the source snapshot into the sheet. Add and edit each set that item directly. Native checks cover the first edit presentation, populated fields, selected icon and Save changes, alongside the separate creation sheet.
- For editors whose content depends on a selection, bind sheet presentation to that selection instead of maintaining a separate visibility flag.

## 2026-09-25: Preview teardown deleted an open database

- The owner saw `SQLite error 10: disk I/O error` at `PRAGMA query_only = 1` while the source-icon preview was closing. System logs tied the exact error to that preview process: its marked temporary database, WAL and SHM had been unlinked while SQLite still used them. The production database passed a read-only integrity check and continued accepting requests.
- A GRDB fixture reproduced the same error after deleting an open store and refreshing its workspace. AppRuntime now owns the observation task, stops the workspace, cancels and awaits observation and maintenance, drains the service, closes GRDB and its lock, and only then removes the verified preview directory. Late activation cannot restart a stopped workspace.
- Regressions verify teardown with active observation, late refresh and activation, idempotent close, lock ownership after reopening, and preserved request evidence. Native preview verification must check system SQLite diagnostics after exit as well as the captured image; a successful screenshot cannot establish safe cleanup.

## 2026-09-25: Incoming decisions were withheld from the list

- The owner reported delayed arrivals. The workspace polled once a second, treated every inactive window as suspended, and kept new request rows out of the list while an older decision was selected. Successful API persistence alone did not establish live visibility.
- Subscribe to committed database changes through GRDB with a bounded notification buffer. A visible inactive window keeps refreshing; new rows enter immediately while selection, notes and the scroll anchor remain stable. Track the pagination cursor separately so a burst larger than one page cannot hide intervening records.
- A synthetic upstream is held behind a gate while the workspace observes the store. The test verifies that the request appears before the gate opens, then receives completion and delivery updates without manual refresh. Separate pagination coverage retains the selected draft through 101 arrivals and loads every intervening row.
- Native capture exposed two additional scroll issues: aligning a new row with the viewport hid its source under the pinned date header, and treating an absent row anchor as the top pulled a history view back to the latest request. Scroll to a separate content-start anchor and determine top position from scroll geometry. Check both top and historical viewport captures; a populated model alone cannot establish correct scrolling.

## 2026-09-25: Database restart failed during journal setup

- Restarting Falcon failed with `cannot change into wal mode from within a transaction`. The original setup ran journal PRAGMAs inside `DatabaseQueue.write`. SQLite left a new database in rollback-journal mode and rejected the same WAL switch when that populated database reopened. Fresh-store tests had missed the reopen path.
- Configure WAL through GRDB's connection configuration, and prepare secure deletion and initial incremental vacuum before schema transactions. Reopening keeps the existing tables, profiles and audit records intact.
- The regression covers both a fresh store and an existing marked rollback-journal file, writes history and a review, releases the store, then reopens it and checks the content and journal mode. Startup checks must exercise a second launch against persistent data.

## 2026-09-25: Connection checks hid subsequent sources

- The owner reported that live agent decisions were absent from the interface after connection setup. Read-only inspection confirmed successful requests in the active app's history. A regression reproduced a visibility defect: the connection check left the workspace filtered to its archived temporary source, so later agent requests remained hidden.
- Connection checks now select their recorded result while keeping all sources visible. A single active source filter displays its name. The regression inserts a subsequent request from another source and verifies that it appears without changing the selected check.
- Stored API evidence and visible UI evidence are separate checks. Validate the post-setup arrival flow as well as the connection check itself.

## 2026-09-25：独立审阅的启动与布局检查

- **经过**：第一次独立 Codex 审阅进程启动成功，但实际推理返回 `service_tier is not supported`，没有产生审阅结论。设置审阅 pane 时，按外层布局推断 resize 的作用范围，短暂把主控列调得过窄，随后恢复为左侧三分之一。
- **原因**：进程 ready 不代表首个模型请求已成功；嵌套 split 的 resize 操作作用于相邻分隔线，不能按整个窗口比例推断。一次 `--current` resize 返回了其他活动窗口的上下文且 `changed=false`，后续全部使用已核实的显式 pane ID。
- **防范**：必须读取首轮实际输出，不能把 idle/done 当作 review 通过；服务等级调整只作用于受控进程，不改全局配置。调整布局前读取 layout，操作后核验返回的 pane ID、changed 和几何位置，保留已有用户 pane。

## 2026-09-25：原生窗口启动与截图等待

- **经过**：早期把服务启动挂到窗口 View 的任务，直接启动程序或临时 app 时只有菜单栏窗口，主窗口未建立，截图等待超时。
- **原因**：应用启动依赖尚未呈现的窗口内容，窗口与运行时之间形成了启动次序问题；观察到的事实不足以归因于 SwiftUI Group 取消。
- **修复与防范**：由 AppDelegate 持有唯一 AppRuntime，在 applicationDidFinishLaunching 启动服务并监听休眠；主 scene 显式打开窗口。截图只选择可成为主窗口的内容视图，失败报告具体窗口状态，并有有限等待和完整 shutdown。

## 2026-09-25：Swift 工具链与 Release 体积

- **经过**：机器默认选择 Command Line Tools，SwiftLint 的 SourceKit 曾无法加载。初版 universal Release 包约 99 MiB，超过设计预算。
- **原因**：静态检查依赖完整 Xcode 工具链；打包同时携带双架构、符号及覆盖率 instrumentation，不能把体积直接归因于三个直接依赖。
- **修复与防范**：每条检查显式设置 DEVELOPER_DIR，不修改机器全局选择。Release 使用本机架构、Osize 和 stripping；Xcode app scheme 关闭 coverage，SwiftPM 测试显式启用。仅设置 CLANG_ENABLE_CODE_COVERAGE 不足以移除 Swift instrumentation，且 xcodebuild 的 -enableCodeCoverage 仅支持 testing，不可用于 build。检查最终 Mach-O sections 和实际启动日志，再测量 bundle 与压缩文件体积，不能只凭构建配置认定已关闭。

## 2026-09-25：Token 数值边界

- **经过**：最终代码复核发现 Double(Int.max) 在 64 位平台向 2^63 舍入，原来的比较会放行不可转换的数值；总量、分桶、来源和 UI 直接求和也可能溢出。
- **修复与防范**：上游 token 从保真数值文本精确转换为 Int；聚合使用 addingReportingOverflow，无法表示的值保持不可用，不饱和截断或伪造零。回归验证巨大、负数、小数、正常计数，以及持久化后逐层聚合和原始记录保留。

## 2026-09-25：JSON 数字在代理中被改写

- **经过**：独立 Pi 复核发现 JSONValue 把全部数字解码为 Double，9007199254740993 会变成 9007199254740992；请求重编码和指纹都受影响。探针也证实 Decimal 会截断足够长的数字。MCP SDK 的 Value 是第二个数值转换边界。
- **修复与防范**：JSON 值保留数字文本，字符串转义仍用 Foundation，增加严格语法、重复键和深度保护。MCP 协议仍交 SDK，工具参数与结果独立保真；指纹使用无浮点舍入的十进制规范化。新增真实 HTTP/MCP、审计原文、展示、分组、精确 token、非法 JSON 和 64 组 Foundation 对照回归。
- **验证教训**：回归初稿漏了 HTTP 必需的 model，收到符合契约的 422。先核对实际协议和类型；HTTP 显式 model 与 MCP 的连接默认模型分别验证，不能把 fixture 错误当作产品缺陷。

## 2026-09-25：原生品牌图片的资源加载

- **经过**：透明 PNG 与 ICNS 生成、构建均成功，但首张真实 App 截图的侧栏 logo 为空。
- **原因**：Xcode 将 PNG 的 1×/2× 资源合成 TIFF；SwiftUI 按资源名称加载未显示，而 AppKit 的 bundle image 查询正确返回两个分辨率。品牌接入规范已有同类原生项目经验，初次实现未落实到调用方式。
- **修复与防范**：共享 `FalconAssets` 使用 AppKit bundle image 查询，分别验证 Xcode 与 SwiftPM 的实际资源和窗口。图片尺寸、alpha 与编译成功都不能代替真实消费者检查。

## 2026-09-25：菜单栏图标尺寸未被约束

- **经过**：品牌接入后的窗口截图正常，但用户发现系统菜单栏显示了过大的彩色游隼头像。
- **原因**：原图的 `NSImage` 逻辑尺寸为 64×64 pt，且不是模板图片；`MenuBarExtra` 没有采用 SwiftUI 的尺寸与渲染修饰。此前的窗口截图没有覆盖菜单栏消费者。
- **修复与防范**：菜单栏使用原图副本，在 AppKit 层设为 18×18 pt 和模板图片。临时原生探针使用生产图片加载代码与打包资源，确认真实 `MenuBarExtra` 按钮为 34×22 pt、图像为 18×18 pt 且模板标志有效，并捕获自身控件检查显示；原始品牌图仍保持 64×64 pt 和彩色模式。后续品牌验证分别覆盖窗口、菜单栏与 Dock。


## 2026-09-25: Normalize image pixels before extracting a template

- The first menu-template exporter used `NSBitmapImageRep.colorAt` and per-pixel NSColor conversion on a generated PNG. AppKit repeatedly reported an unrecognized color-space model, producing excessive diagnostics and making the resulting mask unreliable. The raw image and production app were unchanged.
- Convert the decoded CGImage once into an explicit sRGB RGBA bitmap, then derive alpha directly from normalized bytes. Avoid per-pixel color-object conversion. Capture build output in a bounded log, inspect the actual alpha coverage, and review small light/dark specimens before adopting generated menu assets.

- During this task, the first Herdr Codex worker also inherited an unsupported service tier. Resuming that worker with `-c service_tier=default` made its first real model turn succeed. Keep the override local to the worker, and inspect the first completed tool action before treating an idle/ready process as functioning delegation.
- CoreSVG separately rejected compact arc commands in the Manifest Hermes SVG. The checked-in original stays unchanged; a 512 px transparent master from the existing Sharp/librsvg toolchain supplies the native downsizing step. Require a clean resource-generation log and inspect every bundled icon.

## 2026-09-26: Resolve coverage output before SDK verification

The release preparation assumed SwiftPM's conventional architecture-specific
coverage path. This checkout writes to `.build/out/Products/Debug/codecov`;
the copy failed while the separately launched SDK check continued and replaced
the coverage report. Re-run the complete suite and preserve its actual output.
Resolve the directory first and chain the copy and SDK invocation with success
checks so a missing archive cannot silently lose full-suite evidence.

The first universal build still contained only arm64: `ONLY_ACTIVE_ARCH=YES`
overrode the requested architecture list. Set it to `NO` while preserving the
explicit host-architecture default, rebuild, and require `lipo -verify_arch`
before packaging. Successful Xcode output alone does not prove universal output.

The local `lipo -verify_arch` rejected two architecture arguments with
"requires exactly one input file", even with the input path first. Its help
advertises multiple architectures, but separate arm64 and x86_64 checks both
passed. Use one architecture per invocation and test the exact packaging check
on the real output instead of assuming documented multi-value behavior.

## 2026-09-26: Installed signatures do not prove signing availability

The installed Gecko binary identified the requested Apple Development signer,
but Falcon signing failed with "no identity found". Scoped code-signing identity
discovery then reported zero matching identities. No ad-hoc fallback or Keychain
change was made. An installed signature proves who signed those bytes, not that
the certificate and private key are currently available. Installation docs were
corrected to identify the release as pending rather than already downloadable.

After the owner clarified that Xcode was signed in and authorized their free
personal signing route, `xcodebuild -allowProvisioningUpdates` with automatic
Apple Development signing and the known team succeeded. The same identity then
appeared locally. An empty identity list is a local-state observation, not proof
that Xcode account-managed provisioning cannot obtain a signing identity. Use
the authorized automatic-signing route before asking the owner to restore keys.

## 2026-09-26: Accessibility environment values in visual probes

The temporary status-light probe tried to override SwiftUI's read-only
`accessibilityReduceMotion` and `accessibilityReduceTransparency` environment
values. Compilation correctly rejected those overrides. The corrected probe
compares active and inactive scenes without changing machine accessibility
settings; reduced-effects branches remain code-reviewed rather than claimed as
runtime-tested. Check environment mutability before creating synthetic probes.
