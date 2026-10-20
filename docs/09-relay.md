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
| Worker TDD | 先失败后通过；四项覆盖率分别至少 95%；strict types、零警告 lint、check-only format | 进行中 |
| App 接入 | 直连和代理配置可用；relay 错误归因及不确定结果真实保留 | 进行中 |
| 本地 HTTPS | Caddy 域名、隔离测试凭据、模拟上游，不访问生产推理 | 待验证 |
| CI | 固定 SHA 引用 base-ci；Linux Worker 与 macOS 原生检查；无生产测试凭据 | 进行中 |
| CD | 精确成功 CI 来源；生产环境隔离；部署后版本/SHA/live 验证 | 待验证 |
| 区域可达性 | 从实际受影响网络验证到 Worker，再验证官方推理 | 待验证 |

Workers 的区域 Placement Hints 不是固定国家或 IP 出口保证。普通单元测试、模拟上游和 `/api/live` 成功都不证明所有目标地区能够推理。

本地 nmem 服务当前不可用，旧 L1 报告和端口预约查询失败。现有 Swift L1 缺口不因 Worker 覆盖率达标而消失；不得报告整个仓库通过 L1。

## 参考

- [Workers Placement](https://developers.cloudflare.com/workers/configuration/placement/)
- [Workers Vitest](https://developers.cloudflare.com/workers/testing/vitest-integration/)
- [Istanbul 覆盖率限制](https://developers.cloudflare.com/workers/testing/vitest-integration/known-issues/)
- [cf CI](https://developers.cloudflare.com/cf/ci/)
- [base-ci](https://github.com/nocoo/base-ci)
