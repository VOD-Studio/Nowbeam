import Foundation
import Testing
@testable import NowbeamCapture

struct SessionGuardTests {
    @Test func unlockedSessionHasNoLockFlagAndIsActive() {
        // 实测 macOS 27：解锁状态下 CGSSessionScreenIsLocked 键不存在。
        #expect(SessionGuard.evaluate(onConsole: true, loggedIn: true, lockedFlag: nil) == .active)
    }

    @Test func explicitUnlockedFlagStaysActive() {
        #expect(SessionGuard.evaluate(onConsole: true, loggedIn: true, lockedFlag: false) == .active)
    }

    @Test func lockFlagPresentMeansLocked() {
        // 实测锁屏期间标志出现且为 true，伴随 CGSSessionScreenLockedTime。
        #expect(SessionGuard.evaluate(onConsole: true, loggedIn: true, lockedFlag: true) == .locked)
    }

    @Test func consoleOrLoginMissingBlocksCapture() {
        // 实测锁屏时 onConsole/loginDone 仍为 true，二者只能证明会话归属，不能证明未锁。
        #expect(SessionGuard.evaluate(onConsole: false, loggedIn: true, lockedFlag: nil) == .inactive)
        #expect(SessionGuard.evaluate(onConsole: true, loggedIn: false, lockedFlag: nil) == .inactive)
        #expect(SessionGuard.evaluate(onConsole: false, loggedIn: false, lockedFlag: true) == .inactive)
    }
}
