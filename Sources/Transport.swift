import Foundation
import Darwin

enum MirrorError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
func fail(_ s: String) -> MirrorError { .message(s) }
final class Wire {
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var stopped = false
    let fd: Int32
    var deadline: Date? = Date().addingTimeInterval(90)
    init(_ fd: Int32) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }
    deinit { Darwin.close(fd) }
    func cancel() { lock.lock(); stopped = true; shutdown(fd, SHUT_RDWR); lock.unlock() }
    func read(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= 32 * 1024 * 1024 else { throw fail("Invalid message size.") }
        var bytes = [UInt8](repeating: 0, count: count), offset = 0
        while offset < count {
            lock.lock(); let cancelled = stopped; lock.unlock()
            if cancelled { throw fail("Disconnected.") }
            if let limit = deadline, Date() > limit { throw fail("The iPod did not respond. Unlock it and accept Veency’s access request.") }
            var pollfd = Darwin.pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&pollfd, 1, 500)
            if ready == 0 { continue }
            if ready < 0 { if errno == EINTR { continue }; throw fail("USB connection interrupted.") }
            let n = bytes.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            if n <= 0 { throw fail("The iPod disconnected or Veency closed the connection.") }
            offset += n
        }
        return bytes
    }
    func send(_ bytes: [UInt8]) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0) }
            if n <= 0 { throw fail("Could not send to the iPod.") }
            offset += n
        }
    }
    static func mux() throws -> Wire {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw fail("Could not open Apple’s USB service.") }
        let wire = Wire(fd)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array("/var/run/usbmuxd".utf8) + [0]
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path) }
        let result = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw fail("Apple’s USB service is unavailable. Connect the iPod with a USB cable.") }
        wire.deadline = Date().addingTimeInterval(8)
        return wire
    }
    func muxRequest(_ values: [String: Any]) throws -> [String: Any] {
        var request = values
        request["ClientVersionString"] = "iPod Mirror 0.1"; request["ProgName"] = "iPod Mirror"; request["kLibUSBMuxVersion"] = 3
        let payload = try PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0)
        func le(_ n: UInt32) -> [UInt8] { [UInt8(truncatingIfNeeded:n), UInt8(truncatingIfNeeded:n >> 8), UInt8(truncatingIfNeeded:n >> 16), UInt8(truncatingIfNeeded:n >> 24)] }
        try send(le(UInt32(payload.count+16)) + le(1) + le(8) + le(1) + payload)
        let header = try read(16)
        let length = Int(UInt32(header[0]) | UInt32(header[1]) << 8 | UInt32(header[2]) << 16 | UInt32(header[3]) << 24)
        guard length >= 16, length <= 1024 * 1024 else { throw fail("Invalid USB service response.") }
        let data = Data(try read(length-16))
        guard let answer = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw fail("Invalid USB response.") }
        return answer
    }
}
struct USBDevice {
    let id: Int
    let serial: String
    let product: Int
    var label: String { "USB device · \(serial.suffix(8))" }
    static func list() throws -> [USBDevice] {
        let wire = try Wire.mux(); defer { wire.cancel() }
        let answer = try wire.muxRequest(["MessageType":"ListDevices"])
        return (answer["DeviceList"] as? [[String:Any]] ?? []).compactMap { d in
            guard let p = d["Properties"] as? [String:Any], p["ConnectionType"] as? String == "USB", let id = d["DeviceID"] as? Int, let serial = p["SerialNumber"] as? String else { return nil }
            return USBDevice(id:id, serial:serial, product:p["ProductID"] as? Int ?? 0)
        }
    }
    func connect() throws -> Wire {
        let wire = try Wire.mux()
        let port = Int(UInt16(5900).bigEndian)
        let answer = try wire.muxRequest(["MessageType":"Connect", "DeviceID":id, "PortNumber":port])
        guard answer["Number"] as? Int == 0 else { throw fail("Veency is not reachable on this device. Select your jailbroken iPod, enable Veency in Settings, and unlock it.") }
        wire.deadline = Date().addingTimeInterval(90)
        return wire
    }
}
func be16(_ n: Int) -> [UInt8] { [UInt8(truncatingIfNeeded:n >> 8), UInt8(truncatingIfNeeded:n)] }
func be32(_ n: UInt32) -> [UInt8] { [UInt8(truncatingIfNeeded:n >> 24), UInt8(truncatingIfNeeded:n >> 16), UInt8(truncatingIfNeeded:n >> 8), UInt8(truncatingIfNeeded:n)] }
extension Array where Element == UInt8 {
    func u16(_ i: Int = 0) -> Int { Int(self[i]) << 8 | Int(self[i+1]) }
    func u32(_ i: Int = 0) -> UInt32 { UInt32(self[i]) << 24 | UInt32(self[i+1]) << 16 | UInt32(self[i+2]) << 8 | UInt32(self[i+3]) }
}
