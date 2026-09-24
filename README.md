# Falcon

**让本机 Agent 的 Jev 决策看得见。**

Falcon 是规划中的 macOS 原生应用：向本机提供 TypeSafe / Jev HTTP 与 MCP 代理，以独立内部 key 区分调用来源，集中管理上游连接，并提供最近 7 天的决策观察与用量可视化。

核心体验是从一条请求直接看清：**谁来决策、提供了什么上下文和选项、Jev 返回了什么、用了多少资源**。技术方向是 SwiftUI + Swift，保持小体积、单进程和原生交互。

> 当前阶段：设计文档已通过独立 Codex 审阅，等待用户确认产品取舍与下一阶段。仓库尚无可运行应用、构建配置或自动化测试；设计中的指标均是验收目标，不是已完成的性能或质量结论。

## 📖 设计入口

| 文档 | 内容 |
| --- | --- |
| [文档目录](docs/README.md) | 阅读顺序与设计状态 |
| [01 产品与范围](docs/01-product.md) | 用户场景、边界和需要确认的选择 |
| [02 架构与数据](docs/02-architecture.md) | Swift 选型、生命周期、持久化、7 天留存 |
| [03 HTTP、MCP 与 Jev](docs/03-protocol.md) | 认证、协议、结果语义与错误契约 |
| [04 界面与动效](docs/04-interface.md) | 信息架构、视觉 token、交互与可访问性 |
| [05 交付与验证](docs/05-delivery.md) | 分层实现、原子提交与质量验收 |
| [06 调研证据](docs/06-research.md) | 官方文档、SDK 检查和参考项目 |
| [07 独立审阅](docs/07-design-review.md) | 三轮审阅、6 项发现的闭环与最终 PASS |

Agent 项目约束见 [AGENTS.md](AGENTS.md)。事故与改进记录见 [Retrospective.md](Retrospective.md)。
