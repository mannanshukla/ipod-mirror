import AppKit

final class ScreenView: NSView {
    var frameImage: CGImage? { didSet { needsDisplay=true } }
    var onPointer: ((Int,Int,UInt8)->Void)?
    var onKey: ((UInt32,Bool)->Void)?
    private var dragging=false
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    var imageRect: NSRect {
        guard let image=frameImage else { return .zero }
        let scale=min(bounds.width/CGFloat(image.width),bounds.height/CGFloat(image.height))
        let size=NSSize(width:CGFloat(image.width)*scale,height:CGFloat(image.height)*scale)
        return NSRect(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2,width:size.width,height:size.height)
    }
    override func draw(_ dirtyRect:NSRect) {
        NSColor(calibratedWhite:0.07,alpha:1).setFill();bounds.fill()
        guard let image=frameImage else { return }
        let ns=NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height))
        ns.draw(in:imageRect,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
    }
    private func point(_ event:NSEvent,buttons:UInt8) {
        guard let image=frameImage else { return }
        let p=convert(event.locationInWindow,from:nil),r=imageRect
        if buttons != 0 && !dragging && !r.contains(p) { return }
        let x=max(0,min(image.width-1,Int((p.x-r.minX)*CGFloat(image.width)/r.width)))
        let y=max(0,min(image.height-1,Int((p.y-r.minY)*CGFloat(image.height)/r.height)))
        onPointer?(x,y,buttons)
    }
    override func mouseDown(with e:NSEvent) { window?.makeFirstResponder(self);guard imageRect.contains(convert(e.locationInWindow,from:nil)) else{return};dragging=true;point(e,buttons:1) }
    override func mouseDragged(with e:NSEvent) { if dragging {point(e,buttons:1)} }
    override func mouseUp(with e:NSEvent) { if dragging {point(e,buttons:0)};dragging=false }
    override func rightMouseDown(with e:NSEvent) { point(e,buttons:4) }
    override func rightMouseUp(with e:NSEvent) { point(e,buttons:0) }
    func releaseInput() { dragging=false;onPointer?(0,0,0) }
    override func keyDown(with e:NSEvent) {
        if e.modifierFlags.contains(.command) { super.keyDown(with:e);return }
        let special:[UInt16:UInt32]=[36:0xff0d,48:0xff09,51:0xff08,53:0xff1b,123:0xff51,124:0xff53,125:0xff54,126:0xff52,117:0xffff]
        if let key=special[e.keyCode] { onKey?(key,true);onKey?(key,false);return }
        for scalar in (e.characters ?? "").unicodeScalars {
            let key=scalar.value <= 255 ? scalar.value : 0x01000000 | scalar.value
            onKey?(key,true);onKey?(key,false)
        }
    }
}

final class MirrorApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    enum State { case idle, connecting, connected, waiting }
    var window:NSWindow!
    let screen=ScreenView()
    let status=NSTextField(wrappingLabelWithString:"Connect your iPod over USB to begin.")
    let subtitle=NSTextField(wrappingLabelWithString:"Your familiar little screen, on your Mac.")
    let devices=NSPopUpButton()
    let password=NSSecureTextField()
    let connectButton=NSButton(title:"Connect",target:nil,action:nil)
    let home=NSButton(title:"Home",target:nil,action:nil)
    let lockButton=NSButton(title:"Lock",target:nil,action:nil)
    let screenshotButton=NSButton(title:"Screenshot",target:nil,action:nil)
    let audioButton=NSButton(checkboxWithTitle:"Audio on Mac",target:nil,action:nil)
    let audioStatus=NSTextField(labelWithString:"Audio off")
    var audio:AudioReceiver?
    var audioGeneration=UUID()
    let fastButton=NSButton(checkboxWithTitle:"Direct video · experimental",target:nil,action:nil)
    var directVideo:DirectVideo?
    var videoGeneration=UUID()
    var controlWidth=640,controlHeight=960
    let empty=NSStackView()
    var found=[USBDevice]()
    var state=State.idle
    var generation=UUID()
    var selectedSerial:String?
    var connection:RFB?
    var pendingWire:Wire?
    var reconnectTimer:Timer?
    let inputQueue=DispatchQueue(label:"dev.mannan.ipodmirror.input")
    var latestFrame:(Frame, UUID, RFB, Bool)?
    var frameLock=NSLock(), scheduledFrame=false
    var pollTimer:Timer?
    var scanning=false
    var wantsReconnect=false
    let optionsPopover=NSPopover()
    func applicationDidFinishLaunching(_ note:Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu=NSMenu(),appMenu=NSMenu(),item=NSMenuItem();menu.addItem(item);item.submenu=appMenu
        appMenu.addItem(withTitle:"About iPod Mirror",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:"")
        appMenu.addItem(.separator());appMenu.addItem(withTitle:"Quit iPod Mirror",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let control=NSMenu(),controlItem=NSMenuItem(title:"iPod",action:nil,keyEquivalent:"");menu.addItem(controlItem);controlItem.submenu=control
        for (title,action,key) in [("Home",#selector(goHome),"1"),("Lock",#selector(goLock),"l"),("Save Screenshot…",#selector(saveScreenshot),"s")] {
            let item=control.addItem(withTitle:title,action:action,keyEquivalent:key);item.target=self
        }
        NSApp.mainMenu=menu
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:420,height:790),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title="iPod Mirror";window.titleVisibility = .hidden;window.titlebarAppearsTransparent=true
        window.minSize=NSSize(width:350,height:660);window.contentAspectRatio=NSSize(width:420,height:790)
        window.delegate=self;window.isReleasedWhenClosed=false;window.isOpaque=false;window.backgroundColor = .clear
        let root=NSVisualEffectView();root.material = .underWindowBackground;root.blendingMode = .behindWindow;root.state = .active
        window.contentView=root
        let title=NSTextField(labelWithString:"iPod Mirror");title.font = .systemFont(ofSize:14,weight:.semibold)
        subtitle.textColor = .secondaryLabelColor;subtitle.font = .systemFont(ofSize:10);subtitle.maximumNumberOfLines=1;subtitle.lineBreakMode = .byTruncatingTail
        subtitle.stringValue="Your iPod, right here."
        let titles=NSStackView(views:[title,subtitle]);titles.orientation = .vertical;titles.alignment = .leading;titles.spacing=2
        let settings=NSButton(title:"Connection settings",target:self,action:#selector(showOptions));symbolButton(settings,name:"slider.horizontal.3",label:"Connection settings")
        connectButton.target=self;connectButton.action=#selector(toggleConnection);connectButton.bezelStyle = .rounded;connectButton.controlSize = .small
        connectButton.setContentHuggingPriority(.required,for:.horizontal)
        let header=NSStackView(views:[titles,settings]);header.orientation = .horizontal;header.spacing=8
        titles.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let headerGlass=glass(header,radius:20,inset:9)
        header.widthAnchor.constraint(equalTo:headerGlass.widthAnchor,constant:-18).isActive=true
        home.target=self;home.action=#selector(goHome);lockButton.target=self;lockButton.action=#selector(goLock);screenshotButton.target=self;screenshotButton.action=#selector(saveScreenshot)
        symbolButton(home,name:"house",label:"Home · ⌘1");symbolButton(lockButton,name:"lock",label:"Lock iPod · ⌘L");symbolButton(screenshotButton,name:"camera",label:"Save screenshot · ⌘S")
        audioButton.setButtonType(.toggle);audioButton.target=self;audioButton.action=#selector(toggleAudio)
        symbolButton(audioButton,name:"speaker.wave.2",label:"Play iPod audio on Mac")
        let toolbar=NSStackView(views:[home,lockButton,screenshotButton,audioButton]);toolbar.orientation = .horizontal;toolbar.spacing=10
        let toolbarGlass=glass(toolbar,radius:25,inset:7)
        for button in [home,lockButton,screenshotButton,audioButton] {button.isEnabled=false}
        status.font = .systemFont(ofSize:10);status.textColor = .secondaryLabelColor;status.alignment = .center;status.maximumNumberOfLines=2
        screen.wantsLayer=true;screen.layer?.cornerRadius=18;screen.layer?.masksToBounds=true
        let icon=NSImageView(image:NSImage(named:NSImage.Name("AppIcon")) ?? NSImage(systemSymbolName:"ipodtouch",accessibilityDescription:"iPod") ?? NSImage());icon.imageScaling = .scaleProportionallyUpOrDown;icon.contentTintColor = .white
        let heading=NSTextField(labelWithString:"Your iPod. On your Mac.");heading.font = .systemFont(ofSize:19,weight:.medium);heading.textColor = .white
        let hint=NSTextField(wrappingLabelWithString:"Plug in. Unlock. Connect.\nChoose your iPod in connection settings.");hint.alignment = .center;hint.textColor = .lightGray;hint.font = .systemFont(ofSize:12)
        empty.setViews([icon,heading,hint],in:.center);empty.orientation = .vertical;empty.spacing=14;empty.alignment = .centerX
        for view in [headerGlass,screen,toolbarGlass,status] {view.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(view)}
        empty.translatesAutoresizingMaskIntoConstraints=false;screen.addSubview(empty)
        NSLayoutConstraint.activate([
            headerGlass.topAnchor.constraint(equalTo:root.topAnchor,constant:32),headerGlass.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:12),headerGlass.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-12),
            screen.topAnchor.constraint(equalTo:headerGlass.bottomAnchor,constant:10),screen.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:12),screen.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-12),
            toolbarGlass.topAnchor.constraint(equalTo:screen.bottomAnchor,constant:10),toolbarGlass.centerXAnchor.constraint(equalTo:root.centerXAnchor),
            status.topAnchor.constraint(equalTo:toolbarGlass.bottomAnchor,constant:8),status.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:18),status.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-18),status.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-10),status.heightAnchor.constraint(equalToConstant:28),
            empty.centerXAnchor.constraint(equalTo:screen.centerXAnchor),empty.centerYAnchor.constraint(equalTo:screen.centerYAnchor),icon.heightAnchor.constraint(equalToConstant:112),icon.widthAnchor.constraint(equalToConstant:112)
        ])
        password.placeholderString="Veency password (optional)";password.toolTip="Kept in memory only."
        devices.target=self;devices.action=#selector(selectionChanged)
        fastButton.target=self;fastButton.action=#selector(toggleVideo);fastButton.isEnabled=false
        audioStatus.font = .systemFont(ofSize:11);audioStatus.textColor = .secondaryLabelColor
        let optionsTitle=NSTextField(labelWithString:"Connection");optionsTitle.font = .systemFont(ofSize:15,weight:.semibold)
        let note=NSTextField(wrappingLabelWithString:"Direct video is an experimental 320 × 480 stream. Veency provides the sharper image and handles input. Audio and direct video require the iPod helpers.");note.font = .systemFont(ofSize:11);note.textColor = .secondaryLabelColor
        let options=NSStackView(views:[optionsTitle,devices,password,connectButton,fastButton,audioStatus,note]);options.orientation = .vertical;options.alignment = .leading;options.spacing=12;options.edgeInsets=NSEdgeInsets(top:18,left:18,bottom:18,right:18)
        options.translatesAutoresizingMaskIntoConstraints=false
        let controller=NSViewController();controller.view=NSView();controller.view.addSubview(options)
        NSLayoutConstraint.activate([options.leadingAnchor.constraint(equalTo:controller.view.leadingAnchor),options.trailingAnchor.constraint(equalTo:controller.view.trailingAnchor),options.topAnchor.constraint(equalTo:controller.view.topAnchor),options.bottomAnchor.constraint(equalTo:controller.view.bottomAnchor),options.widthAnchor.constraint(equalToConstant:320),devices.widthAnchor.constraint(equalToConstant:284),password.widthAnchor.constraint(equalToConstant:284),note.widthAnchor.constraint(equalToConstant:284)])
        optionsPopover.contentViewController=controller;optionsPopover.behavior = .transient
        selectedSerial=UserDefaults.standard.string(forKey:"SelectedUSBDevice")
        screen.onPointer={ [weak self] x,y,b in guard let self=self else{return};let px=self.directVideo == nil ? x : x*self.controlWidth/320;let py=self.directVideo == nil ? y : y*self.controlHeight/480;self.send { try $0.pointer(x:px,y:py,buttons:b) } }
        screen.onKey={ [weak self] code,down in self?.send {try $0.key(code,down:down)} }
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        scan();pollTimer=Timer.scheduledTimer(withTimeInterval:3,repeats:true) { [weak self] _ in self?.scan() }
    }
    @objc func showOptions(_ sender:NSButton) {optionsPopover.show(relativeTo:sender.bounds,of:sender,preferredEdge:.maxY)}
    func scan() {
        guard !scanning else{return};scanning=true
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let result=Result {try USBDevice.list()}
            DispatchQueue.main.async {
                guard let self=self else{return};self.scanning=false
                if case .success(let list)=result {
                    let serial=self.selectedSerial ?? self.found.first?.serial
                    self.found=list;self.devices.removeAllItems()
                    if list.isEmpty {self.devices.addItem(withTitle:"No USB device connected")}
                    else {self.devices.addItems(withTitles:list.map(\.label));if let i=list.firstIndex(where:{$0.serial==serial}) {self.devices.selectItem(at:i)}}
                    if self.state == .idle { self.connectButton.isEnabled = !list.isEmpty }
                } else if self.state == .idle { self.status.stringValue="Apple’s USB service is unavailable. Connect your iPod and try again." }
            }
        }
    }
    @objc func selectionChanged() { if state == .idle, found.indices.contains(devices.indexOfSelectedItem) { selectedSerial=found[devices.indexOfSelectedItem].serial } }
    @objc func toggleConnection() {
        if state != .idle { stop();return }
        guard found.indices.contains(devices.indexOfSelectedItem) else{return}
        selectedSerial=found[devices.indexOfSelectedItem].serial
        UserDefaults.standard.set(selectedSerial,forKey:"SelectedUSBDevice");optionsPopover.performClose(nil)
        wantsReconnect=false
        start(found[devices.indexOfSelectedItem])
    }
    func start(_ device:USBDevice) {
        reconnectTimer?.invalidate();reconnectTimer=nil
        generation=UUID();let token=generation,secret=password.stringValue
        state = .connecting;connectButton.title="Cancel";connectButton.isEnabled=true;devices.isEnabled=false;password.isEnabled=false
        status.stringValue="Connecting over USB…";subtitle.stringValue="Unlock your iPod and approve access if asked."
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            do {
                let wire=try device.connect(),rfb=RFB(wire)
                DispatchQueue.main.sync { if self?.generation==token { self?.pendingWire=wire } else {wire.cancel()} }
                rfb.onStatus={ message in DispatchQueue.main.async {guard let self=self,self.generation==token else{return};self.status.stringValue=message} }
                rfb.onFrame={ [weak self,weak rfb] frame in if let rfb=rfb {self?.enqueue(frame,token:token,rfb:rfb)} }
                defer {wire.cancel()}
                try rfb.run(password:secret)
            } catch {
                DispatchQueue.main.async {
                    guard let self=self,self.generation==token else{return}
                    let retry=self.wantsReconnect
                    self.stopAudio();self.stopVideo();self.connection=nil;self.pendingWire=nil;self.screen.releaseInput();self.setControls(false)
                    self.screen.frameImage=nil;self.empty.isHidden=false
                    self.state = retry ? .waiting : .idle
                    self.status.stringValue=error.localizedDescription
                    self.connectButton.title=retry ? "Stop" : "Connect";self.devices.isEnabled = !retry;self.password.isEnabled = !retry
                    self.subtitle.stringValue=retry ? "Waiting for your iPod to reconnect…" : "Your familiar little screen, on your Mac."
                    if retry {self.scheduleReconnect()}
                }
            }
        }
    }
    func scheduleReconnect() {
        reconnectTimer=Timer.scheduledTimer(withTimeInterval:3,repeats:false) { [weak self] _ in
            guard let self=self,self.state == .waiting else{return}
            if let device=self.found.first(where:{$0.serial==self.selectedSerial}) {self.start(device)} else {self.scheduleReconnect()}
        }
    }
    func enqueue(_ frame:Frame,token:UUID,rfb:RFB,direct:Bool=false) {
        // Only one queued display update, even when the main thread is busy.
        frameLock.lock();latestFrame=(frame,token,rfb,direct)
        if scheduledFrame {frameLock.unlock();return};scheduledFrame=true;frameLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self=self else{return}
            self.frameLock.lock();let pending=self.latestFrame;self.latestFrame=nil;self.scheduledFrame=false;self.frameLock.unlock()
            guard let (frame,frameToken,rfb,isDirect)=pending,self.generation==frameToken else{return}
            if !isDirect {self.controlWidth=frame.width;self.controlHeight=frame.height;if self.directVideo != nil && self.state == .connected {return}}
            else if self.directVideo == nil {return}
            guard let provider=CGDataProvider(data:frame.pixels as CFData),let image=CGImage(width:frame.width,height:frame.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:frame.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else{return}
            let first=self.state != .connected
            self.connection=rfb;self.wantsReconnect=true;self.state = .connected;self.screen.frameImage=image;self.empty.isHidden=true;self.setControls(true);self.connectButton.title="Disconnect"
            self.subtitle.stringValue="USB · \(frame.width) × \(frame.height) · \(isDirect ? "Direct video" : "Veency")";self.status.stringValue="Click to tap. Drag to swipe. Click the screen to type."
            if first {self.window.makeFirstResponder(self.screen);if self.audioButton.state == .on {self.startAudio()};if self.fastButton.state == .on {self.startVideo()}}
        }
    }
    func setControls(_ enabled:Bool) {audioButton.isEnabled=enabled;fastButton.isEnabled=enabled;for b in [home,lockButton,screenshotButton] {b.isEnabled=enabled}}
    func send(_ action:@escaping(RFB)throws->Void) {
        guard let rfb=connection,state == .connected else{return}
        inputQueue.async {do {try action(rfb)} catch {rfb.wire.cancel()}}
    }
    @objc func goHome() { send { try $0.pointer(x:0,y:0,buttons:4);try $0.pointer(x:0,y:0,buttons:0) } }
    @objc func goLock() { send { try $0.pointer(x:0,y:0,buttons:2);try $0.pointer(x:0,y:0,buttons:0) } }
    @objc func saveScreenshot() {
        guard let image=screen.frameImage else{return}
        let panel=NSSavePanel();panel.nameFieldStringValue="iPod Screenshot.png";panel.allowedContentTypes=[.png]
        panel.beginSheetModal(for:window) { result in
            guard result == .OK,let url=panel.url else{return}
            do {guard let data=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else{throw fail("Could not encode screenshot.")};try data.write(to:url)} catch {NSAlert(error:error).runModal()}
        }
    }
    @objc func toggleVideo() {if fastButton.state == .on {startVideo()} else {stopVideo();if let rfb=connection {inputQueue.async {try? rfb.request(incremental:false)}}}}
    func startVideo() {
        stopVideo();guard let device=found.first(where:{$0.serial==selectedSerial}),let rfb=connection else{return}
        let video=DirectVideo(),token=UUID(),session=generation;videoGeneration=token;directVideo=video
        video.onFrame={ [weak self,weak rfb] frame in if let rfb=rfb {self?.enqueue(frame,token:session,rfb:rfb,direct:true)} }
        video.onError={ [weak self] message in DispatchQueue.main.async {guard let self=self,self.videoGeneration==token else{return};self.stopVideo();self.fastButton.state = .off;self.status.stringValue="Direct video unavailable. Veency remains connected. " + message;self.inputQueue.async {try? rfb.request(incremental:false)}}}
        video.start(device:device)
    }
    func stopVideo() {videoGeneration=UUID();directVideo?.stop();directVideo=nil}
    @objc func toggleAudio() {if audioButton.state == .on {startAudio()} else {stopAudio()}}
    func startAudio() {
        stopAudio();guard let device=found.first(where:{$0.serial==selectedSerial}) else{return}
        let receiver=AudioReceiver(),token=UUID();audioGeneration=token;audio=receiver;audioStatus.stringValue="Connecting audio…"
        receiver.onStatus={ [weak self] message in DispatchQueue.main.async {guard let self=self,self.audioGeneration==token else{return};self.audioStatus.stringValue=message}}
        receiver.start(device:device)
    }
    func stopAudio() {audioGeneration=UUID();audio?.stop();audio=nil;audioStatus.stringValue="Audio off"}
    func stop() {
        stopAudio();stopVideo()
        screen.releaseInput();wantsReconnect=false;generation=UUID();reconnectTimer?.invalidate();reconnectTimer=nil;pendingWire?.cancel();connection?.wire.cancel();pendingWire=nil;connection=nil
        state = .idle;screen.frameImage=nil;empty.isHidden=false;setControls(false);connectButton.title="Connect";connectButton.isEnabled = !found.isEmpty;devices.isEnabled=true;password.isEnabled=true
        subtitle.stringValue="Your familiar little screen, on your Mac.";status.stringValue="Disconnected. Your apps and data stay on the iPod."
    }
    func windowDidResignKey(_ notification:Notification) {screen.releaseInput()}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
    func applicationWillTerminate(_ notification:Notification) {stop();password.stringValue="";pollTimer?.invalidate()}
}
@main struct Main {
    static func main() { let app=NSApplication.shared;let delegate=MirrorApp();app.delegate=delegate;app.run();withExtendedLifetime(delegate){} }
}
