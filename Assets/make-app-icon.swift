import Cocoa
let folder = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath:folder,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
 for scale in [1,2] {
  let px=size*scale
  let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:px,pixelsHigh:px,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
  NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
  let ctx=NSGraphicsContext.current!.cgContext; ctx.scaleBy(x:CGFloat(px)/1024,y:CGFloat(px)/1024)
  let box=NSBezierPath(roundedRect:NSRect(x:64,y:64,width:896,height:896),xRadius:205,yRadius:205)
  NSGradient(colors:[NSColor(red:0.08,green:0.15,blue:0.25,alpha:1),NSColor(red:0.03,green:0.07,blue:0.13,alpha:1)])!.draw(in:box,angle:70)
  for (radius,fraction,color) in [(290.0,0.86,NSColor.white),(205.0,0.68,NSColor.systemMint),(120.0,0.47,NSColor.systemCyan)] {
   let track=NSBezierPath();track.appendArc(withCenter:NSPoint(x:512,y:512),radius:radius,startAngle:90,endAngle:450)
   track.lineWidth=43; NSColor.white.withAlphaComponent(0.12).setStroke();track.stroke()
   let arc=NSBezierPath();arc.appendArc(withCenter:NSPoint(x:512,y:512),radius:radius,startAngle:90,endAngle:90-360*fraction,clockwise:true)
   arc.lineWidth=43;arc.lineCapStyle = .round;color.setStroke();arc.stroke()
  }
  NSGraphicsContext.restoreGraphicsState()
  let suffix=scale==2 ? "@2x" : ""
  try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"\(folder)/icon_\(size)x\(size)\(suffix).png"))
 }
}
