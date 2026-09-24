# 事故与改进记录

本文件记录本项目实际发生的事故、原因和后续防范措施。

稳定项目约束维护在 [AGENTS.md](AGENTS.md)，架构与设计维护在 [docs](docs/README.md)。

## 2026-09-25：独立审阅的启动与布局检查

- **经过**：第一次独立 Codex 审阅进程启动成功，但实际推理返回 `service_tier is not supported`，没有产生审阅结论。设置审阅 pane 时，按外层布局推断 resize 的作用范围，短暂把主控列调得过窄，随后恢复为左侧三分之一。
- **原因**：进程 ready 不代表首个模型请求已成功；嵌套 split 的 resize 操作作用于相邻分隔线，不能按整个窗口比例推断。一次 `--current` resize 返回了其他活动窗口的上下文且 `changed=false`，后续全部使用已核实的显式 pane ID。
- **防范**：必须读取首轮实际输出，不能把 idle/done 当作 review 通过；服务等级调整只作用于受控进程，不改全局配置。调整布局前读取 layout，操作后核验返回的 pane ID、changed 和几何位置，保留已有用户 pane。
