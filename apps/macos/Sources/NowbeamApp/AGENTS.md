<!-- Parent: ../AGENTS.md -->
# 原生界面与组合根

- 菜单栏面板（`MenuBarExtra`）与设置窗口（`Window`）是日常管理入口，都用 SwiftUI 场景，不手工创建 `NSWindow` / `NSStatusItem`，否则拿不到系统的玻璃窗口外壳；玻璃效果统一经 `InterfaceSupport.swift` 的封装，不在页面里直接写 `#available`。
- AppModel 在 MainActor 管理独立采集器、每目的地连接和隐私投影。
- 新目的地、地址/凭证变化、首次分享都须独立启用。未经 ACK 不能显示同步成功；明确展示暂停时发送空快照。
- 普通配置不含令牌、活动或原始标题；Keychain 是凭证唯一持久存储。异步回调必须核对目的地代次。
- 所有者管理只适用于可选 Nowbeam 接收服务，不能要求第三方接收方实现管理 API。不要添加 Web UI、展示卡片或 CLI 产品。
