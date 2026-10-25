<!-- Parent: ../AGENTS.md -->
# GitHub 自动化

这里只保存契约、仓库格式、Go 和 macOS 实现的检查配置，不添加产品发布、部署、自动推送或依赖真实凭证的工作流。

工作流见 `workflows/`；可运行入口以根目录 Makefile 为准。Linux 检查 Go 竞态、vet 和构建；Apple Silicon macOS 15 检查 Swift Debug/Release 并构建开发签名应用。构建成功不等于真实播放器、权限、正式 WSS 或分发签名验收。
