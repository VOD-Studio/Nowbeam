import AppKit
import Darwin
import Foundation
import NowbeamCore

@MainActor
public final class MediaCollector {
    private struct Response: Decodable {
        let status: String
        let payload: MediaSample?
    }

    public private(set) var diagnostic = "媒体来源已关闭"
    public var onChange: (() -> Void)?
    private var enabled = false
    private var generation = UUID()
    private var projection = MediaProjection()
    private var lastRead: ContinuousClock.Instant?
    private var stream: Process?
    private var streamPipe: Pipe?
    private var probe: Process?
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var timer: Timer?
    private let host: URL?

    public init(resourceDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("MediaRemote", isDirectory: true)) {
        host = resourceDirectory?.appendingPathComponent("media-host.pl")
    }

    public var current: MediaPresence? { enabled ? projection.current() : nil }

    public func configure(enabled: Bool) {
        guard self.enabled != enabled else { return }
        stop()
        self.enabled = enabled
        guard enabled else { return }
        diagnostic = "正在验证当前媒体会话"
        guard let host, FileManager.default.isReadableFile(atPath: host.path) else {
            diagnostic = "包内媒体资源不可用；不会回填旧曲目"
            onChange?()
            return
        }
        startEvents(host: host)
        let timer = Timer(timeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestRefresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        requestRefresh()
    }

    // 两个目的地可等待同一次新鲜读取；不让正常网络为卡死的采集进程续命。
    public func freshValue() async -> MediaPresence? {
        guard enabled else { return nil }
        if lastRead == nil || lastRead!.duration(to: .now) >= .seconds(2) {
            requestRefresh()
        }
        await refreshTask?.value
        return current
    }

    private func startEvents(host: URL) {
        guard stream == nil, enabled else { return }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [host.path, "events"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let expected = generation
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            // 事件仅失效缓存；权威值始终来自带播放状态门控的 snapshot，不保存事件历史。
            let count = (try? handle.read(upToCount: 8_192))?.count ?? 0
            guard count > 0 else { handle.readabilityHandler = nil; return }
            Task { @MainActor in
                guard let self, self.generation == expected else { return }
                self.lastRead = nil
                self.requestRefresh()
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == expected else { return }
                self.streamPipe?.fileHandleForReading.readabilityHandler = nil
                self.stream = nil
                self.streamPipe = nil
                self.projection.clear()
                self.lastRead = nil
                self.diagnostic = "媒体事件进程已停止；等待重新验证"
                self.onChange?()
            }
        }
        do {
            try process.run()
            stream = process
            streamPipe = pipe
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            diagnostic = "无法启动媒体事件进程；媒体保持为空"
            onChange?()
        }
    }

    private func requestRefresh() {
        guard enabled, let host, FileManager.default.isReadableFile(atPath: host.path) else { return }
        if refreshTask != nil {
            refreshAgain = true
            return
        }
        if stream == nil { startEvents(host: host) }
        let expected = generation
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [host.path, "snapshot"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        probe = process
        refreshTask = Task { [weak self] in
            let data = await Self.capture(process: process, output: output.fileHandleForReading)
            guard let self, self.generation == expected, self.enabled else { return }
            self.probe = nil
            let previous = self.projection.current()
            let oldDiagnostic = self.diagnostic
            if let data, let response = try? JSONDecoder().decode(Response.self, from: data), response.status == "ok" {
                let running = Set(["com.tencent.QQMusicMac", "com.netease.163music"].filter {
                    !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
                })
                self.projection.accept(response.payload, runningApplications: running)
                self.lastRead = .now
                self.diagnostic = self.projection.current() == nil
                    ? "没有可确认的 QQ 音乐或网易云音乐会话"
                    : "只读媒体会话已确认；停止、退出或失效时清空"
            } else {
                self.projection.clear()
                self.lastRead = nil
                self.diagnostic = "媒体接口不可用或读取超时；媒体已清空"
            }
            if Self.changed(previous, self.projection.current()) || self.diagnostic != oldDiagnostic {
                self.onChange?()
            }
            self.refreshTask = nil
            if self.refreshAgain {
                self.refreshAgain = false
                self.requestRefresh()
            }
        }
    }

    private static func changed(_ before: MediaPresence?, _ after: MediaPresence?) -> Bool {
        guard var before, var after else { return (before == nil) != (after == nil) }
        let previousPosition = before.playback.positionMs
        let nextPosition = after.playback.positionMs
        before.playback.positionMs = nil
        after.playback.positionMs = nil
        if before != after { return true }
        if let previousPosition, let nextPosition { return abs(previousPosition - nextPosition) > 1_500 }
        return (previousPosition == nil) != (nextPosition == nil)
    }

    private nonisolated static func capture(process: Process, output: FileHandle) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                        process.terminationHandler = { finished in
                            let data = try? output.readToEnd()
                            continuation.resume(returning: finished.terminationStatus == 0 && (data?.count ?? 0) <= 32_768 ? data : nil)
                        }
                        do {
                            try process.run()
                            if Task.isCancelled, process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        } catch {
                            continuation.resume(returning: nil)
                        }
                    }
                } onCancel: {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(4)) } catch { return nil }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    public func stop() {
        generation = UUID()
        enabled = false
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshAgain = false
        if let probe, probe.isRunning { kill(probe.processIdentifier, SIGKILL) }
        probe = nil
        streamPipe?.fileHandleForReading.readabilityHandler = nil
        if let stream, stream.isRunning { kill(stream.processIdentifier, SIGKILL) }
        stream = nil
        streamPipe = nil
        projection.clear()
        lastRead = nil
        diagnostic = "媒体来源已关闭"
        onChange?()
    }
}
