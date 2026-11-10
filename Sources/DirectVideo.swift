import Foundation
final class DirectVideo {
    private let mutex=NSLock()
    private var cancelled=false
    private var wire:Wire?
    var onFrame:((Frame)->Void)?
    var onError:((String)->Void)?
    func stop(){mutex.lock();cancelled=true;let w=wire;mutex.unlock();w?.cancel()}
    func start(device:USBDevice){
        DispatchQueue.global(qos:.userInitiated).async{[self] in
            defer {mutex.lock();let w=wire;wire=nil;mutex.unlock();w?.cancel()}
            do {
                let w=try device.connect(portNumber:5902);mutex.lock();wire=w;let stopped=cancelled;mutex.unlock();if stopped{w.cancel();return}
                while true {
                    w.deadline=Date().addingTimeInterval(5)
                    try w.send(Array("FRAM".utf8));let h=try w.read(20)
                    let width=Int(h.u32(4)),height=Int(h.u32(8)),bytes=Int(h.u32(12))
                    guard h.u32()==0x494d5631,width==320,height==480,bytes==width*height*4 else {throw fail("Invalid direct-video frame.")}
                    onFrame?(Frame(width:width,height:height,pixels:Data(try w.read(bytes))))
                }
            }catch{mutex.lock();let stopped=cancelled;mutex.unlock();if !stopped{onError?(error.localizedDescription)}}
        }
    }
}
