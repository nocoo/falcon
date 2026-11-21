<p align="center"><img src="logo.png" width="128" alt="Falcon logo" /></p>
<h1 align="center">Falcon</h1>
<p align="center">macOS 原生 Jev HTTP / MCP 代理与七天决策观察应用。</p>
<p align="center"><a href="docs/README.en.md">English</a></p>

## 这是什么

Falcon 是面向本机 AI Agent 开发者的 macOS 原生 Jev HTTP / MCP 代理与决策观察应用。每个来源使用独立的本地 key，可以映射到同一个或不同的上游连接（直连 TypeSafe 官方接口或通过自有 Cloudflare Worker relay 转发）。

应用将 SwiftUI、AppKit、Swift Charts 与 Swift 服务运行在同一进程中，绑定本机回环地址 `127.0.0.1:19823`。仓库同时包含位于 [`services/relay/`](services/relay/) 的可选 Cloudflare Worker relay，原生应用不依赖 Node 或 Python 运行时。

## 功能

- **宽幅决策工作区**：同屏展示 `state`、问题定义、选项与决策结果；**Focus review** 可收起导航与列表，**Usage** 支持点击图表钻取延迟与 token 统计。
- **回看与导出**：支持来源图标（默认 `Unknown`，可在列表点击编辑）、来源与时间筛选、全文检索、一键 triage（**Review & next** `⌘Return`）、独立旗标与备注、本地只读阶段回放（不会再次调用 Jev，也不表示 Agent 已执行决策）以及 JSON / CSV 导出。
- **分层留存策略**：未加星记录在本机保留 168 小时（7 天）；加星记录（`⇧⌘S` 或右键菜单）永久保留完整证据。超过七天的记录取消星标将在确认后删除；设置中的清空历史会一并清除星标。
- **官方 SDK 与 MCP 兼容**：提供 `POST /v1/systemone`、`GET /v1/models`（从上游动态返回，不写历史或 token 统计）以及基于 Streamable HTTP 的 `/mcp`（暴露 `jev_decide` 工具）。
- **可选 Relay 转发**：[`services/relay/`](services/relay/) 仅开放 `POST /v1/systemone`、`GET /v1/models` 与匿名 `GET /api/live`，固定上游为 `https://api.typesafe.ai`（使用 Cloudflare Secret）。Worker 不保存决策、不缓存结果、不自动重试；自身故障标记 `X-Falcon-Error-Origin: relay`，在途失败返回 `outcome_unknown: true`。
- **隔离凭据存储**：官方 API key 或 relay token 明文保存在 `~/.config/falcon/credentials.json`（目录 `0700`、文件 `0600`、原子写入，不使用 Keychain）；本地来源 key 仅持久化 SHA-256 摘要；历史数据默认存于 `~/Library/Application Support/Falcon`。

## 使用

需要 macOS 15+ 与 Apple Silicon（`arm64`）。

### 1. 安装或构建

从 [GitHub Releases](https://github.com/nocoo/falcon/releases) 下载 DMG 与 `.sha256` 校验文件：

```sh
shasum -a 256 -c Falcon-0.2.0-arm64.dmg.sha256
```

打开 DMG 将 Falcon 拖入 Applications。v0.2.0 使用个人 Apple Development 签名且未经 Apple 公证；若确认校验通过但被 macOS 拦截，可仅移除下载隔离属性（不能替代公证或修复损坏签名）：

```sh
xattr -dr com.apple.quarantine /Applications/Falcon.app
open /Applications/Falcon.app
```

或从源码执行本地 Release 构建：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/build-app.sh Release
open build/Build/Products/Release/Falcon.app
```

无需上游凭据即可使用合成数据预览界面（独立临时数据库、不监听端口、不读写真实凭据）：

```sh
open build/Build/Products/Release/Falcon.app --args --preview --dark
```

### 2. 初始化与接入

1. 首次启动进入 **Connections**：选择 **Direct**（`https://api.typesafe.ai`）填写 TypeSafe API key，或选择 **Falcon relay**（预设 `https://falcon.hexly.ai`）填写自有 relay 的 Bearer token。切换预设会清空输入中的凭据。
2. 在 **Sources** 创建来源、绑定 connection 与图标，复制仅显示一次的本地 key。
3. 将 Agent 的 API root 指向 `http://127.0.0.1:19823` 并使用该来源 key（关闭窗口后服务继续驻留菜单栏，Quit 退出）。

HTTP 调用示例（官方 SDK 可通过 `TYPESAFE_BASE_URL` / `TYPESAFE_API_KEY` 环境变量或 `base_url` / `api_key` 接入，建议设置 `RetryPolicy(max_retries=0)` 与 `timeout=35` 避免重复推理）：

```sh
curl http://127.0.0.1:19823/v1/systemone \
  -H "Authorization: Bearer $FALCON_SOURCE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"jev-latest","state":"Review an isolated change","questions":{"execution":{"type":"choice","instructions":"Choose how to proceed.","criteria":{"local":"Enough context for a bounded task.","inspect":"Important evidence is missing."}}}}'
```

MCP 客户端配置示例：

```json
{
  "mcpServers": {
    "falcon": {
      "url": "http://127.0.0.1:19823/mcp",
      "headers": {
        "Authorization": "Bearer YOUR_SOURCE_KEY"
      }
    }
  }
}
```

## 开发

- **原生 Swift**：需要 macOS 15+、Xcode（当前验证环境为 Xcode 27 / Swift 6.4，[`project.yml`](project.yml) 指定 `SWIFT_VERSION: "6.0"`）与 XcodeGen。版本号唯一维护源为 [`project.yml`](project.yml) 的 `MARKETING_VERSION`（`0.2.0`）；界面显示 `vX.Y.Z`，`/health` 与 MCP `serverInfo.version` 返回 `X.Y.Z`。
- **Relay Worker**：位于 [`services/relay/`](services/relay/)，需要 Bun 1.4.3 与 Node（`^22.18.0 || ^24.0.0 || >=26.0.0`）。

```sh
# 原生应用构建
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
scripts/build-app.sh Release

# Relay Worker 本地开发（监听 127.0.0.1:7060，通过 https://falcon.dev.hexly.ai 访问）
cd services/relay
bun install --frozen-lockfile
bun run build
bun run dev
```

在 `services/relay` 下执行 `bun install --frozen-lockfile` 会通过 `prepare` 安装 Husky 钩子（也可运行 `scripts/relay-bootstrap-hooks.sh`），在提交时对暂存区快照离线执行 Worker `typecheck`、`lint` 与 `test:coverage`。若使用临时镜像，请保持同一 `BUN_CONFIG_REGISTRY` 环境变量运行 bootstrap（仅写入仓库 Git 配置 `falcon.relayRegistry`，不修改全局配置或 lockfile）。本地模拟环境使用合成 token `harness-relay-token` 与模拟上游，不得用于生产。

## 测试

原生 Swift 检查（使用临时 SQLite、内存或隔离文件凭据及 loopback fixture；`scripts/check-sdk.sh` 通过 `uv` 运行锁定的 `typesafe-sdk==0.7.1`，默认 `swift test` 不触发）：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --enable-code-coverage
scripts/check-sdk.sh
swiftlint lint --strict
xcrun swift-format lint --strict --recursive Sources Tests
git diff --check
```

Relay Worker 与脚本契约检查：

```sh
cd services/relay
bun run typecheck
bun run lint
bun run test:coverage
bun run test:http
```

```sh
# 根目录脚本契约测试
bash -n scripts/relay-bootstrap-hooks.sh .husky/pre-commit && for t in scripts/relay-*.test.py; do python3 "$t"; done
```

Worker 满足四项 95% 覆盖率门槛与 CI 门禁；原生 Swift 95% 覆盖率门槛与自动提交门禁仍在规划中，生产 Jev、完整无障碍矩阵与大数据性能存在验证边界，详见 [交付与验证](docs/05-delivery.md)。

## 技术栈

| 模块 | 技术选型 | 职责 |
| --- | --- | --- |
| 原生应用 | Swift 6、SwiftUI、AppKit、Swift Charts | macOS 15+ 桌面界面、菜单栏驻留与统计图表 |
| 本地服务与存储 | Hummingbird 2.27.0、MCP Swift SDK 0.12.1、GRDB.swift 7.11.1 | HTTP / MCP 代理、SQLite 持久化与留存清理 |
| 工程构建 | SwiftPM、XcodeGen（[`project.yml`](project.yml)） | 依赖管理与 `arm64` 应用打包 |
| Relay Worker | Cloudflare Workers、`cf` CLI、TypeScript、Vitest、Biome、Husky | 可选上游转发、隔离测试 harness 与提交门禁 |

## 文档

- [设计目录](docs/README.md) · [产品设计](docs/01-product.md) · [架构与数据](docs/02-architecture.md) · [HTTP / MCP 契约](docs/03-protocol.md)
- [界面设计](docs/04-interface.md) · [交付与验证](docs/05-delivery.md) · [独立设计审阅](docs/07-design-review.md) · [回看与回放](docs/08-review-playback.md)
- [Relay 设计](docs/09-relay.md) · [macOS 发版流程](docs/10-macos-release.md) · [变更记录](CHANGELOG.md)
- [Agent 约束](AGENTS.md) · [事故复盘](Retrospective.md) · [Harness 图标许可](assets/harness/README.md) · [Brand 资产说明](assets/brand/README.md)

## 许可证

本仓库基于 [MIT License](LICENSE) 发布，Copyright (c) 2026 Zheng Li。
