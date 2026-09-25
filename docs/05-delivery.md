# 05 · 交付与验证

状态：用户已授权实施，首版已建立原生应用、代理、持久化、来源管理、统计和回放。以下区分当前实现、已运行检查和仍待验证的目标。

## 分层交付

每层都保留上一层的可运行产品。协议实验放在测试 fixture，不提交一个依赖临时 Python daemon 的过渡应用。下表对应当前仓库文件，性能与完整质量门禁仍按后文单独验收。

| 层 | 当前实现 | 主要文件 | 状态 |
| --- | --- | --- | --- |
| 0 设计 | 产品、架构、协议、视觉、回放与独立审阅 | `docs/01` 至 `docs/08` | 两次独立设计审阅 PASS，精确版本见 [07](07-design-review.md) |
| 1 可用闭环 | 原生窗口、HTTP/MCP → 合成 Jev → SQLite → 列表/详情 | `Sources/Falcon/App/`、`Sources/FalconCore/Proxy/`、`Persistence/DecisionStore.swift` | 已实现；真实 loopback 集成测试覆盖正式 MCP 初始化与调用序列 |
| 2 完整接入 | 多来源与多上游、来源 key 轮换/撤销、文件凭据、配置快照、官方 SDK 互操作 | `Sources/FalconCore/Configuration/`、`Tests/FalconIntegrationTests/ProxyIntegrationTests.swift`、`scripts/check-sdk.sh` | 已实现；生产 API 仍需独立验证 |
| 3 完整观察 | 七天清理、宽幅详情、Focus review、统计、review、回放与导出 | `Sources/FalconCore/Presentation/`、`Sources/Falcon/Features/` | 已实现；大数据性能与完整人工旅程仍待验收 |
| 4 原生完成度 | 统一颜色/字体、细纹理、浅深色、加载、动效与本地打包 | `Sources/Falcon/Design/FalconTheme.swift`、`scripts/build-app.sh`、`project.yml` | 已有合成数据截图与本地 Release 构建；完整 VoiceOver/性能矩阵及签名公证未完成 |

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
| 留存 | 未加星恰好 168h、星标跨七天保持完整列表/详情/预览/统计/回放/导出、取消超时星标、三份原文与 questions/reviews 级联、到期详情清空、唤醒清理、清理后统计、WAL checkpoint/页回收、8 个并发请求的容量原子预留/单次释放、满盘不提前删未到期或星标数据、手动清空与迟到回调竞争 |
| 统计 | 请求/题/token 不重复、未知不补零、错误率/上游成功率分母、处理/返回耗时及分母区分、返回写回后元数据更新失败、精确 p95、低样本、跨时区/夏令时、同名不同题指纹不混合 |
| UI | 大小窗口同时核对输入/定义/结果、Focus review 恢复布局、首次配置、第一条请求、筛选与钻取、review 草稿切换、复制/导出、来源轮换/撤销、错误恢复、保留滚动与选中、键盘和 VoiceOver |
| 回放 | 注入时钟、慢速/分块正文完成前不揭示、逐事件与拖动/倍速、并发来源不串行化、多题共用响应时点、零出站调用且 usage/review 不变、未知尾部不跳空档、10,000 条上限、后台暂停、播放/暂停中到期清除正文、休眠唤醒先核验再渲染、清空历史停止回放 |

主要测试使用真实 loopback server 和临时 SQLite；官方 SDK 对本地 fixture 发请求验证互操作，不使用真实 Jev 来提供确定性断言。开发期 Python 依赖锁版本，完全不进入 App bundle。

真实 Jev smoke test 只在用户明确授权后发送固定合成输入，记录使用的模型和 usage；不发送用户任务正文，不把通过几条 smoke test 写成模型准确率证明。

## 6DQ 目标与当前证据

| 维度 | 目标 | 当前状态 |
| --- | --- | --- |
| L1 | UT statements/branches/functions/lines 各 ≥95%；严格类型检查、check-only lint/format 零错误零警告；index snapshot pre-commit 阻断 | 测试与严格 lint/format 已有执行入口。四项覆盖率未达标；LLVM branch 为 0/0，不作为测量，region 不冒充 statement。没有安装提交 hook，详细审计保存在 nmem |
| L2 | 100% 所拥有 endpoint/method 真实本地 HTTP，MCP 互操作与 SQLite 集成 | 已有真实 loopback tests、官方 MCP 客户端及 opt-in Python SDK 检查；外部磁盘耗尽/WAL 写入故障与跨进程锁未注入 |
| L3 | 原生关键旅程、截图矩阵、键盘/无障碍验证 | 已检查浅/深色、Focus、小窗口、空状态、回放和 Usage 合成截图；尚无自动化 UI journey suite、完整 VoiceOver 与真实休眠矩阵 |
| G2 | gitleaks + 支持 Package.resolved 的依赖漏洞扫描，工具缺失阻断 | Package.resolved 已锁定依赖；没有自动扫描/推送 gate 的通过证据 |
| D1 | 每次运行独立目录/端口/凭据 namespace，fixture/reset/cleanup 前核验 marker | 存储及传输测试采用每次独立目录、系统分配端口、内存或隔离文件凭据；数据库写入和清理使用 run UUID marker；Preview 同样隔离 |

目标 pre-commit <30 秒，pre-push <3 分钟；这些是预算，不构成跳过检查的理由。UI 纯视图可交 L3，但 ViewModel、认证、统计和保留策略在 UT 范围内。不能为四项 95% 移除难测业务、隐藏告警或排除错误路径。

测试使用系统分配的 loopback 临时端口、独立数据库目录，设置 `_test_marker(run_id=...)`，cleanup 检查目录归属与 marker。CredentialVault 使用测试内存实现或每次独立的临时凭据文件；文件测试覆盖权限、并发更新、损坏拒绝、写入失败与轮换后的重启读取。测试不能读取日常 Falcon 配置或调用上游。

当前检查命令：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --enable-code-coverage
scripts/check-sdk.sh
swiftlint lint --strict
xcrun swift-format lint --strict --recursive Sources Tests
scripts/build-app.sh Release
git diff --check
```

完整 Swift 测试与 opt-in Python SDK 需分别记录。后者会覆盖 SwiftPM coverage 输出，统计全量覆盖率前先保存完整测试报告。AppRuntime 位于应用 target，不能将整个 `Sources/Falcon` 宣称为纯 View 的 UT 豁免。

## 本次运行证据

执行日期为 2026-09-25，机器为 Apple M5 Max，macOS 27.0（26A428），Xcode 27 / Swift 6.4，SwiftLint 0.65.1。以下测试与 Release 对应源码版本 `bddbf9b`，使用临时数据库、内存凭据和合成上游。

| 检查 | 实际结果 |
| --- | --- |
| 完整 Swift 测试 | Core 34 项、Integration 18 项通过；默认跳过 1 项 opt-in Python SDK 用例。命令退出 0，复用构建缓存共 14.72 秒 |
| 官方 Python SDK | `typesafe-sdk==0.7.1` 经真实 Falcon loopback 完成 1 项互操作测试，退出 0；含准备与构建共 17.65 秒 |
| 严格静态检查 | SwiftLint strict 与 swift-format strict 均退出 0，无 lint/format findings；Swift 6 完整并发检查随构建完成 |
| 原生界面 | Release 合成数据检查浅色、深色、Usage、Focus、回放、小窗口和空状态；7 个 App 捕获进程均退出 0 并生成截图，部分快速退出出现系统 InputMethodKit 诊断，保留在运行日志中 |
| Release 打包 | arm64 bundle 13,855,472 bytes（13.21 MiB），压缩 ZIP 5,515,997 bytes（5.26 MiB）；47.57 秒构建成功，Xcode 有一条未使用 AppIntents 的 metadata 提示 |

上述 53 项实际通过的测试不等于完整 L1 达标。全量 Swift 套件对 FalconCore 的行覆盖率为 92.12%（3672/3986），函数覆盖率为 88.30%（619/701）；statement 无测量值，branch 输出 0/0 不可用。这是 Core 与 Integration 共同执行的结果，不是单独 UT 四项达标证明。完整审计保存在 nmem `6dq-audit-github.com-nocoo-falcon-l1`。

Release 已核验无 LLVM coverage sections、无打包进入 App 的 lint 配置；SwiftPM 测试继续显式采集覆盖率。体积仅指当前本机 arm64 开发构建，不包含 dSYM，也不是 universal 或已公证的分发包。

### 2026-09-25 文件凭据变更验证

上游凭据改为 `~/.config/falcon/credentials.json` 后，完整 Swift 回归通过 Core 40 项、Integration 18 项，默认跳过 1 项 opt-in Python SDK 用例。新增文件测试覆盖保存与重开、`0700` / `0600` 权限、32 个并发更新、4 类损坏内容、符号链接拒绝、目录不可写时保留原 profile，以及轮换后重启和孤立凭据回收。测试均使用独立临时目录与合成 key，没有访问真实凭据。

Release 构建、SwiftLint strict、swift-format strict、Markdown 本地链接与 Git whitespace 检查通过。此变更直接移除 Keychain 后端；首次真实启动进入 Connections，真实 Jev 调用由用户填写配置后发起。以上回归结果不改变完整 L1 尚未达标的状态。

### 2026-09-25 图标、triage、星标与生命周期验证

本轮实现代码为 `dd87f03`，包含预览数据库退出修复 `09f42b9` 与代理即时重启修复 `44c3d7a`。菜单栏符号来自 Workflow GPT Image，harness 资源保留 Manifest 原图、来源 revision 与许可；运行时仍为纯 Swift，版本保持 0.1.0。

| 检查 | 实际结果 |
| --- | --- |
| 完整 Swift 测试 | `swift test --enable-code-coverage` 退出 0，Core 56 项、Integration 20 项通过；1 项 opt-in Python SDK 用例跳过 |
| 存储与观察 | 覆盖星标跨到期的完整证据、统一查询/回放/导出、取消超时星标、在途更新保留星标、连续 triage、监听时退出、关闭后迟到刷新、重新打开及锁所有权 |
| 代理重启 | 旧实现的隔离 fixture 复现同端口重绑 `Address already in use`；修复后立即重启与拒绝第二个运行中 listener 两项回归通过 |
| 严格静态检查 | SwiftLint strict 在 53 个文件中无违规，swift-format strict 无输出，均退出 0 |
| 最终原生界面 | 创建来源、首次编辑已有来源、浅色新请求到达、深色决策页共 4 个隔离 preview 均退出 0，4.27–4.85 秒完成并生成截图，应用日志为空 |
| 编辑与视觉 | 编辑首帧包含原名称、连接、启用状态、已选图标和 Save changes；创建仍为 Unknown。已检查深蓝主按钮、明亮旗标和列表/详情图标，实时到达断言通过 |
| SQLite 退出诊断 | 按上述 4 个 preview 的精确 PID 查询系统日志，无 SQLite、I/O 或文件使用中删除诊断；此前同场景的错误已由隔离 GRDB fixture 复现 |
| Release 与真实重启 | arm64 bundle 15,565,275 bytes（14.84 MiB），构建成功。正常退出并重开后认证 health 为 ready / 0.1.0，SQLite quick_check 为 ok，原有请求、连接、来源、来源 key 标识全部保留，两份凭据文件摘要不变 |

此前还检查了紧凑深色、来源选择器与 Usage 图表。Usage 仍输出 Charts 的轴尺寸诊断；Release 保留未使用 AppIntents 的 metadata 提示。上述证据不代表完整 L1 或 L3 达标，本轮没有更新四项覆盖率结论，也没有执行签名、公证、发布或推送。

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

## 已执行的设计 review 流程

1. 提交完整设计，记录 commit SHA；验证链接、示例 JSON/代码语法、文档一致性。
2. 启动独立 Codex，只读审阅该 SHA：产品覆盖、协议事实、可行性、认证隔离、七天数据生命周期、UI 可执行性、体积、质量证据。
3. Reviewer 按严重性给出位置、问题、触发条件与最小修订建议；必须区分阻断项、非阻断建议、待用户选择。
4. 主控修订并原子提交；将确切新 SHA 送同一 reviewer 复审，直到阻断项清零或诚实报告外部阻碍。
5. 保存中文审阅记录、审阅范围、发现及处理、最终判定；完成后关闭受控 pane，向用户报告设计结论和仍需选择的产品项。

设计审阅通过仅归属于对应文档版本。随后用户明确授权了实施；应用实现、运行验证与性能证据单独记录，不能从文档 PASS 推导。

[下一篇：调研证据](06-research.md) · [目录](README.md)
