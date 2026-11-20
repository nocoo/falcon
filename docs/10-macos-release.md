# 10 · macOS 发版流程

本文档记录 Falcon 原生 macOS 应用的权威发版、签名、验证与安装步骤。发版（推 tag、创建 GitHub Release、部署 Worker 或覆盖本机 `/Applications/Falcon.app`）必须获得明确任务授权。

## 1. 发布物契约与版本来源

- 每个正式版本必须在对应的 GitHub Release 上同时附带 `arm64` DMG 与同名 `.sha256` 校验文件；仅有 tag、源码归档、本地构建或单独上传 `.app` 均不算完成发版。
- 绝不覆盖已发布的 Release 资产；发现问题必须递增版本重新发布。
- [project.yml](../project.yml) 中的 `MARKETING_VERSION` 是唯一权威产品版本（`X.Y.Z`）。XcodeGen 将其同步到生成的 Xcode 工程与 `CFBundleShortVersionString`，`services/relay` 构建亦直接读取该字段。
- `AppRuntime` 读取 bundle 版本：侧栏、Settings 与原生 About 面板展示 `vX.Y.Z`；认证后的 `/health` 与 MCP `serverInfo.version` 返回 `X.Y.Z`。
- `CURRENT_PROJECT_VERSION` 是原生 build number；HTTP `api_version` 与 MCP 协议版本为独立契约。未打包的 SwiftPM 可执行文件标识为开发构建，不冒称发布版本。
- 发版前对照上一正式版本（首次发版对照初始开发版本），更新 `MARKETING_VERSION`、递增 `CURRENT_PROJECT_VERSION`、重新运行 XcodeGen 同步工程，并更新根目录 [CHANGELOG.md](../CHANGELOG.md)。

## 2. 签名路由（个人 Apple Development）

- 仅作横向参考，不作为分发信任证明：Gecko 本地安装版使用 Apple Development；Lyre 发版脚本要求 Developer ID（早期安装产物可能为 ad-hoc）。
- Falcon 使用个人免费 Apple Development 签名：Xcode 自动签名，Team `93WWLTN9XU`。
- `xcodebuild -allowProvisioningUpdates` 可在本地 `codesign` 查无身份时自动从已登录的 Xcode 账户拉取托管签名身份与配置；不要将本地空身份列表视为账户无法签名的证据。
- 本流程不宣称 Developer ID 或 Apple 公证（notarization）。绝不静默回退到 ad-hoc 签名，绝不读取无关 Keychain 内容或修改 Keychain ACL。

## 3. 发版前检查

在仓库根目录执行：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --enable-code-coverage
CODECOV_PATH="$(swift test --show-codecov-path)"
# 先保存全量覆盖率输出，再运行 opt-in SDK 检查（后者会覆盖 SwiftPM 覆盖率目录）
scripts/check-sdk.sh
swiftlint lint --strict
xcrun swift-format lint --strict --recursive Sources Tests
git diff --check
```

- 现有的门禁缺口（原生 Swift L1 覆盖率、G2 依赖扫描、自动化 UI L4 旅程等）必须如实披露，不得将发版描述为通过了不存在的门禁。

## 4. 构建 DMG 与本地核验

运行打包脚本：

```sh
scripts/build-dmg.sh
```

脚本行为与约束：

- 仅以 Release 配置构建 `arm64`（Apple Silicon），启用 Xcode 自动签名（Team `93WWLTN9XU`、`-allowProvisioningUpdates`），拒绝非 `arm64` 可执行文件。
- 调用 `scripts/check-app-icon.sh` 核对最终 `Info.plist` 中的 `CFBundleIconFile=Falcon`（由 `Config/Info.plist` 提供）及打包 `Falcon.icns` 与源文件逐字节一致；仅配置 Xcode build setting 不足以证明 Finder 识别图标。
- 执行 `codesign --verify --deep --strict`，生成 `build/Falcon-X.Y.Z-arm64.dmg`（含 `Falcon.app` 与 `/Applications` 链接）及同级 `.sha256`；脚本拒绝覆盖同名既有 DMG。
- 使用 `ULMO`（LZMA）压缩格式（macOS 10.15+ 支持，兼容本应用 macOS 15+ 最低版本；压缩只减小下载体积，不改变安装后体积）。不执行公证。

打包完成后必须进行只读挂载核验：

1. 只读挂载 `build/Falcon-X.Y.Z-arm64.dmg`。
2. 核对 DMG 内 `Falcon.app` 的代码签名、bundle 版本与 build number、可执行文件架构及资源内容。
3. 逐字节对比 DMG 内可执行文件与 `build/Build/Products/Release/Falcon.app` 产物，然后卸载（detach）镜像。
4. 在浅色与深色两种外观下按实际 `18 pt` 尺寸检查菜单栏图标，确认 template 行为与视觉对齐无偏移。

## 5. 推送与创建 GitHub Release

1. 显式暂存发版改动路径，经正常 Git hooks 提交并推送发版 commit。
2. 在精确同一 revision 创建并推送 tag `vX.Y.Z`。
3. 使用 `gh release create` 上传 DMG、`.sha256` 与 `--notes-file`；重试前必须先核查远端 tags 与 releases，避免重复或覆盖。

Release notes 必须包含：

- 本版本变更摘要
- macOS 15+ / Apple Silicon（`arm64`）运行要求
- 实际签名与公证状态（Apple Development 个人签名，未公证）
- SHA-256 校验方法
- 安装步骤及下方限定范围的 Gatekeeper 隔离解除命令

对已核验 SHA-256 的可信下载，若 macOS 因未公证阻止启动，在将应用拖入 `/Applications` 后文档只提供以下精确命令：

```sh
xattr -dr com.apple.quarantine /Applications/Falcon.app
open /Applications/Falcon.app
```

- 必须说明该命令仅清除 Falcon 的下载隔离属性，既不完成公证也不修复无效签名；执行前必须先校验 `.sha256`。
- 绝不建议关闭全局 Gatekeeper、对 `/Applications` 递归操作或对损坏的下载包重新签名。

## 6. 发布后核验与本机安装

1. 核对已发布 tag 指向的精确 SHA、Release 资产名称/体积及下载后的 SHA-256。
2. 检查该精确 revision 在 GitHub Actions 的运行结果（若仍处于 pending，约 5 分钟后复查）；工作流定义或本地通过均不能替代远端 CI 成功。
3. 发版完成后按授权更新本机安装：正常退出既有 Falcon，将已核验 DMG 中的 `Falcon.app` 复制到 `/Applications/Falcon.app`，核验已安装签名与版本，不带 `--preview` 启动。
4. 确认保留既有用户配置与决策历史，并核验运行中进程的可执行文件路径为 `/Applications/Falcon.app/...`；绝不把构建目录中的 `--preview` 进程当作已安装正式版。

[返回目录](README.md) · [交付与验证](05-delivery.md)
