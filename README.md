# Nowbeam

隐私优先的原生桌面状态上报软件。客户端将用户明确允许分享的当前活动，通过通用 WebSocket 协议直接发送给一个或多个接收端，不绑定任何网站或博客系统。

## 当前交付状态

仓库已包含 Swift 6 原生 macOS 菜单栏软件、独立的应用/窗口/媒体采集与隐私投影、多目的地连接、原生接收服务管理，以及可选 Go 接收服务。已有真实 Debug `.app` 启动、双接收端连接与 ACK、暂停后空快照保活和所有者管理的本机证据；**这不是正式发布或全部验收完成的声明**。
本机验证环境为 macOS 27 / Apple Silicon。真实链路已贯通：解锁桌面下前台应用与 QQ 音乐媒体经接收端快照确认，锁屏清空、空快照保活与解锁恢复已实测；验收中发现并修复了会话判定与 AppKit 自动终止两个缺陷。仍未验收：网易云音乐（未安装）、辅助功能授权下的窗口标题、macOS 15 实机、系统信任的正式 WSS 部署、Developer ID 签名及公证。完整边界见下文及[产品验收](docs/product.md#7-首版验收标准)。

## 首版产品

- macOS 菜单栏软件与设置窗口，使用 Swift 6、SwiftUI / AppKit；首批支持目标为 macOS 15+、Apple Silicon。
- 前台应用、窗口标题和媒体是独立来源。媒体首版验收包含 QQ 音乐、网易云音乐，不要求任何时刻存在音乐。
- 窗口标题默认关闭，启用后按应用白名单；在本地完成隐私过滤并预览后分享。
- 多个接收端分别配置地址、凭证与启停，使用 WSS + JSON，子协议 `nowbeam.v1`。
- 接收方按通用协议接入。可选的 Nowbeam 独立接收服务是一个自托管实现，**不是必经中转**。
- 接收服务为单所有者、多设备，公开读取需显式开启，状态按设备返回。展示端自行接入，不提供网站卡片或独立展示页。
- 用户操作放在原生软件内，不另做 Web 管理后台；命令行仅用于开发和可选服务的部署。

## 文档入口

| 文件 | 内容 |
| --- | --- |
| [AGENTS.md](AGENTS.md) | AI 协作约定、不可误解的产品边界与验证要求 |
| [CONTEXT.md](CONTEXT.md) | 领域术语，尤其是来源、在线、公开状态和接收端的区别 |
| [docs/product.md](docs/product.md) | 首版完整范围、隐私及生命周期规则、验收标准 |
| [docs/architecture.md](docs/architecture.md) | 技术裁定、目录组织、独立接收服务与采集约束 |
| [protocol/README.md](protocol/README.md) | WSS 握手、消息、租约、连接替换及消费者规则 |
| [protocol/v1/message.schema.json](protocol/v1/message.schema.json) | JSON Schema 2020-12 消息结构契约 |
| [protocol/v1/examples.json](protocol/v1/examples.json) | 可校验的虚构协议消息示例 |
| [services/receiver/README.md](services/receiver/README.md) | 可选服务构建、启动、TLS、原生管理操作与 HTTP API |

## 构建与启动原生软件

开发构建需要 Apple Silicon Mac、macOS 15+、提供 Swift 6 的 Xcode/命令行工具、Python 3.11+ 和 `make`。首次构建需联网下载固定版本媒体依赖。Python 与项目内 CMake 仅是开发工具，终端用户不需要安装 Homebrew、Python、CMake 或 Swift 编译器；媒体运行使用系统 `/usr/bin/perl`。

在仓库根目录执行：

```sh
make setup
make app-debug
open dist/Nowbeam.app
```

`make setup` 将校验工具及 macOS 构建所需的 CMake 安装到本仓库 `.venv/`，不改全局配置。`make app-debug` 构建包含媒体资源的 `dist/Nowbeam.app`，默认使用 `local.nowbeam.development` 标识和 ad-hoc 开发签名，不生成 DMG。

```sh
make app
```

`make app` 构建 Release 应用及 `dist/Nowbeam.dmg`，同样默认 ad-hoc、未公证。两种构建共用并替换 `dist/Nowbeam.app`。底层入口为 [scripts/build_macos.py](scripts/build_macos.py)，可通过 `APP_ARGS` 传入 `--bundle-id`、`--sign-identity`、`--skip-dmg` 等参数。只有维护者授权的标识和签名身份才可用于正式签名；脚本不执行公证或发布。不要通过关闭 Gatekeeper、SIP 或系统证书校验来运行。

### 原生界面操作

1. 启动后从菜单栏打开设置。**每次启动整体分享都暂停**，并非只在首次安装时暂停；已保存的来源和目的地配置不等于授权自动恢复活动分享。
2. 在“来源与隐私”按需开启应用、窗口或媒体。窗口默认关闭，必须另行添加应用白名单并由用户授予辅助功能权限；隐藏应用同时禁止读取它的窗口标题。媒体与应用来源独立。
3. 在“接收端”添加完整 `wss://` 地址与该接收方签发的设备凭证。各目标的身份、Keychain 凭证、连接和错误独立；新增或替换目的地默认不启用。检查连接只验证 welcome，不发送活动。
4. 在“分享与预览”检查准确的隐私过滤结果，启用需要的目的地后明确“恢复分享”。发送不等于确认，只有收到接收端 ACK 才显示确认；暂停后仍可用空快照保持在线。菜单栏也提供暂停/恢复入口。
5. 使用可选服务时，按[接收服务指南](services/receiver/README.md)部署，再在“接收服务管理”连接实例、初始化或输入已有所有者凭证、签发设备并添加到本机接收端。所有者管理凭证与设备上报凭证不可互换。公开读取默认关闭，必须另行显式开启。

Debug 构建的“来源与隐私”提供明确的本机明文开发开关，只允许 `127.0.0.1` / `::1` 的 HTTP 管理与 WS 上报；例如本机服务的 `http://127.0.0.1:8787` 与 `ws://127.0.0.1:8787/api/v1/ingest`。Release 不提供此例外，必须使用系统信任的 HTTPS/WSS，不能用 Debug 本机成功代替正式 TLS 联合验收。

如果界面显示“系统保护中”，检查其中的会话诊断；不能通过绕过保护来获得活动。锁屏检测使用公开 `CGSessionCopyCurrentDictionary` 的未文档化 `CGSSessionScreenIsLocked` 字段；macOS 27 实测该键仅在锁屏期间出现，故键存在即锁屏、缺失视为未锁，而字典整体不可得或公开会话键异常时 **fail-closed**：停止全部采集，预览和发送均为空。

## 检查与真实验收

以下命令从仓库根目录执行，检查与打包分开：

```sh
make check
make test-receiver
make test-macos
make test-macos SWIFT_CONFIGURATION=release
make build-receiver
```

`make check` 检查协议 Schema、正反例、文档链接、指令层级和基本文本格式，不启动产品。`make test-receiver` 执行 Go 竞态测试及 vet；`make test-macos` 执行指定配置的 Swift 测试；`make test` 聚合两端测试。服务二进制输出为 `services/receiver/bin/nowbeam-receiver`，启动与初始化要求见[服务指南](services/receiver/README.md#构建与本机启动)。CI 配置不等于已触发或通过远端运行，不自动部署或发布。

已完成的本机验证（macOS 27 / Apple Silicon）：

- Go 竞态测试、vet 与二进制构建；Swift Debug 的 22 个 Core 测试和 12 个 Capture 测试、Release 的 16 个 Core 测试和 12 个 Capture 测试均通过。回环连接生命周期测试仅在 Debug 运行，不伪称 Release 已执行同一组明文测试。
- 真实原生四页界面、菜单暂停及正常退出、重启后强制暂停、独立 Keychain 保存/读取/删除；两个本机接收端的 ACK、暂停空快照及目标独立启停已观察。
- 真实接收链路验证一次性初始化、管理/设备权限隔离、公开开关、精确 Origin、接管、乱序/冲突、撤销及 45 秒租约。重复快照不续租，实测约 45.035 秒过期，另一实例仍保活；不完整帧约 1 秒强制释放传输。原生 WSS 已拒绝不可信证书，未修改系统信任。
- 解锁桌面真实采集贯通：前台应用随切换真实变化（cmux、Code 等），QQ 音乐曲目、播放状态与位置经接收端确认并推进；锁屏立即清空来源、空快照保活在线，解锁恢复真实采集。密集采样 0.4 秒间隔完整记录了该转换。验收中修复两缺陷：会话键缺失被误判为“无法确认”（解锁桌面永久空快照），以及 AppKit 自动终止在无窗口时回收常驻进程（已禁用并在清单声明）。
- `make app` 生成了 `dist/Nowbeam.app` 与 `dist/Nowbeam.dmg`；应用为 ARM64、ad-hoc 签名、未公证。最终 Release 应用已实际启动，DMG 只读挂载后的应用也通过严格签名验证。Linux/ARM64 的 scratch 接收器镜像及 Compose 已实际运行，使用 UID 65532、只读根文件系统、清空 capabilities 与 no-new-privileges；容器被强制终止后重启，所有者/设备身份保留，旧活动不恢复。

尚未完成：辅助功能授权及撤销下的窗口标题采集、QQ 音乐播放器退出清除的逐项记录、网易云音乐完整生命周期（本机未安装）、睡眠/唤醒转换、端到端延迟 p95、macOS 15 实机、受系统信任的正式 WSS 联合部署、正式签名包媒体运行和公证。只读 MediaRemote/gate 探针和合成投影样本都不能代替播放器验收。CI 已配置，但未提交、推送或触发远端运行。

## 媒体依赖与分发

打包固定使用 [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter/tree/0e82bf1c44ec39554fbfc402ec88a48c6ae2a0fd) 的审查版本，校验归档 SHA-256，并将 BSD-3-Clause 原许可与来源信息随包保留；完整锁定值见[架构说明](docs/architecture.md#6-媒体依赖决策与实测门槛)。自有 gate 和 Perl 宿主仅在受管子进程读取媒体状态，不远控播放器、不读取账号、Cookie 或缓存。MediaRemote 是私有接口，系统更新后仍需重新验证；项目本身的许可证及正式发布身份不能由这些第三方许可推定。

## 隐私边界

软件只上传明确允许的当前快照，不记录活动历史。锁屏清除活动，断网恢复重新采集，接收端必须执行状态过期。公开状态可被任何访问者读取和另行保存；发送前的本地过滤不能代替对接收方的信任，也不能撤销别人已经保存的内容。
