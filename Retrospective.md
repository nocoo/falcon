# 事故与改进记录

本文件记录本项目实际发生的事故、原因和后续防范措施。

稳定项目约束维护在 [AGENTS.md](AGENTS.md)，架构与设计维护在 [docs](docs/README.md)。

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
