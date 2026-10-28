<!-- Parent: ../AGENTS.md -->
# 原生 macOS 软件

- Swift 6、macOS 15+、Apple Silicon。`Sources/NowbeamCore` 是协议/隐私/凭证/连接，`Sources/NowbeamCapture` 是系统采集，`Sources/NowbeamApp` 是图形化入口。
- UI 在 MainActor；不要在 UI 线程等网络或子进程。来源原始值不得进入日志、普通配置或上报。
- Swift 编码必须显式写出可空来源和媒体字段，不能让 Codable 的省略 nil 改变清除语义。
- 不请求屏幕录制，不监听键盘；只有用户开启窗口来源时才请求 Accessibility。锁屏停止公开活动。
- 应用图标母版是 `Branding/AppIcon.png`（1024×1024，艺术区 824，边距含投影）；`scripts/build_macos.py` 用系统自带的 `sips` / `iconutil` 生成 `.icns`，不在仓库里提交生成物。
- 媒体只用审查过并固定版本的辅助框架；最终包必须自带需要的资源，不要求用户安装开发工具。
- 测试与构建在编辑完成后统一运行。开发签名不能冒充正式签名与公证；不修改系统信任或 TCC 数据库。
