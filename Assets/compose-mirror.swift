import AppKit
let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1024,pixelsHigh:1024,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep);NSGraphicsContext.current?.imageInterpolation = .high
let mirror=NSImage(contentsOfFile:"Assets/Mirror-Backdrop.png")!
let ipod=NSImage(contentsOfFile:"Assets/iPod-Flat.png")!
mirror.draw(in:NSRect(x:-70,y:125,width:900,height:900))
// The reflection and foreground both use the exact original photographic iPod pixels.
NSGraphicsContext.saveGraphicsState()
let flip=NSAffineTransform();flip.translateX(by:550,yBy:0);flip.scaleX(by:-1,yBy:1);flip.concat()
ipod.draw(in:NSRect(x:-30,y:240,width:650,height:650),from:.zero,operation:.sourceOver,fraction:0.32)
NSGraphicsContext.restoreGraphicsState()
let shadow=NSShadow();shadow.shadowColor=NSColor.black.withAlphaComponent(0.45);shadow.shadowBlurRadius=16;shadow.shadowOffset=NSSize(width:-8,height:-8);shadow.set()
ipod.draw(in:NSRect(x:215,y:0,width:950,height:950))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"Assets/AppIcon-Mirror.png"))
