# Cloudflare Relay

## 已确认的设计

2026-10-20，用户批准方案 A、Herdr pane 并行、TDD、接入 `nocoo/base-ci`，以及部署到 `falcon.hexly.ai`。

- Swift App 保留根目录布局；无状态 TypeScript Worker 位于 `services/relay/`。
- App 使用已有连接配置选择直连或 relay，不自动切换、重试或缓存推理结果。
- 本地 source key、relay Bearer token、官方 API key 相互独立。Worker 校验 relay token 后用自己的官方 key 发出请求。
- App 凭据继续保存在 `~/.config/falcon/credentials.json`。云端凭据使用 Cloudflare Secrets，不进入 Git、日志或构建产物。
- Worker 仅转发固定官方上游的 `POST /v1/systemone` 和 `GET /v1/models`，保留正文原始字节、HTTP 状态和允许的诊断响应头。
- Worker 自身错误标记 `X-Falcon-Error-Origin: relay`，正文提供 `error.origin/code/message/outcome_unknown`。已发送的推理在网络故障后不能标记为确定未执行。
- 历史、收藏、用量投影及回放继续由 App 本地负责。Worker 不保存请求和响应正文。
- `GET /api/live` 匿名、禁止缓存，报告产品版本、Git SHA 和有时限的模型列表依赖检查；不执行推理。
- `project.yml` 的 `MARKETING_VERSION` 仍是产品版本唯一来源。

## 验证与发布

| 阶段 | 验收条件 | 状态 |
| --- | --- | --- |
| Worker TDD | 先失败后通过；四项覆盖率分别至少 95%；strict types、零警告 lint、check-only format | 已通过 61 项测试；语句 99.05%、分支 97.52%、函数 100%、行 99.04%；独立正确性复审的问题已关闭 |
| App 接入 | 直连和代理配置可用；relay 错误归因及不确定结果真实保留 | 已实现；95 项 Swift 测试及单独官方 SDK 检查通过，独立复审的问题已修复 |
| 本地 HTTPS | Caddy 域名、隔离测试凭据、模拟上游，不访问生产推理 | 已通过 30 项路由／方法／认证检查及官方 SDK 模型／推理检查；用户于 2026-10-20 确认验收并授权 Y+1 发布 |
| CI | 固定 SHA 引用 base-ci；Linux Worker 与 macOS 原生检查；无生产测试凭据 | `4291fe9` 的八项必要任务全部通过；最终发布 SHA 仍须单独核验 |
| CD | 精确成功 CI 来源；生产环境隔离；部署后版本/SHA/live 验证 | 本机 OAuth 首次部署完成；GitHub production 仅允许 main，仍缺专用 CI API token，自动部署尚未实跑 |
| 线上协议 | 正式域名 TLS、live、认证与官方 SDK | 首次部署通过 live、错误 token 401、模型发现与一次零重试真实推理；初次检查使用公共 DNS 地址覆盖本机旧的 NXDOMAIN 缓存，TLS 校验未关闭 |
| 区域可达性 | 从实际受影响网络验证到 Worker，再验证官方推理 | 待验证 |

Workers 的区域 Placement Hints 不是固定国家或 IP 出口保证。普通单元测试、模拟上游和 `/api/live` 成功都不证明所有目标地区能够推理。

本地 nmem 服务当前不可用，旧 L1 报告和端口预约查询失败。现有 Swift L1 缺口不因 Worker 覆盖率达标而消失；不得报告整个仓库通过 L1。

## 连接与错误语义

Connections 中的 Direct / Falcon relay 是已有连接模型的预设，不是另一个配置系统。切换预设会清空输入中的凭据；改变已保存连接的目标必须提供新凭据。现有来源继续绑定 connection ID，不需要更换 Agent 的本地 key。

官方响应保留原始字节与允许的诊断头。Worker 自身错误例如：

```json
{
  "error": {
    "origin": "relay",
    "code": "upstream_timeout",
    "message": "Upstream request timed out",
    "outcome_unknown": true
  }
}
```

HTTP 与 MCP 使用相同的归因和不确定结果语义。若 relay 标记存在但错误正文损坏，App 向客户端返回保守的 `relay_invalid_error`、`outcome_unknown: true`，同时把原始错误正文保留在本地审计记录中。不能根据网络超时推断官方未执行，也不能把 App 的上游计时标成 Worker 内部的官方计时。

## 本地与生产边界

- 本地 Caddy：`https://falcon.dev.hexly.ai` 转发到 `127.0.0.1:7060`，只允许本机连接。复用现有通配符证书，不改证书或 Keychain。
- 原生监听：仍为 `127.0.0.1:19823`，不把本地 HTTP/MCP 暴露给公网。
- 本地 relay：使用 Miniflare、合成 token 与拦截的官方响应；正式官方凭据不参与测试。
- 生产 relay：`https://falcon.hexly.ai`，`RELAY_TOKEN` 和 `TYPESAFE_API_KEY` 使用 Cloudflare Secrets。CI 使用限定范围的 API Token，不复制本机 OAuth 凭据。
- 版本：App、Worker 和 live 响应都从 `project.yml` 的产品版本派生；Worker 同时报告构建的 Git SHA。

Worker 的 `enable_request_signal` 显式配置在生产与测试环境，不能仅凭 compatibility date 推断真实断连信号已启用。当前 compatibility date 为 `2026-10-13`，与锁定的本地 workerd 支持范围一致；升级 runtime 后需一起复测并更新。25 秒代理预算与 5 秒 live 预算都包含限流等待，迟到的限流成功不能再触发官方请求。请求／响应正文上限分别为 1 MiB／4 MiB；限流是每个 Cloudflare 位置的防滥用措施，不是全局精确账单上限。

Worker 覆盖率范围为 `src/**/*.ts`（不含声明文件）。开发 harness 不计入这四项指标，但参与严格静态检查和真实 HTTP smoke。CLI 构建在本机输出 Docker socket 不可用的探测信息；纯 Worker 构建和 HTTP 检查仍成功，本任务未启动 Docker 或引入容器依赖。

CI 使用 `nocoo/base-ci@ac635753a869cb85fad1f52aae4ccbd6119f3cae`（`main 2026-10-22`）。Worker 质量、原生 Swift、Python 辅助脚本与 workflow lint 分开执行；汇总门禁要求相同 SHA 的所有任务成功。CD 暂以 `workflow_dispatch` 触发，输入成功的 main CI run ID 和对应完整 SHA；部署前再次检查 main，部署后核对 live 的状态、版本和 SHA。

生产发布在本地验收确认之后进行。远程 Workflow 运行、正式 Secrets、生产域名/live 和目标区域推理是单独的验收项，不能用本地模拟成功替代。原生 DMG 的个人 Apple Development 签名仍走仓库已有发版流程，不假设 GitHub 托管 runner 能使用本机签名身份。

首次生产部署基于通过 [CI 39369351212](https://github.com/nocoo/falcon/actions/runs/39369351212) 的 `4291fe9ffc20b15b83f79da718907dfa170b3893`。最终发布与部署 revision 以 GitHub Release 证据及线上 live 响应为准。独立 relay token 保留在本机 `~/.config/falcon/relay-token`（0600），供 Connections 导入；本次部署没有修改既有直连 profile、source 映射或历史。CI token 应通过 `~/.config/falcon/cloudflare-api-token`（0600）或 GitHub production 环境 Secret 配置，不得把本机 OAuth 复制到 CI。

## 参考

- [Workers Placement](https://developers.cloudflare.com/workers/configuration/placement/)
- [Workers Vitest](https://developers.cloudflare.com/workers/testing/vitest-integration/)
- [Istanbul 覆盖率限制](https://developers.cloudflare.com/workers/testing/vitest-integration/known-issues/)
- [cf CI](https://developers.cloudflare.com/cf/ci/)
- [base-ci](https://github.com/nocoo/base-ci)
