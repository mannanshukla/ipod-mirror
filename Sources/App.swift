import AppKit

final class ScreenView: NSView {
    var frameImage: CGImage? { didSet { needsDisplay=true } }
    var onPointer: ((Int,Int,UInt8)->Void)?
    var onKey: ((UInt32,Bool)->Void)?
    /// Two-finger input. Points are normalized to the screen image (0…1, origin top-left).
    var onTouches: ((TouchPhase,[CGPoint])->Void)?
    var multitouchEnabled=false { didSet { if !multitouchEnabled {cancelFingers()};needsDisplay=true } }
    private var dragging=false
    // Trackpad two-finger scroll drives one finger from the pointer (swipe home screens, scroll lists). View coordinates.
    private var scrollFinger:CGPoint?
    private var scrollRejected=false // A scroll that started during another gesture stays ignored until it ends.
    private var rightDown=false
    // Two-finger state. ⌥-drag mirrors a second finger through the screen centre (pinch and rotate);
    // ⌥⇧-drag moves both fingers together; trackpad pinch and rotate gestures drive two fingers around the pointer.
    private enum Fingers { case mirrored, parallel(offset:CGPoint), trackpad(anchor:CGPoint) }
    private var fingers:Fingers?
    private var fingerPoints=[CGPoint]()
    private var hover:CGPoint?
    private var optionHeld=false
    private var magnification:CGFloat=0,rotation:CGFloat=0,magnifying=false,rotating=false
    private var tracking:NSTrackingArea?
    // The touch helper cancels a held gesture after about 3 s of silence, so a still hold repeats its position each second.
    private var keepalive:Timer?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
        // Show where the two fingers are (or would land) while ⌥ is held or a two-finger gesture runs.
        var shown=fingerPoints
        if shown.isEmpty,optionHeld,multitouchEnabled,let p=hover {shown=[p,mirror(p)]}
        let r=imageRect
        for p in shown {
            let c=NSPoint(x:r.minX+p.x*r.width,y:r.minY+p.y*r.height),dot=NSBezierPath(ovalIn:NSRect(x:c.x-11,y:c.y-11,width:22,height:22))
            NSColor(calibratedWhite:1,alpha:fingerPoints.isEmpty ? 0.25:0.45).setFill();dot.fill()
            NSColor(calibratedWhite:0,alpha:0.35).setStroke();dot.lineWidth=1.5;dot.stroke()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t=tracking {removeTrackingArea(t)}
        let t=NSTrackingArea(rect:.zero,options:[.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(t);tracking=t
    }
    private func normalized(_ event:NSEvent)->CGPoint? {
        let p=convert(event.locationInWindow,from:nil),r=imageRect
        guard frameImage != nil,r.width>0,r.height>0 else {return nil}
        return CGPoint(x:(p.x-r.minX)/r.width,y:(p.y-r.minY)/r.height)
    }
    private func clamp(_ p:CGPoint)->CGPoint {CGPoint(x:max(0,min(1,p.x)),y:max(0,min(1,p.y)))}
    private func mirror(_ p:CGPoint)->CGPoint {clamp(CGPoint(x:1-p.x,y:1-p.y))}
    private func moveFingers(_ phase:TouchPhase,_ points:[CGPoint]) {
        let done=phase == .ended || phase == .cancelled
        fingerPoints=done ? [] : points;needsDisplay=true
        onTouches?(phase,points)
        if done {keepalive?.invalidate();keepalive=nil}
        else if keepalive == nil {
            let timer=Timer(timeInterval:1,repeats:true) { [weak self] _ in guard let self=self,!self.fingerPoints.isEmpty else{return};self.onTouches?(.moved,self.fingerPoints) }
            RunLoop.main.add(timer,forMode:.common);keepalive=timer // .common keeps it firing during mouse-drag tracking.
        }
    }
    private func cancelFingers() {
        if fingers != nil,!fingerPoints.isEmpty {onTouches?(.cancelled,fingerPoints)}
        keepalive?.invalidate();keepalive=nil
        fingers=nil;fingerPoints=[];magnifying=false;rotating=false;needsDisplay=true
    }
    override func flagsChanged(with e:NSEvent) {
        optionHeld=e.modifierFlags.contains(.option);needsDisplay=true;super.flagsChanged(with:e)
    }
    override func mouseMoved(with e:NSEvent) {
        optionHeld=e.modifierFlags.contains(.option)
        hover=normalized(e).flatMap {imageRect.contains(convert(e.locationInWindow,from:nil)) ? $0:nil}
        if optionHeld {needsDisplay=true}
    }
    override func mouseExited(with e:NSEvent) {
        hover=nil;needsDisplay=true
        // Scroll events go to whatever view is under the pointer, so the end of this one may never arrive here.
        if let f=scrollFinger {scrollFinger=nil;point(f,buttons:0)}
    }
    // Trackpad pinch and rotate: two fingers around the pointer, 15% of the screen width apart at rest.
    private func trackpadFingers()->[CGPoint]? {
        guard case .trackpad(let a)? = fingers else {return nil}
        let r=imageRect,aspect=r.height/max(r.width,1)
        let radius=max(0.03,0.15*(1+magnification)),angle=rotation*CGFloat.pi/180
        let dx=radius*cos(angle),dy=radius*sin(angle)/aspect
        return [clamp(CGPoint(x:a.x-dx,y:a.y+dy)),clamp(CGPoint(x:a.x+dx,y:a.y-dy))]
    }
    private func trackpad(_ e:NSEvent,magnify:Bool) {
        guard multitouchEnabled,!dragging,scrollFinger == nil else {return}
        switch e.phase {
        case .began:
            if fingers == nil {
                guard let p=normalized(e),imageRect.contains(convert(e.locationInWindow,from:nil)) else {return}
                magnification=0;rotation=0;fingers = .trackpad(anchor:p)
                if magnify {magnifying=true} else {rotating=true}
                if let f=trackpadFingers() {moveFingers(.began,f)}
            } else if case .trackpad = fingers {if magnify {magnifying=true} else {rotating=true}}
        case .changed:
            guard case .trackpad = fingers else {return}
            if magnify {magnification+=e.magnification} else {rotation+=CGFloat(e.rotation)}
            if let f=trackpadFingers() {moveFingers(.moved,f)}
        case .ended,.cancelled:
            guard case .trackpad = fingers else {return}
            if magnify {magnifying=false} else {rotating=false}
            if !magnifying && !rotating {let f=fingerPoints;fingers=nil;if !f.isEmpty {moveFingers(e.phase == .ended ? .ended:.cancelled,f)}}
        default: break
        }
    }
    override func magnify(with e:NSEvent) {trackpad(e,magnify:true)}
    override func rotate(with e:NSEvent) {trackpad(e,magnify:false)}
    private func point(_ event:NSEvent,buttons:UInt8) {
        let p=convert(event.locationInWindow,from:nil)
        if buttons != 0 && !dragging && !imageRect.contains(p) { return }
        point(p,buttons:buttons)
    }
    private func point(_ p:NSPoint,buttons:UInt8) {
        guard let image=frameImage else { return }
        let r=imageRect
        let x=max(0,min(image.width-1,Int((p.x-r.minX)*CGFloat(image.width)/r.width)))
        let y=max(0,min(image.height-1,Int((p.y-r.minY)*CGFloat(image.height)/r.height)))
        onPointer?(x,y,buttons)
    }
    override func mouseDown(with e:NSEvent) {
        window?.makeFirstResponder(self);guard fingers == nil,scrollFinger == nil,imageRect.contains(convert(e.locationInWindow,from:nil)) else{return}
        if multitouchEnabled,e.modifierFlags.contains(.option),let p=normalized(e) {
            let second=mirror(p)
            fingers=e.modifierFlags.contains(.shift) ? .parallel(offset:CGPoint(x:second.x-p.x,y:second.y-p.y)) : .mirrored
            moveFingers(.began,[clamp(p),second]);return
        }
        dragging=true;point(e,buttons:1)
    }
    private func dragFingers(_ e:NSEvent)->[CGPoint]? {
        guard let p=normalized(e).map(clamp) else {return nil}
        switch fingers {
        case .mirrored?: return [p,mirror(p)]
        case .parallel(let o)?: return [p,clamp(CGPoint(x:p.x+o.x,y:p.y+o.y))]
        default: return nil
        }
    }
    override func mouseDragged(with e:NSEvent) {
        if let f=dragFingers(e) {moveFingers(.moved,f);return}
        if dragging {point(e,buttons:1)}
    }
    override func mouseUp(with e:NSEvent) {
        if let f=dragFingers(e) {fingers=nil;moveFingers(.ended,f);return}
        if dragging {point(e,buttons:0)};dragging=false
    }
    override func scrollWheel(with e:NSEvent) {
        // Only trackpad and Magic Mouse touches; momentum after lift-off and clicky wheels are ignored.
        guard e.hasPreciseScrollingDeltas,e.momentumPhase.isEmpty else {return}
        let r=imageRect,ending=e.phase.contains(.ended) || e.phase.contains(.cancelled)
        if e.phase.contains(.began) {scrollRejected=false}
        // Start at .began, or mid-gesture when the pointer slid in from outside the view.
        if scrollFinger == nil,!scrollRejected,!ending,e.phase.contains(.began) || e.phase.contains(.changed) {
            let p=convert(e.locationInWindow,from:nil)
            guard frameImage != nil,fingers == nil,!dragging,!rightDown,r.contains(p) else {if e.phase.contains(.began) {scrollRejected=true};return}
            scrollFinger=p;point(p,buttons:1)
        }
        if ending {scrollRejected=false}
        guard var f=scrollFinger else {return}
        if e.phase.contains(.changed) || e.phase.contains(.began) {
            // The finger follows the hand: with natural scrolling the deltas already point that way.
            let sign:CGFloat=e.isDirectionInvertedFromDevice ? 1:-1
            f.x=max(r.minX,min(r.maxX-1,f.x+sign*e.scrollingDeltaX));f.y=max(r.minY,min(r.maxY-1,f.y+sign*e.scrollingDeltaY))
            scrollFinger=f;point(f,buttons:1)
        }
        if ending {scrollFinger=nil;point(f,buttons:0)}
    }
    // Right click is Veency's Home button; skip it while a finger is down so it can't break the touch.
    override func rightMouseDown(with e:NSEvent) { guard !dragging,fingers == nil,scrollFinger == nil else{return};rightDown=true;point(e,buttons:4) }
    override func rightMouseUp(with e:NSEvent) { guard rightDown else{return};rightDown=false;point(e,buttons:0) }
    func releaseInput() { cancelFingers();dragging=false;scrollFinger=nil;scrollRejected=false;rightDown=false;onPointer?(0,0,0) }
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
    var touch:TouchChannel?
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
    let settingsButton=NSButton(title:"Connection settings",target:nil,action:nil)
    @objc func openSettings() {showOptions(settingsButton)}
    func applicationDidFinishLaunching(_ note:Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu=NSMenu(),appMenu=NSMenu(),item=NSMenuItem();menu.addItem(item);item.submenu=appMenu
        appMenu.addItem(withTitle:"About iPod Mirror",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:"")
        appMenu.addItem(.separator());appMenu.addItem(withTitle:"Quit iPod Mirror",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let control=NSMenu(),controlItem=NSMenuItem(title:"iPod",action:nil,keyEquivalent:"");menu.addItem(controlItem);controlItem.submenu=control
        for (title,action,key) in [("Home",#selector(goHome),"1"),("Lock",#selector(goLock),"l"),("Save Screenshot…",#selector(saveScreenshot),"s"),("Connection Settings…",#selector(openSettings),",")] {
            let item=control.addItem(withTitle:title,action:action,keyEquivalent:key);item.target=self
        }
        NSApp.mainMenu=menu
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:336,height:528),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title="iPod Mirror";window.titleVisibility = .hidden;window.titlebarAppearsTransparent=true
        window.minSize=NSSize(width:280,height:444);window.collectionBehavior = .fullScreenNone
        window.delegate=self;window.isReleasedWhenClosed=false;window.isOpaque=false;window.backgroundColor = .clear
        window.hasShadow=true
        let root=NSView();root.wantsLayer=true;root.layer?.backgroundColor=NSColor(calibratedWhite:0.07,alpha:1).cgColor
        root.layer?.cornerRadius=20;root.layer?.borderWidth=1;root.layer?.borderColor=NSColor(calibratedWhite:0.5,alpha:0.55).cgColor;root.layer?.masksToBounds=true
        window.contentView=root
        let barContent=NSView()
        let glassBar=glass(barContent,radius:18,inset:0)
        glassBar.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(glassBar)
        NSLayoutConstraint.activate([glassBar.leadingAnchor.constraint(equalTo:root.leadingAnchor),glassBar.trailingAnchor.constraint(equalTo:root.trailingAnchor),glassBar.topAnchor.constraint(equalTo:root.topAnchor),glassBar.heightAnchor.constraint(equalToConstant:32)])
        subtitle.textColor = .secondaryLabelColor;subtitle.font = .systemFont(ofSize:11)
        subtitle.stringValue="Your iPod, right here."
        let settings=settingsButton;settings.target=self;settings.action=#selector(showOptions)
        symbolButton(settings,name:"slider.horizontal.3",label:"Connection settings · ⌘,")
        connectButton.target=self;connectButton.action=#selector(toggleConnection);connectButton.bezelStyle = .rounded
        home.target=self;home.action=#selector(goHome);lockButton.target=self;lockButton.action=#selector(goLock);screenshotButton.target=self;screenshotButton.action=#selector(saveScreenshot)
        symbolButton(home,name:"app",label:"Home · ⌘1");symbolButton(lockButton,name:"lock",label:"Lock iPod · ⌘L");symbolButton(screenshotButton,name:"camera",label:"Save screenshot · ⌘S")
        audioButton.setButtonType(.toggle);audioButton.target=self;audioButton.action=#selector(toggleAudio)
        symbolButton(audioButton,name:"speaker.wave.2",label:"Play iPod audio on Mac")
        let toolbar=NSStackView(views:[home,lockButton,screenshotButton,audioButton,settings]);toolbar.orientation = .horizontal;toolbar.spacing=2
        for button in [home,lockButton,screenshotButton,audioButton] {button.isEnabled=false}
        status.font = .systemFont(ofSize:11);status.textColor = .secondaryLabelColor;status.maximumNumberOfLines=3
        screen.wantsLayer=true;screen.layer?.cornerRadius=16;screen.layer?.masksToBounds=true
        let icon=NSImageView(image:NSImage(named:NSImage.Name("AppIcon")) ?? NSImage());icon.imageScaling = .scaleProportionallyUpOrDown
        let heading=NSTextField(labelWithString:"iPod Mirror");heading.font = .systemFont(ofSize:20,weight:.medium);heading.textColor = .white
        let hint=NSTextField(wrappingLabelWithString:"Plug in your iPod, then open\nConnection settings to begin.");hint.alignment = .center;hint.textColor = .lightGray;hint.font = .systemFont(ofSize:12)
        empty.setViews([icon,heading,hint],in:.center);empty.orientation = .vertical;empty.spacing=14;empty.alignment = .centerX
        for view in [screen,toolbar] {view.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(view)}
        empty.translatesAutoresizingMaskIntoConstraints=false;screen.addSubview(empty)
        NSLayoutConstraint.activate([
            screen.topAnchor.constraint(equalTo:root.topAnchor,constant:32),screen.heightAnchor.constraint(equalTo:screen.widthAnchor,multiplier:1.5),screen.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:4),screen.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-4),screen.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-4),
            toolbar.topAnchor.constraint(equalTo:root.topAnchor,constant:4),toolbar.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-9),toolbar.heightAnchor.constraint(equalToConstant:24),
            empty.centerXAnchor.constraint(equalTo:screen.centerXAnchor),empty.centerYAnchor.constraint(equalTo:screen.centerYAnchor),icon.heightAnchor.constraint(equalToConstant:100),icon.widthAnchor.constraint(equalToConstant:100)
        ])
        password.placeholderString="Veency password (optional)";password.toolTip="Kept in memory only."
        devices.target=self;devices.action=#selector(selectionChanged)
        fastButton.target=self;fastButton.action=#selector(toggleVideo);fastButton.isEnabled=false
        audioStatus.font = .systemFont(ofSize:11);audioStatus.textColor = .secondaryLabelColor
        let optionsTitle=NSTextField(labelWithString:"Connection");optionsTitle.font = .systemFont(ofSize:15,weight:.semibold)
        let note=NSTextField(wrappingLabelWithString:"Direct video is an experimental 320 × 480 stream. Veency provides the sharper image and handles input. Audio and direct video require the iPod helpers.");note.font = .systemFont(ofSize:11);note.textColor = .secondaryLabelColor
        let options=NSStackView(views:[optionsTitle,subtitle,devices,password,connectButton,fastButton,audioStatus,status,note]);options.orientation = .vertical;options.alignment = .leading;options.spacing=12;options.edgeInsets=NSEdgeInsets(top:18,left:18,bottom:18,right:18)
        options.translatesAutoresizingMaskIntoConstraints=false
        let controller=NSViewController();controller.view=NSView();controller.view.addSubview(options)
        NSLayoutConstraint.activate([options.leadingAnchor.constraint(equalTo:controller.view.leadingAnchor),options.trailingAnchor.constraint(equalTo:controller.view.trailingAnchor),options.topAnchor.constraint(equalTo:controller.view.topAnchor),options.bottomAnchor.constraint(equalTo:controller.view.bottomAnchor),options.widthAnchor.constraint(equalToConstant:320),devices.widthAnchor.constraint(equalToConstant:284),password.widthAnchor.constraint(equalToConstant:284),note.widthAnchor.constraint(equalToConstant:284)])
        optionsPopover.contentViewController=controller;optionsPopover.behavior = .transient
        selectedSerial=UserDefaults.standard.string(forKey:"SelectedUSBDevice")
        screen.onPointer={ [weak self] x,y,b in guard let self=self else{return};let px=self.directVideo == nil ? x : x*self.controlWidth/320;let py=self.directVideo == nil ? y : y*self.controlHeight/480;self.send { try $0.pointer(x:px,y:py,buttons:b) } }
        screen.onKey={ [weak self] code,down in self?.send {try $0.key(code,down:down)} }
        screen.onTouches={ [weak self] phase,points in guard let self=self,self.state == .connected else{return};self.touch?.send(phase,points) }
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        scan();pollTimer=Timer.scheduledTimer(withTimeInterval:3,repeats:true) { [weak self] _ in self?.scan() }
    }
    func windowWillResize(_ sender:NSWindow,to frameSize:NSSize) -> NSSize { NSSize(width:frameSize.width,height:(frameSize.width-8)*1.5+36) }
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
                    self.stopAudio();self.stopVideo();self.stopTouch();self.connection=nil;self.pendingWire=nil;self.screen.releaseInput();self.setControls(false)
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
            self.subtitle.stringValue="USB · \(frame.width) × \(frame.height) · \(isDirect ? "Direct video" : "Veency")";if first {self.status.stringValue="Click to tap. Drag or two-finger swipe to scroll. ⌥-drag or pinch on the trackpad for two fingers. Click the screen to type."}
            if first {self.startTouch();self.window.makeFirstResponder(self.screen);if self.audioButton.state == .on {self.startAudio()};if self.fastButton.state == .on {self.startVideo()}}
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
    func startTouch() {
        stopTouch();guard let device=found.first(where:{$0.serial==selectedSerial}) else{return}
        let channel=TouchChannel(device:device),session=generation;touch=channel
        channel.onStatus={ [weak self,weak channel] message in DispatchQueue.main.async {guard let self=self,let channel=channel,self.generation==session,self.touch === channel else{return};self.status.stringValue=message} }
        screen.multitouchEnabled=true
    }
    func stopTouch() {screen.multitouchEnabled=false;touch?.stop();touch=nil}
    @objc func toggleAudio() {if audioButton.state == .on {startAudio()} else {stopAudio()}}
    func startAudio() {
        stopAudio();guard let device=found.first(where:{$0.serial==selectedSerial}) else{return}
        let receiver=AudioReceiver(),token=UUID();audioGeneration=token;audio=receiver;audioStatus.stringValue="Connecting audio…"
        receiver.onStatus={ [weak self] message in DispatchQueue.main.async {guard let self=self,self.audioGeneration==token else{return};self.audioStatus.stringValue=message}}
        receiver.start(device:device)
    }
    func stopAudio() {audioGeneration=UUID();audio?.stop();audio=nil;audioStatus.stringValue="Audio off"}
    func stop() {
        screen.releaseInput();stopAudio();stopVideo();stopTouch();wantsReconnect=false;generation=UUID();reconnectTimer?.invalidate();reconnectTimer=nil;pendingWire?.cancel();connection?.wire.cancel();pendingWire=nil;connection=nil
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
