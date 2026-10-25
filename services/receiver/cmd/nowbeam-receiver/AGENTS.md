<!-- Parent: ../AGENTS.md -->
# nowbeam-receiver 入口约定

上层约定：[cmd/AGENTS.md](../AGENTS.md)。

- 先完成配置、数据库锁与初始化检查，再开放监听。
- 直接 TLS 使用系统支持的密码学实现，最低 TLS 1.2；不降低证书校验策略。
- 捕获 SIGINT/SIGTERM，清空瞬态状态、停止接入、等待已升级连接，整个退出有界。
- 日志仅固定安全诊断，不输出原始 error、请求头、URL、SQL 或消息正文。
