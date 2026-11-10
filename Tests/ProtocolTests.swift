import Foundation
import Darwin
func expect(_ value:Bool,_ message:String) { if !value { fatalError(message) } }
func pair() throws -> (Wire,Wire) {
    var fds:[Int32]=[0,0];guard socketpair(AF_UNIX,SOCK_STREAM,0,&fds)==0 else{throw fail("socketpair")}
    return (Wire(fds[0]),Wire(fds[1]))
}
func hello(_ server:Wire, minor:Int, authenticated:Bool=false) throws {
    try server.send(Array(String(format:"RFB 003.%03d\n",minor).utf8))
    expect(try server.read(12)==Array(String(format:"RFB 003.%03d\n",minor).utf8),"version")
    if minor==3 {try server.send(be32(1))} else {
        try server.send([1,authenticated ? 2:1]);expect(try server.read(1)==[authenticated ? 2:1],"security")
        if authenticated {
            try server.send(Array(0..<16));let response=try server.read(16)
            expect(response==[0xb8,0x66,0x92,0x41,0x25,0xc8,0xee,0xbb,0x9d,0xeb,0xc1,0xdb,0x61,0xc5,0x38,0xe2],"DES challenge response")
        }
        try server.send(be32(0))
    }
    expect(try server.read(1)==[1],"shared flag")
    try server.send(be16(2)+be16(2)+[32,24,0,1,0,255,0,255,0,255,0,8,16,0,0,0]+be32(4)+Array("Test".utf8))
    expect(try server.read(20)==[0,0,0,0,32,24,0,1,0,255,0,255,0,255,0,8,16,0,0,0],"pixel format")
    expect(try server.read(12)==[2,0,0,2]+be32(0)+be32(UInt32(bitPattern:-223)),"encodings")
    expect(try server.read(10)==[3,0,0,0,0,0,0,2,0,2],"initial request")
}
@main struct Tests {
 static func main() throws {
    if CommandLine.arguments.contains("--list") {for d in try USBDevice.list(){print(d.label)};return}
    for minor in [3,8] {
        let (client,server)=try pair(),rfb=RFB(client),done=DispatchSemaphore(value:0),frameReady=DispatchSemaphore(value:0)
        var frames=[Frame]();let lock=NSLock()
        rfb.onFrame={f in lock.lock();frames.append(f);lock.unlock();frameReady.signal()}
        DispatchQueue.global().async {defer{done.signal()};do{try rfb.run(password:"")}catch{}}
        try hello(server,minor:minor)
        let pixels:[UInt8]=[255,0,0,0,0,255,0,0,0,0,255,0,255,255,255,0]
        try server.send([0,0,0,1]+be16(0)+be16(0)+be16(2)+be16(2)+be32(0)+pixels)
        expect(frameReady.wait(timeout:.now()+2) == .success,"frame timeout")
        expect(try server.read(10)==[3,1,0,0,0,0,0,2,0,2],"incremental request")
        try server.send([0,0,0,1]+be16(1)+be16(1)+be16(1)+be16(1)+be32(0)+[7,8,9,0])
        expect(frameReady.wait(timeout:.now()+2) == .success,"partial timeout")
        _ = try server.read(10)
        lock.lock();expect(Array(frames[1].pixels.prefix(12))==Array(pixels.prefix(12)),"partial update preserved pixels");expect(Array(frames[1].pixels.suffix(4))==[7,8,9,0],"partial pixels");lock.unlock()
        try rfb.pointer(x:1,y:1,buttons:1);expect(try server.read(6)==[5,1,0,1,0,1],"pointer")
        try rfb.key(0xff0d,down:true);expect(try server.read(8)==[4,1,0,0,0,0,255,13],"key")
        try server.send([0,0,0,1]+be16(0)+be16(0)+be16(1)+be16(3)+be32(UInt32(bitPattern:-223)))
        expect(frameReady.wait(timeout:.now()+2) == .success,"resize timeout");_ = try server.read(10)
        client.cancel();expect(done.wait(timeout:.now()+2) == .success,"cancel must unblock read");server.cancel()
        print("PASS RFB 3.\(minor): handshake, raw/partial frames, input, resize, cancellation")
    }
    do {
        let (client,server)=try pair(),rfb=RFB(client),done=DispatchSemaphore(value:0)
        DispatchQueue.global().async {defer{done.signal()};do{try rfb.run(password:"")}catch{}}
        try hello(server,minor:8)
        try server.send([0,0,0,1]+be16(0)+be16(0)+be16(65535)+be16(65535)+be32(0))
        expect(done.wait(timeout:.now()+2) == .success,"reject out of bounds before allocating");client.cancel();server.cancel()
        print("PASS malformed rectangle rejected")
    }
    do {
        let (client,server)=try pair(),rfb=RFB(client),done=DispatchSemaphore(value:0)
        DispatchQueue.global().async {defer{done.signal()};do{try rfb.run(password:"password")}catch{}}
        try hello(server,minor:8,authenticated:true);client.cancel();expect(done.wait(timeout:.now()+2) == .success,"auth session cancel");server.cancel()
        print("PASS VNC DES authentication fixture")
    }
 }
}
