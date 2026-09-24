# 03 · HTTP、MCP 与 Jev

状态：设计契约。官方事实与本地约束分开列明；协议依据见 [06](06-research.md)。

## 上游 Jev 契约

官方推理接口为 `POST https://api.typesafe.ai/v1/systemone`，使用 `Authorization: Bearer <key>`。不是 OpenAI Chat Completions。

请求包含 `state`（string / object / array）、`model`（string）、`questions`（按 question ID 命名的 map）。每题的 `instructions` 可为 string / object / array；不能收窄成纯文本 prompt。Question ID 用于关联响应，不作为模型输入。

| 类型 | 请求 | 响应与展示 |
| --- | --- | --- |
| Choice | `type=choice`；criteria 为 option → string/object/array/null，官方最多 255 项 | `choice`、完整 `probabilities`、`confidence`；突出赢家与前两名 margin，但保留零概率选项 |
| Noul | `type=noul`；可选 criteria 的 `true/false` 定义 | `noul` 是 yes 概率；没有独立 confidence，不自动阈值化成确定布尔值 |
| Score | `type=score`；criteria 为有序描述数组，2–10 级 | `score` 为概率加权等级位置，连同 `legend`、`probabilities`、`confidence`；不是通用 0–100 分 |

响应根包含实际 `model`、按 question ID 对应的 `answers`、`usage.input_tokens/output_tokens`。显示 requested model 和 resolved model，避免 `jev-latest` 升级后历史混淆。上游错误可包括 401、422、429、529；未记录的其他 HTTP 状态同样需正确转发。

首版支持这三种题型，不猜测未知题型。局部验证不应发明官方未声明的 token 限额或固定题数。严格校验已知必需字段、已知字段的类型和大小边界；未知顶层字段及 question 附加字段作为 JSON 原样保留并透传，由上游决定是否支持。官方 SDK 的 `extra_body` 与原始 question 字典扩展不能被本地静默丢弃或先行 422。未知字段不具有 Falcon 路由、鉴权或 profile 覆写权限。

响应成功校验：question ID 集合一致、type 匹配；Choice winner 属于 criteria，probability key 集合一致，值有限且在 [0,1]，总和容差 0.02；confidence 在 [0,1]；Noul 在 [0,1]；Score 的 legend / probabilities 等级对应请求，score 在合法范围。容差仅用于接纳文档示例中的舍入，不重归一化、不修改返回值；非法响应存原文并标记 invalid_response，返回本地 502。usage 缺失或不完整则保留 nullable 并提示协议异常，不制造 token。

## HTTP 表面

全接口仅绑定 `127.0.0.1`，均要求来源 Bearer key，包括 health。默认示例端口 19823；实际以应用设置和 bind 结果为准。

| Endpoint | 行为 |
| --- | --- |
| `GET /health` | 已认证后返回服务状态、API 版本；不返回来源列表、凭据、历史正文；ready 200，否则 503 |
| `POST /v1/systemone` | 接受官方请求体；成功保留上游响应 JSON，不注入额外根字段；`X-Falcon-Request-ID` 关联观察记录 |
| `POST /mcp` | MCP Streamable HTTP，见后文 |
| `GET /mcp`、`DELETE /mcp` | 已认证后 405，`Allow: POST`；首版无 SSE 与 session 删除 |

未知路径 404，已知路径不支持的方法 405；Origin/Host 校验及认证在路由之前。无 CORS，OPTIONS 不开放浏览器跨域。首版不代理 `/v1/models`，不声称支持官方 SDK 的全部资源；只保证 `system_one` 互操作。

HTTP 请求的 `model` 必填；官方 SDK会带默认 model。MCP 可省略 model，使用来源绑定 profile 的默认值，再构造完整上游请求。UI 同时保存收到的输入和实际送出的有效请求；不得将本地 metadata 夹入 state。

可选 `X-Falcon-Agent`、`X-Falcon-Project`、`X-Falcon-Run-ID` 仅用于显示与关联，全部视为不可信字符串，计入 4 KiB metadata 上限。不自动读取进程、工作目录、git 仓库或其他本机信息。无论 metadata 自称谁，账目归属只取 key 的 source ID。

请求只转发允许的 JSON 与固定 `Content-Type`、`Accept`、Falcon User-Agent 和上游 Bearer。调用方 headers、Cookies、内部 key、host、caller metadata 不进入上游。响应只转发 content type、Retry-After 等明确允许的非敏感字段；不转发 Set-Cookie、Authorization 或任意调试 headers。

## 来源与密钥

- 内部 key 使用 256 bit 安全随机值，格式 `falcon_` 加 base64url；创建或轮换时仅显示一次。数据库保存 SHA-256 摘要、后四位和 key ID，验证采用时序安全比较。
- 一个 source 一把 active key；轮换事务立即撤销旧 key，不保留宽限兼容路径。用户重新配置 agent；历史聚合仍按同一 source ID。
- 来源 key 仅允许推理与基本健康查询，不能列举其他来源、读历史、导出、改配置或读取上游 key。
- 上游 key 存 Falcon 专属 Keychain service，profile 只持引用。编辑只能替换，普通界面不提供历史明文查看；不记录到日志、crash metadata、导出或剪贴板配置模板。
- Keychain 拒绝访问时显示具体操作入口，不弹循环授权、不扫描其他条目。设计阶段不执行任何 Keychain 操作。

任何已授权本机进程持有 key 都能冒用该来源；这不是进程身份认证系统。正文可能本来含敏感信息，不能靠自动脱敏承诺“安全原文”；设置页明确完整留存含义，复制/导出由用户显式触发。

## Base URL 与出站安全

配置采用 API root，例如 `https://api.typesafe.ai` 或网关根 `https://gateway.example/api`；规范化尾随 `/`，追加 `/v1/systemone`，预览最终地址。禁止 userinfo、query、fragment 和直接填入 `/v1/systemone` 的歧义值。

正式 profile 只允许 HTTPS，TLS 按系统信任验证，不提供跳过验证选项；本地测试 fixture 独立注入 HTTP transport，不作为产品设置。禁止目标为 Falcon 自己；上游 URL 不能由每次客户端请求覆写。HTTP 重定向一律不跟随，返回明确错误，防止 key 随 redirect 流出。修改目标需要重新输入该目标的 key，不能把旧目标凭据自动带到新 host。

入站 Host 仅接受设置的 `127.0.0.1:port`；客户端有 Origin 时只允许同一显式 origin，其他（含 `null`）返回 403；无 Origin 的 CLI / SDK可用。拒绝 `0.0.0.0` 监听及任何 LAN 地址。客户端请求的本地 HTTP 不携带上游 key。

## MCP 契约

使用官方 Swift SDK 0.12.1 与 2025-11-25 Streamable HTTP 语义。支持 `initialize`、`notifications/initialized`、`ping`、`tools/list`、`tools/call`；声明 tools capability，不声明 resources、prompts、subscriptions 或后台 tasks。

只有一个工具 `jev_decide`：参数以 `{state, questions, model?}` 为已知字段，三类 question 使用 JSON Schema `oneOf`，以 `type` 的 const 区分；根与题级允许附加 JSON 字段，已知必需字段仍严格验证。工具的 arguments 映射为有效上游 JSON，附加字段全部保留；JSON-RPC 的 id/method 等外层协议字段不转发。工具说明强调模型输出不等于执行许可。

成功 `CallToolResult.structuredContent` 为 `{request_id, response}`，response 是上游完整 JSON；`content` 同时带同一对象的 JSON 文本以供客户端读取。`isError=false`，输出 schema 明确这层包装。业务失败返回 `isError=true` 与 `{request_id?, error:{origin, code, message, retryable, outcome_unknown}}`。MCP 协议错误（无效方法/参数）使用 JSON-RPC error；HTTP 认证失败在协议之外返回 401/403，不能假装是工具结果。

正常请求客户端发送 `Accept: application/json, text/event-stream`；服务采用 application/json 响应；notification 返回 202 空体，GET / DELETE 405，不创建 Mcp-Session-Id。initialize 在该 POST 内按 SDK 支持集合协商版本并返回，由客户端保存；后续每个 POST 独立校验 `MCP-Protocol-Version` 是否属于支持集合，不支持则 400。缺少版本头按规范视为 2025-03-26，再按 SDK 支持集合判定。不保存客户端先前协商值，因此不宣称检测了“当前头与该客户端先前协商版本一致”；请求 key 认证与版本支持检查每次都执行。

**并发隔离与生命周期**：SDK 的 stateless transport 以 JSON-RPC id 关联 waiter。不同客户端可能同时使用 id=1，不能共用一个全局 transport。每个 HTTP POST 使用独立 server/transport 上下文（共享只含业务的 DecisionService），显式采用 `Server.Configuration.default`（0.12.1 为 `strict=false`），注册相同工具后处理一次请求，结束或超时必定 disconnect。不得在这种每请求实例模式下开启 strict，否则后续 tools/list、tools/call 会被新实例当成未初始化。来源身份来自该 HTTP 上下文，不用全局 currentSource。

这是有限能力的无状态 MCP server：客户端按标准执行 initialize → initialized → list/call，但服务不跨 POST 保存初始化状态、clientInfo/capabilities 或证明先前已初始化，不发起依赖客户端 capabilities 的请求。来源归属依然由每次 key 决定，metadata 只能逐次自报。首阶段必须用实际标准客户端跑完整跨 POST 序列、两客户端同 id 并发与 disconnect 清理；这是该架构能否进入下一层的退出条件，未通过则修订设计，不留作上线后的已知缺陷。

首版不支持跨 POST 的取消追踪/恢复会话，不宣称处理了客户端断开即取消推理；已有推理直到响应或 30 秒截止，结果仍归入记录。notification cancellation 可被协议接收但属于 best effort，不承诺取消上游。transport 任务超时必须释放 waiter。

来源 key 是本地预配置 Bearer，不实现 OAuth discovery / 授权服务器；支持能配置固定 Authorization header 的 HTTP MCP 客户端。配置页写明这个边界，不宣称兼容所有仅支持 OAuth 或 stdio 的客户端，也不自动安装桥接进程。

## 错误与重试

| 情况 | HTTP | 记录与重试语义 |
| --- | --- | --- |
| key 缺失/错误/撤销 | 401 | 不发上游、不存正文；同一错误文案 |
| Host/Origin 不合法、来源禁用 | 403 | 不发上游；来源禁用可记录安全计数 |
| 无效 JSON / shape | 400 / 422 | 已认证则记录本地 rejected |
| 请求/响应太大 | 413 / 502 | 请求未完整则元数据；响应保留受限诊断并标记超限，不称完整 |
| 不支持 Content-Type / Content-Encoding | 415 | 仅 application/json、identity，请求不解压 |
| 本地并发超限 | 429 | `Retry-After: 1`，origin=falcon；不发上游 |
| 未配置、暂停、凭据不可用 | 503 | origin=falcon；修复后才能接受推理 |
| 上游 4xx/5xx | 原状态 | 保留有界上游 body；X-Falcon-Error-Origin=upstream；不改造成模型答案 |
| 网络错误 / 非法成功响应 | 502 | 原因分类，结果可能未知；不静默重发 |
| 30 秒截止 | 504 | timed_out；上游可能已处理或计费 |
| 审计写入失败 / 容量不足 | 507 | origin=falcon；标明是否已发上游，UI 暂停接收 |

Falcon 本地错误为 `{error:{origin:"falcon",code,message,request_id?,outcome_unknown}}`；error message 不回显 key、完整 URL 凭据或请求正文。request ID 仅在分配后出现。超限拒绝记录也必须有界；存储不足时允许无法记录拒绝，但不继续发送上游。

Falcon 不自动重试，包括 429/529。官方 SDK 默认可能重试，因此接入示例显式使用 `RetryPolicy(max_retries=0)`；外部调用方坚持 retry 时，每一次到达 Falcon 都是独立、可计费的新 request，可用 Run-ID 关联但不做去重。不存在上游 exactly-once 保证。

## 官方 Python SDK接入示例

以下为未来服务的使用方式；当前仓库无可运行服务。实际 key 由用户安全地注入环境，不能提交到文件。

```python
import os
from typesafe_sdk import Choice, RetryPolicy, TypeSafeClient

with TypeSafeClient(
    api_key=os.environ["FALCON_SOURCE_KEY"],
    base_url="http://127.0.0.1:19823",
    model="jev-latest",
    retry=RetryPolicy(max_retries=0),
    timeout=35,
) as client:
    result = client.system_one(
        state={"task": "Review a focused documentation change"},
        questions={
            "execution": Choice(
                instructions="Choose an execution mode for this task.",
                criteria={"local": "One bounded task", "delegate": "Independent subtasks"},
            )
        },
    )
    print(result.choices["execution"].choice)
```

`typesafe-sdk==0.7.1` 的离线 MockTransport 已验证 base URL 拼接、内部 key 格式接受和三类响应解析；真实 HTTP、MCP、URLSession 与上游一致性尚待实施验证，见 [05](05-delivery.md)。

[下一篇：界面与动效](04-interface.md) · [目录](README.md)
