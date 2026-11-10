import AppKit

/// Uses the system material, including its accessibility and appearance behavior.
func glass(_ content:NSView, radius:CGFloat=22, inset:CGFloat=10) -> NSView {
    let host:NSView
    let container=NSView()
    if #available(macOS 26.0, *) {
        let effect=NSGlassEffectView();effect.style = .regular;effect.cornerRadius=radius;effect.contentView=container
        if #available(macOS 27.0, *) {effect.effectIsInteractive=true}
        host=effect
    } else {
        let effect=NSVisualEffectView();effect.material = .hudWindow;effect.blendingMode = .behindWindow;effect.state = .active
        effect.wantsLayer=true;effect.layer?.cornerRadius=radius;effect.layer?.masksToBounds=true
        container.translatesAutoresizingMaskIntoConstraints=false;effect.addSubview(container)
        NSLayoutConstraint.activate([container.leadingAnchor.constraint(equalTo:effect.leadingAnchor),container.trailingAnchor.constraint(equalTo:effect.trailingAnchor),container.topAnchor.constraint(equalTo:effect.topAnchor),container.bottomAnchor.constraint(equalTo:effect.bottomAnchor)])
        host=effect
    }
    content.translatesAutoresizingMaskIntoConstraints=false;container.addSubview(content)
    NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo:container.leadingAnchor,constant:inset),content.trailingAnchor.constraint(equalTo:container.trailingAnchor,constant:-inset),content.topAnchor.constraint(equalTo:container.topAnchor,constant:inset),content.bottomAnchor.constraint(equalTo:container.bottomAnchor,constant:-inset)])
    return host
}
func symbolButton(_ button:NSButton, name:String, label:String) {
    button.title="";button.image=NSImage(systemSymbolName:name,accessibilityDescription:label)
    button.imagePosition = .imageOnly;button.bezelStyle = .rounded;button.isBordered=false
    button.toolTip=label;button.setAccessibilityLabel(label)
    button.translatesAutoresizingMaskIntoConstraints=false
    NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant:38),button.heightAnchor.constraint(equalToConstant:34)])
    button.contentTintColor = .labelColor
}
