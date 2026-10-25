<!-- Parent: ../AGENTS.md -->
# Receiver 维护约定

上层约定：[services/AGENTS.md](../AGENTS.md)。运行和 API 说明：[README.md](README.md)。

- 独立 Go module；依赖必须在 `go.mod` / `go.sum` 锁定。使用标准库 HTTP、coder/websocket 和 modernc SQLite，不增加通用框架层。
- 持久数据仅为配置、设备名称、创建时间、凭证校验值。活动快照、序号、连接 ID 与租约只存在内存。
- `httpapi` 适配 HTTP/WSS，`presence` 统一原子状态和授权，`storage` 管理持久化，`wire` 负责完整协议校验；入口手工组装。
- 协议拒绝路径必须先于任何状态修改；未知字段、缺失字段、null、重复键、Unicode、UTC、精确数字都不可宽松化。
- 撤销和候选注册共用临界区；候选欢迎不能接管；失效、替换、撤销后的连接永不复活；旧关闭不能清除新状态。
- 不把错误底层文本、请求、令牌、标题或曲目写入日志。设备令牌与所有者令牌不可互换。
- Docker build context 为仓库根目录；非 root 运行，公网 TLS，保留依赖再分发声明。不替项目指定许可证。
- 完成编辑后交由集成负责人统一运行 `gofmt -w cmd internal`、`go test -race ./...`、`go vet ./...`、`go build ./cmd/nowbeam-receiver`；仅报告实际执行结果。
