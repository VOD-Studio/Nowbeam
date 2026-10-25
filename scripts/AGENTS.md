<!-- Parent: ../AGENTS.md -->
# 开发校验与打包工具

- `check.py` 是协议和仓库静态校验入口，不是 Nowbeam 产品 CLI，也不实现接收端状态机。覆盖 Swift、Go、Objective-C、Perl、容器配置及 Go 依赖清单；遍历前排除构建产物与本地缓存，不把下载的第三方源码当作仓库源码检查。
- Python 依赖只放根目录 `requirements-dev.txt`，安装到 `.venv`，不得污染用户全局 Python。macOS 的 `cmake==3.31.6` 也是项目本地开发依赖，打包器必须使用 `.venv/bin/cmake`，不依赖系统 CMake 版本。
- 消息正反例必须覆盖消费者可见行为，例如独立空来源、暂停不推进、非法字段拒绝和消息上限；不做源码字符串快照。
- `check.py` 不得访问用户真实活动、凭证、播放器、外部服务或生产环境；正常运行必须离线、确定性。行为回归由 `make test-receiver` / `make test-macos` 执行，不用静态文字断言代替。
- `build_macos.py` 仅在 Apple Silicon macOS 上打包；允许下载固定提交并校验 SHA-256 的媒体依赖，必须随包保留原许可。`make app-debug` 生成 Debug `.app`（跳过 DMG），`make app` 生成 Release `.app` / DMG，均输出到 `dist/`；额外参数通过 `APP_ARGS` 传入。
- 打包默认 ad-hoc 签名，不等于 Developer ID 签名、公证或发布。不要更改全局工具链、系统信任或用户授权；Python/CMake 不进入产品运行依赖。
- 编辑结束后由集成负责人统一运行 `make check`、相关测试及打包验证，不在并行编辑中重复启动。不要把静态校验、构建或单元测试说成 UI、正式 WSS 或真实媒体采集验收。
