import Foundation
import CoreGraphics

/// Multitouch frames for the iPod's touch helper on port 5904 (Device/TouchServer.m, Docs/PROTOCOL.md).
/// Veency's RFB pointer carries one finger only, so two-finger gestures travel on this side channel.
enum TouchPhase: UInt8 { case began = 1, moved = 2, ended = 3, cancelled = 4 }

let maxTouchFingers = 5

/// Encodes one frame. Points are portrait screen pixels; out-of-range values are clamped.
func touchFrame(_ phase: TouchPhase, _ points: [(x: Int, y: Int)], width: Int, height: Int) -> [UInt8] {
    precondition((1...maxTouchFingers).contains(points.count), "1–5 fingers")
    var bytes: [UInt8] = [UInt8(ascii: "T"), phase.rawValue, UInt8(points.count), 0]
    for p in points { bytes += be16(max(0, min(width - 1, p.x))) + be16(max(0, min(height - 1, p.y))) }
    return bytes
}

/// Parses the helper's 12-byte handshake reply: "IMT1", width, height (UInt16 BE pixels), max fingers.
func parseTouchHello(_ reply: [UInt8]) throws -> (width: Int, height: Int, fingers: Int) {
    guard reply.count == 12, Array(reply[0..<4]) == Array("IMT1".utf8) else { throw fail("Unrecognized touch helper.") }
    let width = reply.u16(4), height = reply.u16(6), fingers = Int(reply[8])
    guard (1...4096).contains(width), (1...4096).contains(height), (2...maxTouchFingers).contains(fingers) else { throw fail("Invalid touch helper reply.") }
    return (width, height, fingers)
}

final class TouchChannel {
    private let queue = DispatchQueue(label: "dev.mannan.ipodmirror.touch")
    private let mutex = NSLock()
    private var wire: Wire?
    private var stopped = false
    private var size = (width: 640, height: 960)
    private var lastFailure: Date?
    private var gestureOpen = false
    private let connect: () throws -> Wire
    /// Called on the channel's queue with a user-facing message when the helper is missing or drops.
    var onStatus: ((String) -> Void)?

    init(device: USBDevice) { connect = { try device.connect(portNumber: 5904) } }
    init(connect: @escaping () throws -> Wire) { self.connect = connect }

    func stop() { mutex.lock(); stopped = true; let w = wire; wire = nil; mutex.unlock(); w?.cancel() }

    /// Points are normalized to the screen image (0…1, origin top-left).
    func send(_ phase: TouchPhase, _ points: [CGPoint]) {
        guard (1...maxTouchFingers).contains(points.count) else { return }
        queue.async { [self] in
            if phase == .began { gestureOpen = false }
            else if !gestureOpen { return } // The start of this gesture never reached the iPod.
            guard let w = phase == .began ? open() : current() else { return }
            let pixels = points.map { (x: Int(($0.x * CGFloat(size.width)).rounded(.down)), y: Int(($0.y * CGFloat(size.height)).rounded(.down))) }
            do {
                try w.send(touchFrame(phase, pixels, width: size.width, height: size.height))
                gestureOpen = phase == .began || phase == .moved
            } catch {
                drop(w); gestureOpen = false
                report("Two-finger input disconnected. It will reconnect on the next gesture.")
            }
        }
    }

    private func current() -> Wire? { mutex.lock(); defer { mutex.unlock() }; return stopped ? nil : wire }
    private func drop(_ w: Wire) { mutex.lock(); if wire === w { wire = nil }; mutex.unlock(); w.cancel() }
    private func report(_ message: String) { mutex.lock(); let live = !stopped; mutex.unlock(); if live { onStatus?(message) } }

    /// Connects lazily at the start of a gesture; after a failure, waits a few seconds before trying again.
    private func open() -> Wire? {
        if let w = current() { return w }
        mutex.lock(); let isStopped = stopped; mutex.unlock()
        if isStopped { return nil }
        if let failed = lastFailure, Date().timeIntervalSince(failed) < 5 { return nil }
        do {
            let w = try connect()
            w.deadline = Date().addingTimeInterval(3)
            try w.send(Array("IMT1".utf8))
            let hello = try parseTouchHello(try w.read(12))
            w.deadline = nil
            mutex.lock()
            if stopped { mutex.unlock(); w.cancel(); return nil }
            wire = w; size = (hello.width, hello.height)
            mutex.unlock()
            lastFailure = nil
            return w
        } catch {
            lastFailure = Date()
            report("Two-finger input needs the iPod touch helper. Install the helpers, then restart SpringBoard.")
            return nil
        }
    }
}
