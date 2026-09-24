# 06 · 调研证据

核对日期：2026-09-25。以下区分读取到的事实、离线探针结果与尚未运行的验证。未接触真实上游凭据、未修改 Keychain、证书或系统 ACL。

## TypeSafe 官方资料

| 资料 | 本次确认 |
| --- | --- |
| [Quick start](https://docs.typesafe.ai/introduction/quickstart) | 系统使用 state + typed questions；默认 jev-latest |
| [HTTP API](https://docs.typesafe.ai/api.md) | POST /v1/systemone；三种 Question/Answer、usage、401/422/429/529 |
| [SDK 索引](https://docs.typesafe.ai/sdk.md) | 当前列出 Python 与 JavaScript/TypeScript；明确允许任意语言直接调用 HTTP |
| [Python SDK](https://docs.typesafe.ai/sdk/python.md) 与 [Usage](https://docs.typesafe.ai/sdk/python/usage.md) | 自定义 base_url、RetryPolicy、raw response；debug 会记录未脱敏 body |
| [Python client](https://docs.typesafe.ai/sdk/python/api/clients/sync.md) | 可传 transport、timeout；max_retries=0 禁用自动重试 |
| [State](https://docs.typesafe.ai/concepts/state.md) | string/object/array 的状态表达 |
| [Choice](https://docs.typesafe.ai/primitives/choice.md) | 结构化 instructions/criteria；批量独立题与候选项分布 |
| [Confidence](https://docs.typesafe.ai/confidence.md) | Choice/Score 分布集中度；Noul 没有 confidence；阈值需按领域评估 |
| [Models](https://docs.typesafe.ai/models.md) | alias 与实际模型区分；设计不硬编码模型版本 |

本机 reference skill 位于 `workspace/references/typesafe-skills/skills/typesafe-ai/SKILL.md`，读取快照 `a31ec925a8f55333cb3197d20594fcc139d67583`。它强调 Jev 返回 typed judgments 与 probabilities，不生成推理解释；活文档是协议事实来源。没有把引用 skill 的本地路径误认为 Falcon 内已有 reference 目录。

官方 Python 源码核对快照：[typesafe-sdk-python@0ffd094](https://github.com/typesafe-ai/typesafe-sdk-python/tree/0ffd094c72ed9445223060b24ffd7a56aa781fb4)。`_core/config.py` 验证 key 为非空、无空白的可打印 ASCII，不要求 TypeSafe 专属前缀；`_core/client/sync/client.py` 支持 base URL 和 transport 注入。

### 已执行的离线 SDK 探针

使用本机 quick-decide skill 的锁定依赖环境，实际包版本 `typesafe-sdk==0.7.1`，`httpx2.MockTransport` 注入固定 synthetic response：

| 项目 | 结果 |
| --- | --- |
| 内部 key | 非秘密测试值 `falcon_test_nonsecret` 被 SDK接受 |
| base_url | `http://127.0.0.1:19823` |
| SDK构造的请求 | `POST http://127.0.0.1:19823/v1/systemone` |
| 返回解析 | Choice=`local`、Noul=`0.9`、Score=`0.2`、input_tokens=`10` |
| 网络/计费 | 无真实 HTTP socket、无上游调用、无 usage 消耗 |

这是官方客户端形状验证，不是 Falcon server 集成测试。探针未提交为产品代码；实现时把此类契约纳入真实本地 HTTP 测试。SDK源码快照和已安装 0.7.1 分开记载，不假定两者完全相同。

另按工作流调用一次 Jev 做调研/委派建议，发送的是简短任务摘要，没有生产请求与凭据：返回 `jev-1.13.0`；建议 proceed 0.46、subagent 0.61、主要顾虑 missing_evidence 0.52。此调用仅是工作安排建议，不构成 Falcon 协议验收或产品决策样本。

## Swift 与 MCP 资料

| 资料 | 已确认 / 未确认 |
| --- | --- |
| [MCP Swift SDK 0.12.1](https://github.com/modelcontextprotocol/swift-sdk/tree/0.12.1) | tag SHA `a0ae212ebf6eab5f754c3129608bc5557637e605`；Package.swift 要求 Swift tools 6.1 |
| [StatelessHTTPServerTransport](https://github.com/modelcontextprotocol/swift-sdk/blob/0.12.1/Sources/MCP/Base/Transports/HTTPServer/StatelessHTTPServerTransport.swift) | 已读源码：JSON response、无 SSE/session、GET/DELETE 405、notification 202；waiter 以 RPC id 索引，因此文档要求每 HTTP 请求隔离实例 |
| [MCP transport specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports) | Origin 校验、loopback、认证、Accept、协议头、GET 405 合法；连接断开不等价取消 |
| [Hummingbird](https://github.com/hummingbird-project/hummingbird) | 已读 README：SwiftNIO HTTP server、loopback 绑定、路由与生命周期；尚未构建 Falcon 适配 |
| [GRDB](https://github.com/groue/GRDB.swift) | 已读 Package.swift，系统 SQLite、Swift API；尚未确定并锁定与其他依赖兼容的发布版本 |

不能把官方 MCP SDK 的 NetworkTransport 当 HTTP server parser，也不能把 HTTPClientTransport 当 server。无状态 MCP 在实际 agent 客户端的初始化、并发、授权 header 设置与每请求实例模式尚需实施期验证。

## 原生 UI 参考

| 项目快照 | 已读文件 | 采用的设计经验 |
| --- | --- | --- |
| [Showtime a3614a4](https://github.com/nocoo/showtime/tree/a3614a4bdf9dcc73eb338d7815891302b0f60007) | `Package.swift`、`Sources/Showtime/App/StudioTheme.swift`、`StudioView.swift`、`docs/studio.md` | 统一动态色、轻表面与细边框、原生窗口、Reduce Motion、240 ms 过渡 |
| [Lyre b4131da](https://github.com/nocoo/lyre/tree/b4131da570edfa9b971f9bdc9f9b5c2023ebc20d) | `apps/macos/Lyre/Views/LyreTheme.swift`、`MainWindowView.swift`、`docs/09-macos-ui-redesign.md` | 单窗口导航、32 pt 控件、紧凑表单、主题一致、真实进度、不把可达性当认证 |

本轮读取的是代码和项目文档，没有启动这两个应用做视觉回归；它们记录的截图、测试和性能结果不属于 Falcon。Falcon 的配色、token、布局与验证矩阵见 [04](04-interface.md)，须以真实实现再验收。

## 工作流事实

从 nmem 查到《开发流程：编号文档》（ID `400e2be9-d4a2-4dae-83bb-01ce038567be`）：编号文件名使用小写英文连字符，README 建立入口，列明确切改动位置、原子提交与质量计划，不写工时估算。当前文档树据此初始化。

初始 Falcon 仓库只有 LICENSE，main 工作区干净；没有可继承的 app target、依赖、CI 或既有测试。当前 docs 所写的质量与性能全部是计划，只有本文件明确标为“已执行”的调研探针属于执行证据。

[目录](README.md) · [返回项目入口](../README.md)
