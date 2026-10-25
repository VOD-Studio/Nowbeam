<!-- Parent: ../AGENTS.md -->
# 命令入口约定

上层约定：[Receiver AGENTS.md](../AGENTS.md)。

- 只包含服务进程入口，不把 Nowbeam 原生产品改造成 CLI 管理工具。
- 入口负责配置、依赖组装、监听与退出，不放协议或设备业务逻辑。
- 不添加启动时自动公开、自动签发设备或输出 secret 的便利路径。
