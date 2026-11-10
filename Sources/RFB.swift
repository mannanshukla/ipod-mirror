import Foundation

struct Frame {
    let width: Int
    let height: Int
    let pixels: Data // RGBA, top row first
}
final class RFB {
    let wire: Wire
    private(set) var width = 0, height = 0
    private var pixels = [UInt8]()
    var onFrame: ((Frame) -> Void)?
    var onStatus: ((String) -> Void)?
    init(_ wire: Wire) { self.wire = wire }
    func run(password: String) throws {
        let greeting = try wire.read(12)
        guard let version = String(bytes:greeting,encoding:.ascii), version.hasPrefix("RFB 003."), version.hasSuffix("\n"), let minor = Int(version.dropFirst(8).prefix(3)) else { throw fail("This device did not send a VNC greeting.") }
        let protocolMinor = minor >= 8 ? 8 : (minor >= 7 ? 7 : 3)
        try wire.send(Array(String(format:"RFB 003.%03d\n",protocolMinor).utf8))
        var security: UInt32
        if protocolMinor == 3 {
            security = try wire.read(4).u32()
            if security == 0 { throw fail(try reason()) }
        } else {
            let count = Int(try wire.read(1)[0]); if count == 0 { throw fail(try reason()) }
            let methods = try wire.read(count)
            if methods.contains(2) && !password.isEmpty { security = 2 }
            else if methods.contains(1) { security = 1 }
            else if methods.contains(2) { throw fail("Enter your Veency password, then connect again.") }
            else { throw fail("This VNC server requires an unsupported authentication method.") }
            try wire.send([UInt8(security)])
        }
        if security == 2 {
            guard !password.isEmpty else { throw fail("Enter your Veency password, then connect again.") }
            try wire.send(Self.challengeResponse(try wire.read(16), password:password))
        } else if security != 1 { throw fail("Unsupported VNC authentication method.") }
        onStatus?("Approve access on the iPod if prompted…")
        if security == 2 || protocolMinor >= 8 {
            if try wire.read(4).u32() != 0 { throw fail(protocolMinor >= 8 ? try reason() : "Veency rejected the password or access request.") }
        }
        try wire.send([1]) // shared session
        let header = try wire.read(24)
        try resize(header.u16(0), header.u16(2))
        let nameLength = Int(header.u32(20)); guard nameLength <= 4096 else { throw fail("Invalid server name.") }
        _ = try wire.read(nameLength)
        // 32 bpp, 24 depth, little endian, true colour; R at bit 0, G 8, B 16.
        try wire.send([0,0,0,0,32,24,0,1,0,255,0,255,0,255,0,8,16,0,0,0])
        try wire.send([2,0,0,2] + be32(0) + be32(UInt32(bitPattern:-223)))
        onStatus?("Connected over USB")
        try request(incremental:false)
        wire.deadline = nil
        while true {
            switch try wire.read(1)[0] {
            case 0:
                let h = try wire.read(3), count = h.u16(1)
                guard count <= 4096 else { throw fail("Too many screen rectangles.") }
                for _ in 0..<count {
                    let r = try wire.read(12), x = r.u16(0), y = r.u16(2), w = r.u16(4), h = r.u16(6)
                    let encoding = Int32(bitPattern:r.u32(8))
                    if encoding == -223 { try resize(w,h); continue }
                    guard encoding == 0, x+w <= width, y+h <= height else { throw fail("Invalid or unsupported screen rectangle.") }
                    let bytes = try wire.read(w*h*4)
                    for row in 0..<h {
                        let start = ((y+row)*width+x)*4
                        pixels.replaceSubrange(start..<(start+w*4),with:bytes[(row*w*4)..<((row+1)*w*4)])
                    }
                }
                if count > 0 { onFrame?(Frame(width:width,height:height,pixels:Data(pixels))) }
                // One outstanding incremental request keeps memory and traffic bounded.
                try request(incremental:true)
            case 1:
                let h = try wire.read(5); _ = try wire.read(h.u16(3)*6)
            case 2: break // Bell: do not surprise the user with audio.
            case 3:
                let h = try wire.read(7), length = Int(h.u32(3))
                guard length <= 1024*1024 else { throw fail("Oversized clipboard message.") }
                _ = try wire.read(length) // No automatic clipboard sharing.
            default: throw fail("Unsupported VNC server message.")
            }
        }
    }
    private func reason() throws -> String {
        let n = Int(try wire.read(4).u32()); guard n <= 4096 else { throw fail("VNC authentication failed.") }
        return String(bytes:try wire.read(n),encoding:.utf8) ?? "VNC authentication failed."
    }
    private func resize(_ w: Int, _ h: Int) throws {
        guard w > 0, h > 0, w <= 2048, h <= 2048 else { throw fail("Unsupported display size.") }
        width=w; height=h; pixels=[UInt8](repeating:0,count:w*h*4)
    }
    func request(incremental: Bool) throws { try wire.send([3,incremental ? 1:0,0,0,0,0]+be16(width)+be16(height)) }
    func pointer(x:Int,y:Int,buttons:UInt8) throws { try wire.send([5,buttons]+be16(x)+be16(y)) }
    func key(_ code:UInt32,down:Bool) throws { try wire.send([4,down ? 1:0,0,0]+be32(code)) }
    static func challengeResponse(_ challenge:[UInt8],password:String) throws -> [UInt8] {
        guard challenge.count == 16 else { throw fail("Invalid authentication challenge.") }
        var key=[UInt8](repeating:0,count:8)
        for (i,b) in password.utf8.prefix(8).enumerated() {
            var reversed:UInt8=0
            for bit in 0..<8 { reversed |= ((b >> bit)&1) << (7-bit) };key[i]=reversed
        }
        defer { for i in key.indices { key[i]=0 } }
        var result=[UInt8](repeating:0,count:16), written=0
        let status=key.withUnsafeBytes { k in challenge.withUnsafeBytes { c in result.withUnsafeMutableBytes { r in
            CCCrypt(CCOperation(kCCEncrypt),CCAlgorithm(kCCAlgorithmDES),CCOptions(kCCOptionECBMode),k.baseAddress,8,nil,c.baseAddress,16,r.baseAddress,16,&written)
        } } }
        guard status == kCCSuccess, written == 16 else { throw fail("VNC password authentication failed.") }
        return result
    }
}
