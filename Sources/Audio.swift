import AVFoundation

final class AudioReceiver {
    private let mutex=NSLock()
    private var cancelled=false
    private var wire:Wire?
    private var queued=0
    var onStatus:((String)->Void)?
    func stop(){mutex.lock();cancelled=true;let w=wire;mutex.unlock();w?.cancel()}
    func start(device:USBDevice) {
        DispatchQueue.global(qos:.userInitiated).async { [self] in
            let engine=AVAudioEngine(),player=AVAudioPlayerNode()
            defer {player.stop();engine.stop();mutex.lock();let w=wire;wire=nil;mutex.unlock();w?.cancel()}
            do {
                let w=try device.connect(portNumber:5903)
                mutex.lock();wire=w;let stopped=cancelled;mutex.unlock();if stopped {w.cancel();return}
                try w.send(Array("IMA1".utf8));guard try w.read(4)==Array("IMA1".utf8) else{throw fail("Unrecognized audio helper.")}
                w.deadline=nil
                engine.attach(player)
                var currentRate=0,currentChannels=0,announced=false,primed=false
                var totalReceived=0,totalPlayed=0,underruns=0,lastReport=Date()
                onStatus?("Audio connected · waiting for playback")
                while true {
                    let header=try w.read(16),rate=Int(header.u32()),channels=Int(header.u32(4)),frames=Int(header.u32(8)),bytes=Int(header.u32(12))
                    guard (8000...96000).contains(rate),(1...2).contains(channels),(1...2048).contains(frames),bytes==frames*channels*4 else{throw fail("Invalid audio packet.")}
                    let payload=try w.read(bytes)
                    if rate != currentRate || channels != currentChannels {
                        player.stop();engine.stop();engine.disconnectNodeOutput(player)
                        guard let format=AVAudioFormat(standardFormatWithSampleRate:Double(rate),channels:AVAudioChannelCount(channels)) else{throw fail("Unsupported audio format.")}
                        engine.connect(player,to:engine.mainMixerNode,format:format)
                        try engine.start();primed=false;currentRate=rate;currentChannels=channels
                    }
                    mutex.lock();let empty=queued==0;let full=queued>=12;if !full{queued+=1};mutex.unlock();if full{continue}
                    if empty && primed {player.pause();primed=false;underruns+=1}
                    let format=AVAudioFormat(standardFormatWithSampleRate:Double(rate),channels:AVAudioChannelCount(channels))!
                    guard let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(frames)) else{throw fail("Could not allocate audio buffer.")}
                    buffer.frameLength=AVAudioFrameCount(frames)
                    for f in 0..<frames {for c in 0..<channels {
                        let i=(f*channels+c)*4,bits=UInt32(payload[i]) | UInt32(payload[i+1])<<8 | UInt32(payload[i+2])<<16 | UInt32(payload[i+3])<<24
                        let value=Float(bitPattern:bits);buffer.floatChannelData![c][f]=value.isFinite ? max(-1,min(1,value)):0
                    }}
                    player.scheduleBuffer(buffer,completionCallbackType:.dataPlayedBack){ [weak self] _ in guard let self=self else{return};self.mutex.lock();self.queued=max(0,self.queued-1);self.mutex.unlock() }
                    totalReceived+=frames
                    mutex.lock();let buffered=queued;mutex.unlock()
                    if !primed && buffered>=4 {player.play();primed=true}
                    if !announced && primed {announced=true;onStatus?("Audio playing on Mac")}
                    if Date().timeIntervalSince(lastReport)>=5 {totalPlayed=totalReceived;_ = totalPlayed;lastReport=Date();onStatus?("Audio playing · \(underruns) rebuffer\(underruns == 1 ? "" : "s")")}
                }
            } catch {mutex.lock();let stopped=cancelled;mutex.unlock();if !stopped {onStatus?(error.localizedDescription)}}
        }
    }
}
