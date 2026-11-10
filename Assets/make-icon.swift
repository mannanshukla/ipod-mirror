import AppKit
let source=NSImage(contentsOfFile:"Assets/iPod-Website.png")!
let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1024,pixelsHigh:1024,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
NSGraphicsContext.current?.imageInterpolation = .high
let h:CGFloat=960,w=h*source.size.width/source.size.height
source.draw(in:NSRect(x:(1024-w)/2,y:32,width:w,height:h))
// Preserve the existing photographic body, replacing only its screen with the archived iOS 4 Home screen.
let home=NSImage(contentsOfFile:"Assets/iPod-Home-Reference.png")!
home.draw(in:NSRect(x:(1024-w)/2+47*w/534,y:32+(1000-168-667)*h/1000,width:445*w/534,height:667*h/1000),from:NSRect(x:22,y:home.size.height-92-381,width:254,height:381),operation:.copy,fraction:1)
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"Assets/AppIcon.png"))
