<!-- Parent: ../AGENTS.md -->
# 校验工作流

- `check.yml` 保留 `make setup` / `make check`；独立 Go job 执行 `make test-receiver`（竞态测试及 vet）和 `make build-receiver`，Go 版本读取 `services/receiver/go.mod`。
- 默认权限仅 `contents: read`；外部 Action 固定到已核实的完整提交，不使用未固定分支。
- macOS job 使用官方标准 `macos-15` ARM64 runner，以 `DEVELOPER_DIR` 选择镜像已有的 Xcode 16.4，不修改全局 `xcode-select`。执行 Swift Debug/Release 测试和 `make app-debug` / `make app`；构建前明确检查 ARM64，不能悄悄产出 x86 应用。
- macOS 打包工具由 `make setup` 安装到 `.venv`；不使用 runner 自带的其他版本 CMake。只做默认 ad-hoc 开发签名，不添加公证凭证或发布步骤。
- 不执行 PR 提供的特权发布任务，不配置部署凭证，不加入占位 build/test 步骤。
- 本地检查通过不等于 GitHub 上的工作流已经运行；交付时分开说明。

## 官方来源

- Runner 标签与架构：[GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)；macOS 15 工具链与 Xcode 路径：[官方镜像清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md)。
- Action v6 完整提交通过官方仓库 API 核对：[checkout](https://api.github.com/repos/actions/checkout/git/ref/tags/v6)、[setup-python](https://api.github.com/repos/actions/setup-python/git/ref/tags/v6)、[setup-go](https://api.github.com/repos/actions/setup-go/git/ref/tags/v6)。更新时重新核实具体提交，而不是只改注释版本。
