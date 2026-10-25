# Nowbeam 独立接收服务

这是可选、自托管的 Nowbeam v1 接收端，不是客户端必经中转，也没有 Web 管理后台。原生软件可以直接同时连接它和其他兼容接收端。服务只保存实例配置、设备名称及凭证校验值；当前活动和连接代次只在内存中，退出或重启后不恢复。

上层约定见 [services/AGENTS.md](../AGENTS.md)，产品边界见 [产品规格](../../docs/product.md)，线上消息以 [协议与关闭码](../../protocol/README.md) 和 [Schema](../../protocol/v1/message.schema.json) 为准。

## 构建与本机启动

需要 Go 1.26 或后续受支持版本。以下命令从仓库根目录开始：

```sh
make build-receiver
cd services/receiver
```

根目录 target 等价于在 `services/receiver/` 执行 `go build -trimpath -o bin/nowbeam-receiver ./cmd/nowbeam-receiver`。接下来的本机启动命令在此目录执行；原生客户端构建与启动另见[根 README](../../README.md#构建与启动原生软件)。

首次部署先在仓库以外的私人目录创建初始化凭证，不把凭证填入命令参数、URL、Git 或截图。例如：

```sh
mkdir -m 700 -p "$HOME/.config/nowbeam-receiver"
(umask 077; openssl rand -hex 32 > "$HOME/.config/nowbeam-receiver/bootstrap")
NOWBEAM_BOOTSTRAP_TOKEN_FILE="$HOME/.config/nowbeam-receiver/bootstrap" bin/nowbeam-receiver
```

默认仅监听 `127.0.0.1:8787`，数据库放在当前目录 `data/nowbeam.sqlite`。这是本机开发或可信反向代理上游，不是公网明文部署。新建数据库所在目录为 `0700`，数据库和锁文件为 `0600`；已有数据库目录必须已经是私人目录，否则拒绝启动。拒绝同一数据库的第二个进程，以及数据库/锁文件符号链接。

本机 Debug 客户端需在“来源与隐私”显式开启仅限回环的明文开发选项，再以 `http://127.0.0.1:8787` 管理、`ws://127.0.0.1:8787/api/v1/ingest` 上报；`::1` 同样允许，但需让服务监听对应地址。Release 不接受这些明文地址，必须先部署系统信任的 HTTPS/WSS。不要通过全局关闭证书检查或修改系统信任来跳过验证。

### 配置

| 环境变量 | 默认值 / 含义 |
| --- | --- |
| `NOWBEAM_LISTEN_ADDR` | `127.0.0.1:8787`；只有操作者显式设置才绑定其他地址 |
| `NOWBEAM_DATABASE_PATH` | `data/nowbeam.sqlite`；应位于专用、可写、权限 `0700` 的目录 |
| `NOWBEAM_BOOTSTRAP_TOKEN_FILE` | 可选初始化凭证文件；允许末尾换行，最多 512 个可打印 ASCII 字符 |
| `NOWBEAM_BOOTSTRAP_TOKEN` | `_FILE` 的替代方式，二者不能同时设置；至少 32 个高熵随机字符，推荐密码学随机 32 字节以上 |
| `NOWBEAM_TLS_CERT_FILE` | 直接 TLS 的证书链 PEM，与私钥一起设置 |
| `NOWBEAM_TLS_KEY_FILE` | 直接 TLS 的私钥 PEM，与证书一起设置 |

初始化凭证只在数据库尚未初始化时必需；初始化后可移除环境变量和文件配置。服务不把它保留为登录凭证：数据库只保留独立生成的所有者令牌 SHA-256 校验值，内存中的初始化校验值也在成功后清空。已初始化实例的 setup 始终返回 `409 already_initialized`。不要丢失原生软件 Keychain 中的所有者凭证；本版没有通过旧初始化凭证恢复所有者身份的后门。

环境配置和底层失败仅输出固定安全错误标识，不记录活动正文、标题、曲目、凭证、认证头或数据库错误内容。启动失败时检查配置配对、私人目录权限、数据库占用与证书可读性；不要开启请求体日志排错。

## TLS 与反向代理

正式原生客户端只接受 HTTPS 管理入口与 WSS 上报入口。直接 TLS 运行时设置证书链和私钥；只接受 TLS 1.2 及以上，WebSocket 使用 HTTP/1.1。

也可以让维护者已经配置好的可信反向代理终结 TLS，将 `/api/v1/` 和 `/healthz` 原样转发到回环上游。代理必须：

- 正确转发 HTTP/1.1 `Upgrade`、`Connection` 和 `Sec-WebSocket-Protocol`；
- 保留 `Authorization`，不把它写入访问日志，也不记录请求体；
- 使用受系统信任的证书，不要求客户端关闭证书验证；
- 上游只在回环或受保护私有网络内可见；不要公开裸露 8787 明文端口；
- WebSocket 空闲超时大于 45 秒，建议至少 90 秒；不缓冲 WebSocket 消息。

普通 HTTP 请求有首部、读写和空闲期限；升级后的连接由 10 秒首次快照期限、45 秒租约和有限写入期限管理，不用 HTTP 写入超时截断健康长连接。SIGTERM/SIGINT 会清除内存投影并在总计 10 秒内结束 HTTP 和已升级连接；容器给予 12 秒退出宽限。

## 容器与两个独立实例

仓库根目录是 Docker build context。镜像从源码构建，不依赖任何声称已经发布的 Nowbeam 镜像。镜像使用非 root 用户、无 shell 的 scratch 运行层，SQLite 不需要 CGO。

```sh
docker build -f services/receiver/Dockerfile -t nowbeam-receiver:local .
```

Compose 默认只把容器端口发布到宿主回环。Docker Compose 的本地文件 secret 通常仍沿用源文件模式；为使容器用户 65532 可读，初始化文件可设为 `0444`，但其宿主父目录必须保持 `0700`，且始终放在仓库外：

```sh
chmod 0444 "$HOME/.config/nowbeam-receiver/bootstrap"
export NOWBEAM_BOOTSTRAP_SECRET_FILE="$HOME/.config/nowbeam-receiver/bootstrap"
docker compose -p nowbeam-one -f services/receiver/compose.yaml up --build -d
```

这个模式下文件只挂载进接收容器，不进入构建上下文、镜像或数据库。保留 Compose secret 配置时文件必须仍存在，即使 setup 已完成；若要移除部署凭证，同时删去部署配置中的 `_FILE` 环境项与 secret 挂载，不能只删源文件。

第二实例使用不同的 Compose project、初始化文件和宿主端口，例如 `-p nowbeam-two` 与 `NOWBEAM_HOST_PORT=8788`。两个 project 的命名卷独立，各自在原生软件里初始化、签发设备凭证和设置公开权限。不要共享 SQLite 文件或使用多个副本；文件锁不把单进程状态机变成高可用集群。升级/备份前正常停止该实例，然后备份私人数据目录；活动没有备份或历史恢复语义。

## 原生软件内管理

1. 在 Nowbeam 设置“接收服务管理”点击“连接服务…”，输入本地名称和 HTTPS 实例地址；新实例勾选“这是尚未初始化的新实例”，填写部署时生成的初始化凭证。已有实例使用所有者管理凭证，不再走 setup。
2. 软件调用一次 setup，将仅返回一次的独立所有者令牌保存到 Keychain。可用“复制管理凭证”安全备份；若初始化成功但本地保存失败，先备份界面暂存的凭证，不要试图再次初始化。复制到剪贴板后注意其他应用可能读取。
3. 在“授权设备”填写公开名称并“签发设备凭证”。设备令牌只返回一次，可“添加到本机接收端，暂不启用”；软件以返回的 `/api/v1/ingest` 创建独立目的地，不要求手工复制自己的设备令牌。给其他设备签发时需安全传递凭证。
4. 在“接收端”检查连接：只接收 welcome 后关闭，不接管已有设备、不上传活动。添加或替换目的地不会自动启用；启用目标并检查“分享与预览”后，还需明确恢复整体分享。每次客户端启动都再次暂停，已启用连接可发送空快照保持在线。
5. 所有者在“公开读取”显式开启“允许匿名读取当前状态”并保存、确认后，外部消费者才可访问。上报授权和公开授权相互独立；浏览器 Origin 按需逐条精确填写。
6. 撤销设备时持久删除凭证，立即清空活动并关闭同设备所有候选/当前连接。重新授权需要新设备凭证。

设备名称是所有者明确输入的展示名称，不自动使用 Mac 主机名。限制 128 个 Unicode 码点，修剪首尾空白，拒绝空白名称、控制字符和不可见格式控制。设备身份是接收端独立随机 UUID v4，不是跨站或硬件标识。

## 管理与读取 HTTP API

全部 JSON 路由返回 `Cache-Control: no-store`，错误只含稳定 `{"code":"..."}`。带正文的请求使用 `Content-Type: application/json`，上限 16 KiB，拒绝未知字段、重复键、错误大小写、缺字段与不符合约定的 null。路由不接受查询参数。Cookie 不参与认证，令牌只放 `Authorization: Bearer ...`。

| 方法与路径 | 权限 | 成功结果 |
| --- | --- | --- |
| `GET /healthz` | 无 | `200 {"status":"ok"}`，不披露配置 |
| `POST /api/v1/setup`，正文 `{}` | 一次性初始化凭证 | `201 {"ownerToken":"..."}` |
| `GET /api/v1/admin/settings` | 所有者 | `{"publicReadEnabled":false,"allowedOrigins":[]}` |
| `PUT /api/v1/admin/settings` | 所有者 | 必须提交上述两个字段，返回更新值 |
| `GET /api/v1/admin/devices` | 所有者 | `{"devices":[{"id":"...","displayName":"...","createdAt":"..."}]}` |
| `POST /api/v1/admin/devices`，正文 `{"displayName":"..."}` | 所有者 | `201 {"device":{...},"token":"...","ingestPath":"/api/v1/ingest"}` |
| `DELETE /api/v1/admin/devices/{id}` | 所有者 | `204`；不存在返回 `404` |
| `GET /api/v1/presence` | 已开启匿名读取，或所有者诊断 | 按设备返回当前投影 |
| `OPTIONS /api/v1/presence` | CORS 预检 | 精确匹配允许 Origin 后返回 `204`，不代表已获得读取权限 |
| `GET /api/v1/ingest` | 单设备凭证 | WebSocket Upgrade，必须 `nowbeam.v1` |

CORS 只在 presence 路由支持 GET/OPTIONS，允许 Origin 为精确的 `http(s)://host[:port]`，不能有路径、凭证、通配符、query 或 fragment。默认列表为空，完全拒绝带 Origin 的浏览器读取；无 Origin 的服务端消费者仍按公开权限鉴权。CORS 不限制已经获准匿名读取的非浏览器消费者，不能当访问控制。原生 WebSocket 上报一律拒绝 Origin；读取 CORS 配置不会授予浏览器上报权限。

### 当前状态与媒体锚点

presence 返回 `generatedAt` 和 `devices` 数组。每项只包含 `deviceId`、`displayName`、`online`、`updatedAt`、`expiresAt`、完整 `sources`；不返回连接 ID、凭证校验值、客户端 observedAt、进程或采集原始对象。

- `online: true` 只表示当前租约有效，三个来源均为空也可在线。
- `updatedAt` 是最后新接受快照的服务端接收时间；存在媒体时，它也是 `positionMs` 的播放位置时间锚点，不使用客户端墙钟。
- `expiresAt = updatedAt + 45 秒`。播放且位置、速率已知时，消费者可基于该锚点有限推进，且不得超过可靠时长；暂停、位置未知或速率未知时不要虚构进度。
- 过期、断开后的设备仍可列出，但 `online` 为 false，两个时间和全部来源均为 null。撤销设备完全从数组移除。
- 读取路径同步过滤过期内容，调度器也主动清除并关闭过期连接。过期连接不能通过迟到快照复活；必须新握手。
- 同序号同语义快照只返回原 ACK，不续租。键顺序、JSON 空白与等值数字表示不影响指纹；同序号改写或乱序关闭连接。
- 每台设备独立，不选主、不合并、不保留历史。消费者同样必须在到期后停止展示，不能永久缓存状态。

## 目录与维护

- `cmd/nowbeam-receiver`：环境组装、监听、TLS 和退出；
- `internal/config`：配置与 secret 文件输入；
- `internal/wire`：严格 JSON、完整 Schema 字段与媒体跨字段约束、规范化指纹；
- `internal/storage`：仅配置、设备、令牌 SHA-256 校验值的 SQLite 存储；
- `internal/presence`：同一临界区内授权/注册/撤销、候选接管、序号、租约和投影；
- `internal/httpapi`：HTTPS 管理、CORS、WSS 适配；
- `scripts/collect-licenses.sh`：构建产物保留 Go 和依赖的原始再分发声明。

维护检查由集成负责人统一执行；以下是复现入口，不表示每次文档修改都已运行：

```sh
# 仓库根目录
make test-receiver
make build-receiver
```

`make test-receiver` 在 Go module 内运行 `go test -race ./...` 与 `go vet ./...`。需要格式化实现代码时，在 `services/receiver/` 执行 `gofmt -w cmd internal`，不要把格式化当成行为验证。

已有本机证据：Go 竞态测试、vet 和上述二进制构建通过；两个隔离接收进程实际运行，鉴权、一次性初始化、设备不能管理、公开默认关闭及精确 Origin 生效。真实 45 秒租约观测到同序重复快照不续租，到期清空，另一实例用新快照保活仍在线；welcome 不接管、旧 close 不清新状态、旧连接无法复活、同序冲突/跳号关闭和撤销 `4001` 移除均有真实链路记录。新增真实 TLS socket 回归覆盖不完整帧、撤销、接管及服务退出。

测试还覆盖严格字段/空值/重复键、数字和 Unicode、首次期限、撤销注册竞争、重启、真实 httptest HTTPS/WSS、TLS 不受信任及超大分片消息。测试中受控 TLS 信任不等于系统信任下的正式 WSS 部署已验收。

原生 Debug `.app` 的双目的地 ACK、暂停空快照、停止一个目标不重连另一个、原生菜单退出，以及所有者 Keychain/管理界面已观察。Swift 客户端已在实际容器上完成初始化、签发设备和快照 ACK；Keychain 保存/读取/删除通过。不可信 WSS 证书被原生客户端拒绝，未改变系统信任。Linux/ARM64 scratch 镜像及 Compose 已实际运行，UID 65532、只读根文件系统、capabilities 清空和 no-new-privileges 生效；带有合成活动的容器被强制终止再启动，授权持久化，活动、时间戳和租约不恢复，初始化仍不可重开。

macOS 27 解锁桌面的真实采集、锁屏清空与解锁恢复已实测（详见[产品验收记录](../../docs/product.md#当前证据与未验收项)）；网易云音乐、辅助功能窗口标题、AX 权限授予/撤销、延迟 p95、macOS 15、正式反向代理/系统信任 TLS 部署、Developer ID 签名及公证仍有缺口。已构建的 `.app` / DMG 是 ad-hoc 开发产物，不是已发布或公证的正式包。

## 依赖与分发

`go.mod` / `go.sum` 固定实际解析的依赖版本，不使用分支 tip：

- [github.com/coder/websocket v1.8.15](https://github.com/coder/websocket/tree/v1.8.15)，ISC；只使用明确子协议、上下文和完整消息限制，关闭压缩。
- [modernc.org/sqlite v1.61.0](https://pkg.go.dev/modernc.org/sqlite@v1.61.0)，Go 包为 BSD-3-Clause；上游还附 SQLite、sqlite-vec 及其他嵌入组件声明，分发时必须一并保留，不能把整个 Go 模块简单标成 SQLite 公有领域。
- 构建镜像固定到已解析的 Go 1.26.5 Alpine 多平台摘要；这不是“最新安全补丁”的声明，发布时应按维护策略升级并重新验收。

Docker 构建自动把所有锁定依赖的顶层 `LICENSE*` / `COPYING*` / `NOTICE*`（包括 SQLite 的第三方声明）和 Go 运行库声明放入镜像 `/licenses`。单独分发二进制时运行 `sh scripts/collect-licenses.sh <随包许可目录>` 并一同交付。此处不替 Nowbeam 项目指定许可证或声明已获发布授权。
