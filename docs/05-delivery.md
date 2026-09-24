# 05 · 交付与验证

状态：实施计划，不是实施授权。本轮只做文档审阅与提交。

## 分层交付

每层都保留上一层的可运行产品。协议实验放在测试 fixture，不提交一个依赖临时 Python daemon 的过渡应用。具体文件路径是规划，尚不存在。

| 层 | 交付内容 | 主要拟新增文件 | 退出条件 / 原子提交 |
| --- | --- | --- | --- |
| 0 当前 | 产品、架构、协议、视觉、验收、证据与独立审阅 | README、AGENTS、docs | 文档一致、来源可核实、review 无未解决阻断项；`docs: define falcon design` |
| 1 可用闭环 | 真原生窗口、一个来源/上游的正常管理、HTTP → Jev fixture → SQLite → 列表与详情；并在隔离 fixture 中完成 MCP 架构验证 | `Falcon.xcodeproj`、`Package.swift`、`Sources/Falcon/App/`、`Sources/FalconCore/{DecisionService,JevClient,DecisionStore}.swift`、`Tests/FalconCoreTests/`、`Tests/FalconIntegrationTests/` | 真实 HTTP、持久化和 UI 闭环；标准 MCP 客户端跨 POST 的 initialize → initialized → list/call、同 id 并发隔离、disconnect 清理全部通过，缺一不得进入第 2 层；`feat: add native decision proxy` |
| 2 完整接入 | 多来源/profile、轮换/撤销、官方 MCP SDK、官方 Python SDK互操作 | `Sources/FalconCore/{SourceStore,CredentialStore,ProxyServer,MCPAdapter}.swift`、`Tests/FalconIntegrationTests/` | 同 id 并发来源隔离、认证、MCP 初始化与三类结果通过；`feat: add source keys and mcp` |
| 3 完整观察 | 七天清理、来源时间线、宽详情与 Focus review、review、统计、只读历史回放、JSON/CSV 导出 | `Sources/FalconCore/{RetentionPolicy,UsageQueries}.swift`、`Sources/Falcon/Features/{Decisions,Usage,Sources,Connections}/`、`Sources/Falcon/Features/Decisions/ReplayViewModel.swift` | 端到端回看/回放、零出站调用、阶段时点/返回耗时、到期缓存清理及分页/容量边界通过；`feat: add decision review and usage` |
| 4 完成度 | 统一 token、材质、动效、浅深色、无障碍、性能与正式打包 | `Sources/Falcon/Design/`、`Tests/FalconUITests/`、`scripts/`、`docs/evidence/` | 真实截图和交互审阅、资源预算实测、质量 gate 证据；按独立变更继续原子提交 |

UI 主题、大空间 overview 与输入/问题/结果同时可见从第 1 层生效，第 4 层负责全状态精修；不能先交窄详情或互斥 tab 再整套替换。阶段时间事实从第 1 层记录，第 3 层的历史回放直接读取已留存字段。认证、前置审计写入、体积/并发上限、七天隐藏查询和测试隔离也必须在第一条生产请求之前生效；第 3 层扩展并验证其完整管理体验。

第 1 层必须验证 Hummingbird + MCP + GRDB 的兼容构建和 Release 体积，并在隔离测试 fixture 中通过上述完整标准 MCP 客户端序列；这是架构门槛，不是可选提前测试。第 2 层才将已验证的 MCP 适配接入正式应用和来源管理。若门槛失败先修订设计；体积不满足预算则先用链接产物证据定位依赖，不立刻手写 HTTP/MCP 替代成熟实现。

## 准确性优先的测试清单

| 类别 | 必须覆盖的失败或边界 |
| --- | --- |
| Jev 契约 | 三类题、结构化 instructions/criteria、255 Choice、Score 2/10 级、批量独立题、extra_body/附加 question 字段透传、未知/缺失 answer、错误类型、NaN/非法概率、缺 usage、resolved model |
| 代理认证 | 错 key/撤销/禁用、每次请求重新认证、并发更换 URL+key 的整体快照、配置提交失败、旧凭据在途引用回收、不转发内部 key、客户端身份伪报、Host/Origin、redirect 与 key 出站边界 |
| MCP | 标准客户端跨 POST 的 initialize / initialized / ping / list / call 全序列、独立版本头校验、202 notification、GET/DELETE 405、错误映射、同 id 多客户端并发、waiter 清理、显式宽松模式与实例生命周期 |
| HTTP | 每一 endpoint/method；分块/超长 body、错误 Content-Type/Encoding、断开、deadline、并发超额、未配置与 pause |
| 存储 | 写入失败不调用上游、响应写入失败但上游已执行、重启 interrupted、事务原子性、列表游标同时间稳定性、归档/重命名不破坏历史 |
| 留存 | 恰好 168h、三份原文与 questions/reviews 级联、到期详情清空、唤醒清理、清理后统计、WAL checkpoint/页回收、8 个并发请求的容量原子预留/单次释放、满盘不提前删未到期数据、手动清空与迟到回调竞争 |
| 统计 | 请求/题/token 不重复、未知不补零、错误率/上游成功率分母、处理/返回耗时及分母区分、返回写回后元数据更新失败、精确 p95、低样本、跨时区/夏令时、同名不同题指纹不混合 |
| UI | 大小窗口同时核对输入/定义/结果、Focus review 恢复布局、首次配置、第一条请求、筛选与钻取、review 草稿切换、复制/导出、来源轮换/撤销、错误恢复、保留滚动与选中、键盘和 VoiceOver |
| 回放 | 注入时钟、慢速/分块正文完成前不揭示、逐事件与拖动/倍速、并发来源不串行化、多题共用响应时点、零出站调用且 usage/review 不变、未知尾部不跳空档、10,000 条上限、后台暂停、播放/暂停中到期清除正文、休眠唤醒先核验再渲染、清空历史停止回放 |

主要测试使用真实 loopback server 和临时 SQLite；官方 SDK 对本地 fixture 发请求验证互操作，不使用真实 Jev 来提供确定性断言。开发期 Python 依赖锁版本，完全不进入 App bundle。

真实 Jev smoke test 只在用户明确授权后发送固定合成输入，记录使用的模型和 usage；不发送用户任务正文，不把通过几条 smoke test 写成模型准确率证明。

## 6DQ 目标与当前证据

| 维度 | 目标 | 当前状态 |
| --- | --- | --- |
| L1 | UT statements/branches/functions/lines 各 ≥95%；严格类型检查、check-only lint/format 零错误零警告；index snapshot pre-commit 阻断 | planned：无实现、无 hook；Swift/LLVM 的 region 不直接冒充 statement/branch，缺失指标要明确记录并找到可证明测量方案 |
| L2 | 100% 已拥有 endpoint/method 真实本地 HTTP，MCP 互操作与 SQLite 集成 | planned：本轮只有官方 SDK MockTransport 探针，不算 Falcon L2 |
| L3 | 原生关键旅程、截图矩阵、键盘/无障碍验证 | planned：没有 App、没有截图执行结果 |
| G2 | gitleaks + 支持 Package.resolved 的依赖漏洞扫描，工具缺失阻断 | planned：没有锁文件、gate 或扫描执行证据 |
| D1 | 每次运行独立目录/端口/凭据 namespace，fixture/reset/cleanup 前核验 marker | planned：当前仅合成离线 SDK 探针，无生产数据访问 |

目标 pre-commit <30 秒，pre-push <3 分钟；这些是预算，不构成跳过检查的理由。UI 纯视图可交 L3，但 ViewModel、认证、统计和保留策略在 UT 范围内。不能为四项 95% 移除难测业务、隐藏告警或排除错误路径。

测试使用系统分配的 loopback 临时端口、独立数据库目录，设置 `_test_marker(env=test, run_id=...)`，cleanup 检查目录归属与 marker。CredentialStore 使用测试内存实现；确需验证 Keychain 时只使用测试 namespace，并单独授权真实系统交互。测试不能读取日常 Falcon 配置或调用上游。

当前唯一现成仓库命令是 `git diff --check` 与 `git status --short`；实现后从真实 manifest/scripts 录入构建、测试和 lint 命令，不能在文档先编造可执行脚本。

## 小体积与性能验收预算

以下是待实测目标。测量基线为 Apple Silicon、Release arm64、macOS 15+；记录具体机器、OS、数据集、sample 数与测量工具，不写脱离环境的数字。

| 项目 | 初始预算 | 测法 |
| --- | --- | --- |
| 安装体积 | App bundle ≤30 MiB，压缩分发包 ≤15 MiB | 去除 dSYM 后统计实际发布 bundle，传递依赖包含在内 |
| 空闲占用 | 60 秒稳定后 RSS ≤100 MiB，CPU 平均 <1% | 菜单栏运行、窗口关闭与前台静止各测；CPU 相对单核 |
| 首次可交互 | 冷启动 ≤1.5 秒 | 10 次中位数，分别空库/10 万条库，不含首次系统签名检查 |
| 代理本地开销 | p95 ≤25 ms | loopback fixture，8 并发、典型 ≤32 KiB 输入，包含审计持久化；上游等待单独计时 |
| 列表筛选 | p95 ≤100 ms | 10 万 request / 30 万 questions，元数据筛选，不包含正文检索 |
| 全文搜索 | 首批结果 ≤500 ms，可取消 | 七天典型数据集，完整扫描显示进度；不为达标漏掉其他页 |
| 图表 | p95 ≤200 ms | 7 天/10 万条，精确聚合和 percentile；批量刷新不阻塞接入 |
| 交互 | 60 Hz 目标，无 >100 ms 主线程阻塞 | Instruments，概率列表/JSON展开/实时插入/窗口 resize |

测试集应包含短请求、1 MiB 长请求、多题和高选项数。存储预算、7 天量和最大 payload 共同约束可留存量，不能承诺 10 万条每条均为最大请求。超过体积或耗时预算需报告实测差距与原因，由用户评估，不删掉必需安全或审计能力来达标。

## 本轮文档 review 流程

1. 提交完整设计，记录 commit SHA；验证链接、示例 JSON/代码语法、文档一致性。
2. 启动独立 Codex，只读审阅该 SHA：产品覆盖、协议事实、可行性、认证隔离、七天数据生命周期、UI 可执行性、体积、质量证据。
3. Reviewer 按严重性给出位置、问题、触发条件与最小修订建议；必须区分阻断项、非阻断建议、待用户选择。
4. 主控修订并原子提交；将确切新 SHA 送同一 reviewer 复审，直到阻断项清零或诚实报告外部阻碍。
5. 保存中文审阅记录、审阅范围、发现及处理、最终判定；完成后关闭受控 pane，向用户报告设计结论和仍需选择的产品项。

审阅通过仅表示文档可作为下一阶段依据，不等于应用已构建、性能已达标、用户已授权实现。

[下一篇：调研证据](06-research.md) · [目录](README.md)
