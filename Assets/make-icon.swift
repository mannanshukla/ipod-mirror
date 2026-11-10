import AppKit
let source=NSImage(contentsOfFile:"Assets/iPod-Website.png")!
let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1024,pixelsHigh:1024,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
NSGraphicsContext.current?.imageInterpolation = .high
let h:CGFloat=960,w=h*source.size.width/source.size.height
source.draw(in:NSRect(x:(1024-w)/2,y:32,width:w,height:h))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"Assets/AppIcon.png"))
