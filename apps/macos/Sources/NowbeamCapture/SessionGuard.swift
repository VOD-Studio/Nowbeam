import AppKit
import CoreGraphics

@MainActor
public final class SessionGuard {
    public enum State: Equatable, Sendable {
        case active, locked, inactive, sleeping, unavailable

        public var permitsCapture: Bool { self == .active }
        public var description: String {
            switch self {
            case .active: "会话已解锁"
            case .locked: "已锁屏，全部活动清空"
            case .inactive: "当前用户会话未激活，全部活动清空"
            case .sleeping: "系统或屏幕休眠，全部活动清空"
            case .unavailable: "无法确认系统锁定状态，分享保持空白"
            }
        }
    }

    public private(set) var state: State = .unavailable
    public var onChange: ((State) -> Void)?
    public var onSleep: (() -> Void)?
    public var onWake: (() -> Void)?
    private var tokens: [NSObjectProtocol] = []
    private var timer: Timer?
    private var systemSleeping = false
    private var screenSleeping = false
    private var sessionInactive = false

    public init() {}

    public func start() {
        guard tokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for name in names {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let name = notification.name
                Task { @MainActor in self?.receive(name) }
            })
        }
        // 不把丢失的分布式通知当安全边界；定期重新检查状态，缺失字段时禁止采集。
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    private func receive(_ name: Notification.Name) {
        switch name {
        case NSWorkspace.willSleepNotification:
            systemSleeping = true
        case NSWorkspace.didWakeNotification:
            systemSleeping = false
        case NSWorkspace.screensDidSleepNotification:
            screenSleeping = true
        case NSWorkspace.screensDidWakeNotification:
            screenSleeping = false
        case NSWorkspace.sessionDidResignActiveNotification:
            sessionInactive = true
        case NSWorkspace.sessionDidBecomeActiveNotification:
            sessionInactive = false
        default:
            return
        }
        refresh()
        if name == NSWorkspace.willSleepNotification { onSleep?() }
        if name == NSWorkspace.didWakeNotification { onWake?() }
    }

    public func refresh() {
        let next: State
        if systemSleeping || screenSleeping {
            next = .sleeping
        } else if sessionInactive {
            next = .inactive
        } else if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
                  let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool,
                  let loggedIn = session[kCGSessionLoginDoneKey as String] as? Bool,
                  let locked = session["CGSSessionScreenIsLocked"] as? Bool {
            // CGSessionCopyCurrentDictionary 是公开 API；此字段未文档化，缺失绝不能默认解锁。
            next = !onConsole || !loggedIn ? .inactive : (locked ? .locked : .active)
        } else {
            next = .unavailable
        }
        guard next != state else { return }
        state = next
        onChange?(next)
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        tokens.removeAll()
        state = .unavailable
    }
}
