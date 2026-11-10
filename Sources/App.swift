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
    let empty=NSStackView()
    var found=[USBDevice]()
    var state=State.idle
    var generation=UUID()
    var selectedSerial:String?
    var connection:RFB?
    var pendingWire:Wire?
    var reconnectTimer:Timer?
    let inputQueue=DispatchQueue(label:"dev.mannan.ipodmirror.input")
    var latestFrame:(Frame, UUID, RFB)?
    var frameLock=NSLock(), scheduledFrame=false
    var pollTimer:Timer?
    var scanning=false
    var wantsReconnect=false
    func applicationDidFinishLaunching(_ note:Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu=NSMenu(),appMenu=NSMenu(),item=NSMenuItem();menu.addItem(item);item.submenu=appMenu
        appMenu.addItem(withTitle:"About iPod Mirror",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:"")
        appMenu.addItem(.separator());appMenu.addItem(withTitle:"Quit iPod Mirror",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let control=NSMenu(),controlItem=NSMenuItem(title:"iPod",action:nil,keyEquivalent:"");menu.addItem(controlItem);controlItem.submenu=control
        for (title,action,key) in [("Home",#selector(goHome),"h"),("Lock",#selector(goLock),"l"),("Save Screenshot…",#selector(saveScreenshot),"s")] {
            let item=control.addItem(withTitle:title,action:action,keyEquivalent:key);item.target=self
        }
        NSApp.mainMenu=menu
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:460,height:820),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="iPod Mirror";window.minSize=NSSize(width:390,height:640);window.delegate=self;window.isReleasedWhenClosed=false
        let root=NSView();window.contentView=root
        let title=NSTextField(labelWithString:"iPod Mirror");title.font = .systemFont(ofSize:23,weight:.semibold)
        subtitle.textColor = .secondaryLabelColor;subtitle.font = .systemFont(ofSize:12)
        password.placeholderString="Veency password (if set)";password.toolTip="Kept in memory only. Not saved or sent anywhere except the selected USB device."
        devices.target=self;devices.action=#selector(selectionChanged)
        connectButton.target=self;connectButton.action=#selector(toggleConnection);connectButton.bezelStyle = .rounded
        home.target=self;home.action=#selector(goHome);lockButton.target=self;lockButton.action=#selector(goLock);screenshotButton.target=self;screenshotButton.action=#selector(saveScreenshot)
        for b in [home,lockButton,screenshotButton] { b.bezelStyle = .rounded;b.isEnabled=false }
        let chooser=NSStackView(views:[devices,connectButton]);chooser.orientation = .horizontal;chooser.spacing=8
        devices.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let header=NSStackView(views:[title,subtitle,chooser,password]);header.orientation = .vertical;header.alignment = .leading;header.spacing=8
        let bottom=NSStackView(views:[home,lockButton,screenshotButton]);bottom.orientation = .horizontal;bottom.spacing=12
        status.font = .systemFont(ofSize:11);status.textColor = .secondaryLabelColor;status.maximumNumberOfLines=3
        screen.wantsLayer=true;screen.layer?.cornerRadius=12;screen.layer?.masksToBounds=true
        let icon=NSImageView(image:NSImage(systemSymbolName:"ipodtouch",accessibilityDescription:"iPod") ?? NSImage());icon.contentTintColor = .white
        let heading=NSTextField(labelWithString:"A little closer.");heading.font = .systemFont(ofSize:21,weight:.medium);heading.textColor = .white
        let hint=NSTextField(wrappingLabelWithString:"Plug in your jailbroken iPod.\nEnable Veency, unlock the screen,\nthen choose Connect.");hint.alignment = .center;hint.textColor = .lightGray;hint.font = .systemFont(ofSize:13)
        empty.setViews([icon,heading,hint],in:.center);empty.orientation = .vertical;empty.spacing=16;empty.alignment = .centerX
        for view in [header,screen,bottom,status] {view.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(view)}
        empty.translatesAutoresizingMaskIntoConstraints=false;screen.addSubview(empty)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo:root.topAnchor,constant:18),header.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:20),header.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-20),
            chooser.widthAnchor.constraint(equalTo:header.widthAnchor),password.widthAnchor.constraint(equalTo:header.widthAnchor),
            screen.topAnchor.constraint(equalTo:header.bottomAnchor,constant:16),screen.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:20),screen.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-20),
            bottom.topAnchor.constraint(equalTo:screen.bottomAnchor,constant:12),bottom.centerXAnchor.constraint(equalTo:root.centerXAnchor),
            status.topAnchor.constraint(equalTo:bottom.bottomAnchor,constant:9),status.leadingAnchor.constraint(equalTo:header.leadingAnchor),status.trailingAnchor.constraint(equalTo:header.trailingAnchor),status.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-14),status.heightAnchor.constraint(greaterThanOrEqualToConstant:30),
            empty.centerXAnchor.constraint(equalTo:screen.centerXAnchor),empty.centerYAnchor.constraint(equalTo:screen.centerYAnchor),icon.heightAnchor.constraint(equalToConstant:58),icon.widthAnchor.constraint(equalToConstant:40)
        ])
        screen.onPointer={ [weak self] x,y,b in self?.send { try $0.pointer(x:x,y:y,buttons:b) } }
        screen.onKey={ [weak self] code,down in self?.send {try $0.key(code,down:down)} }
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        scan();pollTimer=Timer.scheduledTimer(withTimeInterval:3,repeats:true) { [weak self] _ in self?.scan() }
    }
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
                    self.connection=nil;self.pendingWire=nil;self.screen.releaseInput();self.setControls(false)
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
    func enqueue(_ frame:Frame,token:UUID,rfb:RFB) {
        // Only one queued display update, even when the main thread is busy.
        frameLock.lock();latestFrame=(frame,token,rfb)
        if scheduledFrame {frameLock.unlock();return};scheduledFrame=true;frameLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self=self else{return}
            self.frameLock.lock();let pending=self.latestFrame;self.latestFrame=nil;self.scheduledFrame=false;self.frameLock.unlock()
            guard let (frame,frameToken,rfb)=pending,self.generation==frameToken else{return}
            guard let provider=CGDataProvider(data:frame.pixels as CFData),let image=CGImage(width:frame.width,height:frame.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:frame.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else{return}
            let first=self.state != .connected
            self.connection=rfb;self.wantsReconnect=true;self.state = .connected;self.screen.frameImage=image;self.empty.isHidden=true;self.setControls(true);self.connectButton.title="Disconnect"
            self.subtitle.stringValue="USB · \(frame.width) × \(frame.height) · Veency";self.status.stringValue="Click to tap. Drag to swipe. Click the screen to type."
            if first {self.window.makeFirstResponder(self.screen)}
        }
    }
    func setControls(_ enabled:Bool) {for b in [home,lockButton,screenshotButton] {b.isEnabled=enabled}}
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
    func stop() {
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
