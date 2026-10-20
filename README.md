# Falcon

<img src="assets/brand/icon-rounded.png" width="128" height="128" alt="Falcon">

**让本机 Agent 的 Jev 决策看得见。**

Falcon 是 macOS 原生 Jev HTTP / MCP 代理与七天决策观察应用。每个来源使用独立本地 key，可以映射同一个或不同的上游。SwiftUI、AppKit、Swift Charts 与 Swift 服务运行在同一进程中。

仓库同时包含可选的 Cloudflare Worker relay：App 可以直连 TypeSafe，也可以通过自有 Worker 转发。Swift 包仍在根目录，Worker 独立位于 [`services/relay/`](services/relay/)，无需为原生 App 安装 Node 依赖。

宽幅工作区同时展示 state、定义、问题、选项和决策；支持来源图标、来源与时间筛选、全文检索、一键 triage、备注、真实阶段回放、延迟与 token 统计、JSON / CSV 导出。普通记录保留七天，加星记录永久保留完整证据，每次新请求仍然调用 Jev。

## 运行

需要 macOS 15+、Xcode 与 XcodeGen。当前验证工具链为 Xcode 27 / Swift 6.4；运行时不依赖 Python 或 Node。

```sh
scripts/build-app.sh Release
open build/Build/Products/Release/Falcon.app
```

脚本仅构建 arm64（Apple Silicon），产物位于 `build/Build/Products/Release/Falcon.app`。这是本地开发构建。

v0.1.7 是供个人使用的 macOS 15+、Apple Silicon 专用 DMG，不支持 Intel Mac，采用自己账户的 Apple Development 签名，未经过 Apple 公证。从 [GitHub Releases](https://github.com/nocoo/falcon/releases) 下载 DMG 和同名 `.sha256`，在下载目录执行：

```sh
shasum -a 256 -c Falcon-0.1.7-arm64.dmg.sha256
```

打开 DMG，将 Falcon 拖入 Applications。若确认下载可信且校验通过，但 macOS 因未公证阻止打开，可仅移除 Falcon 的下载隔离属性：

```sh
xattr -dr com.apple.quarantine /Applications/Falcon.app
open /Applications/Falcon.app
```

此命令不会完成公证，也不能修复损坏的签名。签名及标准发版步骤见 [AGENTS.md](AGENTS.md#standard-macos-release-procedure)。

版本只在 [project.yml](project.yml) 的 `MARKETING_VERSION` 中维护；侧栏、设置、关于面板和服务元信息读取同一构建版本。界面使用 `vX.Y.Z`，HTTP `/health` 与 MCP `serverInfo.version` 返回 `X.Y.Z`。变更记录见 [CHANGELOG.md](CHANGELOG.md)。

1. 首次真实启动自动进入 **Connections**。选择 **Direct**，填写 TypeSafe API key；或选择 **Falcon relay**，填写自有 relay 的 Bearer token。官方 root 是 `https://api.typesafe.ai`，relay 预设为 `https://falcon.hexly.ai`。切换预设会清空正在输入的凭据，避免把官方 key 发给 relay。
2. 在 **Sources** 创建来源、选择 connection 和图标，复制仅显示一次的本地 key。图标默认 Unknown，可选择 Codex、Grok、Claude Code 等；点击现有来源图标即可编辑。
3. 将 Agent 的 API root 指向 `http://127.0.0.1:19823`，Bearer token 使用该来源的本地 key。
4. 发起决策后，在 **Decisions** 回看；**Focus review** 可收起导航与列表，**Usage** 可点击图表钻取。

关闭窗口后服务继续在菜单栏运行。Quit 退出应用；登录启动默认关闭。修改端口后需同步更新客户端配置。

无需上游凭据即可查看合成数据：

```sh
open build/Build/Products/Release/Falcon.app --args --preview --dark
```

Preview 使用独立临时数据库，不监听端口、不读取真实凭据文件、不调用上游。退出后校验测试 marker 并清理。正常启动不加 `--preview`，只显示真实历史；没有请求时列表为空。

## 接入

本地 HTTP 使用 TypeSafe 的 API 路径、JSON 请求/响应和 Bearer 认证。官方 SDK 无需替换；只将 `base_url` 改为 `http://127.0.0.1:19823`，`api_key` 改为 Sources 创建的本地 key，不向 Agent 提供上游 key。Sources 页面并列列出推理、模型发现与 MCP，并提供 SDK / MCP 配置模板。

| 接口 | 官方 SDK / 格式 |
| --- | --- |
| `POST /v1/systemone` | `client.system_one(...)`；三类问题及上游完整响应 |
| `GET /v1/models` | `client.models.list()`；`{"models":[{"name":"...","description":"...","release_date":"YYYY-MM-DD"}]}` |

模型和别名从当前来源绑定的上游返回，不在 Falcon 硬编码；模型查询不产生决策记录或 token 统计。SDK 也支持 `TYPESAFE_BASE_URL` 与 `TYPESAFE_API_KEY` 环境变量。SDK 默认重试可能重复推理，建议显式设置 `RetryPolicy(max_retries=0)` 和 `timeout=35`；这两项是运行建议，不是额外认证要求。完整示例见 [协议说明](docs/03-protocol.md#官方-python-sdk接入示例)。

以下示例从环境变量读取已经配置的来源 key：

```sh
curl http://127.0.0.1:19823/v1/systemone \
  -H "Authorization: Bearer $FALCON_SOURCE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"jev-latest","state":"Review an isolated change","questions":{"execution":{"type":"choice","instructions":"Choose how to proceed.","criteria":{"local":"Enough context for a bounded task.","inspect":"Important evidence is missing."}}}}'
```

MCP 使用 Streamable HTTP、JSON response 和 `jev_decide` 工具；客户端须支持固定 Authorization header：

```json
{
  "mcpServers": {
    "falcon": {
      "url": "http://127.0.0.1:19823/mcp",
      "headers": {"Authorization": "Bearer YOUR_SOURCE_KEY"}
    }
  }
}
```

连接凭据（官方 key 或 relay token）明文保存在 `~/.config/falcon/credentials.json`，文件由 Connections 自动维护，目录权限 `0700`、文件权限 `0600`，采用原子写入。应用不使用 Keychain。本地来源 key 只持久化摘要。未加星的请求和响应在本机保留 168 小时；加星后永久保留，可从列表的星标入口查看全部时间。超过七天的记录取消星标会删除，操作前确认；设置中的清空历史也包含星标。数据默认明文存储于当前用户的 Application Support/Falcon，导出文件由用户管理。回放不会再次请求 Jev，也不表示 Agent 已执行了决策。

详情底部的 **Review & next**（⌘Return）保存当前备注、标记已阅并打开下一条未阅。旗标和备注独立操作；详情工具栏的星标（⇧⌘S）及列表右键菜单控制永久留存。来源图标的出处与许可见 [harness assets](assets/harness/README.md)，菜单栏符号见 [brand assets](assets/brand/README.md)。

## 可选 Relay

```text
Agent --local source key--> Falcon App --official key--> TypeSafe
                                     \--relay token--> Worker --official key--> TypeSafe
```

Worker 只开放 `POST /v1/systemone`、`GET /v1/models` 和匿名 `GET /api/live`，固定上游为 `https://api.typesafe.ai`。官方 key 保存在 Cloudflare Secret，调用方不能指定转发目标。Worker 不保存决策、不缓存结果、不自动重试；本地 HTTP/MCP、来源权限、历史和收藏仍属于 App。

代理自身故障会明确标记 `origin: relay`；已发送请求后发生网络故障时，`outcome_unknown: true` 表示官方可能已经执行，不应自动重试。回放中的上游阶段是 App 的观测，不是 Worker 到官方的内部时间线。

目标生产域名为 `https://falcon.hexly.ai`，本地验收域名为 `https://falcon.dev.hexly.ai`。本地模拟环境使用独立测试 token 和模拟官方响应，不读取生产凭据。部署与区域可达性仍需分别验证；Cloudflare Worker 并不保证固定国家出口。实现与验收状态见 [Relay 设计](docs/09-relay.md)。

Relay 功能目前属于待发布的开发版本；已发布的 v0.1.7 DMG 不包含新的连接预设。生产域名仍待上线验收。

## 开发验证

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --enable-code-coverage
scripts/check-sdk.sh
swiftlint lint --strict
xcrun swift-format lint --strict --recursive Sources Tests
git diff --check
```

测试使用临时 SQLite、内存或隔离文件凭据与真实 loopback fixture。SDK 检查通过 `uv` 运行锁定的官方 `typesafe-sdk==0.7.1`，只在开发期使用。默认 Swift 测试不执行该 opt-in Python 用例。

Worker 开发需要 Bun 1.4.3 和 Node；依赖及 `cf` 版本由独立 lockfile 固定：

```sh
cd services/relay
bun install --frozen-lockfile --ignore-scripts
bun run typecheck
bun run lint
bun run test:coverage
bun run test:http
```

`test:http` 构建 Worker 后，在临时 loopback 端口运行真实 HTTP 检查，官方上游被模拟。`bun run dev` 重新构建并启动同一隔离环境，默认端口 7060；本机通过 Caddy 的 HTTPS 域名访问。该环境的合成 token 为 `harness-relay-token`，不能用于生产。

从仓库根目录运行 `scripts/relay-bootstrap-hooks.sh` 安装 Husky。提交时在独立临时目录中检查 Git 暂存快照，离线安装锁定依赖，执行 Worker types、lint 和覆盖率；不会把未暂存的修复当作提交内容。需要先完成依赖安装以准备本机 Bun 缓存。

若安装依赖时使用了临时镜像，请用同一个 `BUN_CONFIG_REGISTRY` 环境变量运行 bootstrap。它仅在本仓库 Git 配置 `falcon.relayRegistry` 中记录离线缓存的命名空间，不修改全局 Bun 配置或 lockfile；门禁仍禁止联网安装。

Worker 的四项 95% 覆盖率目标与提交门禁独立于原生 Swift。Swift 完整四项覆盖率与自动提交门禁尚未达标；生产 Jev、完整无障碍矩阵和大数据性能仍有验证边界。已执行证据与预算见 [交付与验证](docs/05-delivery.md) 和 [Relay 设计](docs/09-relay.md)。

## 文档

[设计目录](docs/README.md) · [架构与数据](docs/02-architecture.md) · [HTTP / MCP 契约](docs/03-protocol.md) · [界面设计](docs/04-interface.md) · [回看与回放](docs/08-review-playback.md) · [独立设计审阅](docs/07-design-review.md)

Agent 项目约束见 [AGENTS.md](AGENTS.md)，事故记录见 [Retrospective.md](Retrospective.md)。
