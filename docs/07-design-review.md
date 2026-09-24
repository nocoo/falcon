# 07 · 独立设计审阅记录

日期：2026-09-25。结论：**PASS，设计文档无未解决阻断项**。

## 范围与方式

主控完成设计后，在独立 Herdr pane 启动 Codex（GPT-6-Sol，high reasoning），只读审阅 README、AGENTS 与全部编号设计文档。Reviewer 自行读取文档、精确 Git diff、官方 TypeSafe 文档和 MCP Swift SDK 源码；不修改文件、不实现应用、不接触凭据。首次进程因 service tier 错误未执行审阅，不计为有效审阅，过程见 [Retrospective](../Retrospective.md)。

审阅按文档推荐方案进行：七天仅留存、纯 Swift HTTP 运行时与官方 SDK 开发期验证。两项产品取舍明确待用户确认；通过不表示用户已选择，也不授权开始实现。

| 轮次 | 精确内容版本 | 判定 |
| --- | --- | --- |
| 初审 | `7ae82b4e745e35422b4db9a69254e39ec4aca120` | CHANGES REQUIRED：5 项发现 |
| 复审 | `a8ec73b68bc9ace2eca3315b6d5242f36a7dcf50` | 原 5 项解决；新增 1 项交付门槛一致性问题 |
| 最终确认 | `8fcb76ac175ae6865ae363d30feac644957ea236` | PASS：最后 1 项解决，无新阻断项 |

本记录与导航链接在最终确认之后追加；没有改变被审阅的设计契约。

## 发现与处理

| 编号 | 严重性 | 问题 | 最终处理 |
| --- | --- | --- | --- |
| R1 | P1 | URL 和 key 分别读取会在配置切换时错配 | [执行快照](02-architecture.md)：完整 URL/model/credential 不可变快照、版本原子启用、旧凭据在途引用回收 |
| R2 | P2 | 每 POST 新 Server 与跨 POST 初始化承诺不一致 | [MCP 生命周期](03-protocol.md)：显式 strict=false、每 POST 支持版本校验，明确不保存初始化关联；首层验证完整标准客户端序列 |
| R3 | P2 | 本地 schema 拒绝官方 SDK 的扩展字段 | [字段透传](03-protocol.md)：校验已知字段，保留根和 question 的附加 JSON 字段，不允许其覆写 Falcon 路由与认证 |
| R4 | P2 | 单请求容量检查会被并发请求重复占用 | [容量预留](02-architecture.md)：唯一全局 actor、原子总账、DB/WAL/投影余量、单次释放、回收空闲页 |
| R5 | P3 | 单份 request BLOB 无法证明代理转换 | [数据模型](02-architecture.md)：received_request、effective_request、upstream_response 分别持久化，共同到期 |
| R6 | P2 | 协议首层门槛与交付章“可提前测试”冲突 | [第一层退出条件](05-delivery.md)：强制完整 MCP 序列、同 ID 并发与断连清理；正式接入保留在第 2 层 |

Reviewer 最终原文结论：

> 上轮剩余的 P2 已解决；8fcb76ac175ae6865ae363d30feac644957ea236 的完整设计文档集：PASS。此前五项已在上轮判定解决，本次未发现新的文档阻断项。

## 已验证与未验证

已验证：官方 Jev 路径、三种题型和用量字段；MCP SDK 0.12.1 的选定 transport / Server 行为；官方 Python SDK 0.7.1 离线契约探针；文档本地链接、示例 Python 语法、Git whitespace；跨文档一致性。Reviewer 认可主要 UI 旅程、状态和可访问性规划覆盖，且质量/性能诚实标为目标。

未验证：Swift 依赖共同构建、真正的 Falcon HTTP / MCP 互操作、Keychain 与并发配置实现、容量上界公式、七天清理、实际 UI 与动效、资源预算、6DQ gate。这些必须在 [交付计划](05-delivery.md) 的对应阶段提交运行证据。没有执行真实 Falcon App 测试，因为应用尚不存在。

下一步由用户审阅设计并确定 [两项产品选择](01-product.md)，再决定是否进入实现。本次没有 push、发布或系统凭据配置变更。

[目录](README.md) · [项目入口](../README.md)
