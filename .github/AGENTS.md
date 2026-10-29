<!-- Parent: ../AGENTS.md -->
# GitHub 自动化

这里保存契约、仓库格式、Go 和 macOS 实现的检查配置，以及合并到 `main` 后按根目录 `VERSION` 自动发布预发布版的工作流（`release.yml`）。不添加部署到生产环境、依赖签名/公证等真实凭证的工作流；发布只写 GitHub Release 与 GHCR，只使用 `GITHUB_TOKEN`。

工作流见 `workflows/`；可运行入口以根目录 Makefile 为准。Linux 检查 Go 竞态、vet 和构建；Apple Silicon macOS 检查 Swift Debug/Release 并构建开发签名应用。构建成功不等于真实播放器、权限、正式 WSS 或分发签名验收。
