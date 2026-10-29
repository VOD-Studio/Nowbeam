<!-- Parent: ../AGENTS.md -->
# 校验工作流

- `check.yml` 保留 `make setup` / `make check`；独立 Go job 执行 `make test-receiver`（竞态测试及 vet）和 `make build-receiver`，Go 版本读取 `services/receiver/go.mod`。
- 默认权限仅 `contents: read`；外部 Action 固定到已核实的完整提交，不使用未固定分支。
- macOS job 使用 `xcode-27` runner（actionlint 的内置标签表不认识它，但仓库的真实运行已证实可用），以 `DEVELOPER_DIR` 选择镜像里最新的 Xcode，不修改全局 `xcode-select`。执行 Swift Debug/Release 测试和 `make app-debug` / `make app`；构建前明确检查 ARM64，不能悄悄产出 x86 应用。
- macOS 打包工具由 `make setup` 安装到 `.venv`；不使用 runner 自带的其他版本 CMake。`check.yml` 只做默认 ad-hoc 开发签名，不含发布步骤。
- `release.yml`：只由 `vX.Y.Z` 标签（且提交必须在 `main` 上）触发发布，`workflow_dispatch` 只构建不发布。产物：ad-hoc 签名、未公证的客户端 DMG、linux/amd64 与 linux/arm64 接收服务二进制（附第三方许可）、推送到 GHCR 的多平台镜像、`SHA256SUMS`，Release 一律标记为预发布。权限按作业最小化：仅 `release` 作业有 `contents: write`，仅 `image` 作业有 `packages: write`。Developer ID 签名与公证需要维护者提供身份和凭据，且要先验证 hardened runtime 下 perl 宿主加载媒体框架仍可用，因此尚未接入，不要用占位步骤假装已有。
- 不执行 PR 提供的特权发布任务，不配置部署凭证，不加入占位 build/test 步骤。
- 本地检查通过不等于 GitHub 上的工作流已经运行；交付时分开说明。

## 官方来源

- Runner 标签与架构：[GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)；macOS 15 工具链与 Xcode 路径：[官方镜像清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md)。
- Action v6 完整提交通过官方仓库 API 核对：[checkout](https://api.github.com/repos/actions/checkout/git/ref/tags/v6)、[setup-python](https://api.github.com/repos/actions/setup-python/git/ref/tags/v6)、[setup-go](https://api.github.com/repos/actions/setup-go/git/ref/tags/v6)。更新时重新核实具体提交，而不是只改注释版本。
