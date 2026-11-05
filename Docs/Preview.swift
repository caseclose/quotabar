// Documentation renderer. All values are synthetic; no refresh, login or keychain access.
struct PreviewMenu: View {
    var light = false
    var ink: Color { light ? .black : .white }
    var body: some View {
        HStack(spacing:7) {
            Image(systemName:"circle.dotted.circle").foregroundStyle(.mint).padding(.trailing,8)
            entry("codex","95%"); entry("cursor","100/85%"); entry("deepseek","¥128")
            Rectangle().fill(ink.opacity(0.18)).frame(width:1,height:14).padding(.horizontal,10)
            Image(systemName:"wifi"); Image(systemName:"battery.100"); Text("10:24")
        }.font(.system(size:11,weight:.medium)).foregroundStyle(ink.opacity(0.92))
         .padding(.horizontal,18).frame(height:38)
         .background(ink.opacity(light ? 0.045 : 0.055)).clipShape(Capsule())

    }
    func entry(_ asset: String,_ text: String) -> some View {
        HStack(spacing:3) {
            if let url = Bundle.main.url(forResource:asset,withExtension:"png"), let image = NSImage(contentsOf:url) {
                Image(nsImage:image).renderingMode(.template).resizable().scaledToFit().frame(width:15,height:15)
            }
            Text(text).monospacedDigit()
        }
    }
}
struct PreviewHero: View {
    let meter: Meter
    var light = false
    var ink: Color { light ? .black : .white }
    var body: some View {
        ZStack {
            light ? Color(red:0.965,green:0.98,blue:0.99) : Color(red:0.025,green:0.045,blue:0.075)
            RadialGradient(colors:[Color.cyan.opacity(0.14),.clear],center:.topLeading,startRadius:5,endRadius:700)
            RadialGradient(colors:[Color.mint.opacity(0.09),.clear],center:.bottomTrailing,startRadius:5,endRadius:650)
            VStack(spacing:0) {
                HStack(spacing:10) {
                    if let iconURL = Bundle.main.url(forResource:"QuotaBar",withExtension:"icns"), let icon = NSImage(contentsOf:iconURL) { Image(nsImage:icon).resizable().frame(width:32,height:32) }
                    Text("QuotaBar").fontWeight(.semibold)
                }
                    .font(.system(size:19)).foregroundStyle(ink.opacity(0.92)).padding(.top,42)
                Text("额度，一眼可见。").font(.system(size:42,weight:.semibold)).tracking(1).padding(.top,15)
                Text("Codex · Cursor · DeepSeek").font(.system(size:15)).foregroundStyle(ink.opacity(0.58)).padding(.top,12)
                PreviewMenu(light:light).padding(.top,26)
                Panel(meter:meter,settings:{})
                    .environment(\.colorScheme,.dark)
                    .background(Color(red:0.085,green:0.105,blue:0.135))
                    .clipShape(RoundedRectangle(cornerRadius:20))
                    .overlay(RoundedRectangle(cornerRadius:20).stroke(.white.opacity(0.17),lineWidth:1))
                    .shadow(color:.black.opacity(light ? 0.18 : 0.4),radius:30,y:16).padding(.top,18)
                HStack(spacing:30) {
                    Label("原生 macOS",systemImage:"macwindow")
                    Label("60 秒自动刷新",systemImage:"arrow.clockwise")
                    Label("凭据留在本机",systemImage:"lock.shield")
                }.font(.system(size:12)).foregroundStyle(ink.opacity(0.64)).padding(.top,27)
                Text("界面由真实 SwiftUI 组件渲染 · 全部额度为演示数据")
                    .font(.system(size:10)).foregroundStyle(ink.opacity(light ? 0.5 : 0.35)).padding(.top,15).padding(.bottom,30)
            }.padding(.horizontal,40)
        }.frame(width:840).fixedSize(horizontal:false,vertical:true)
         .environment(\.locale,Locale(identifier:"zh_CN")).preferredColorScheme(light ? .light : .dark)
    }
}
struct MenuHero: View {
    var light = false
    var ink: Color { light ? .black : .white }
    var body: some View {
        VStack(spacing:20) {
            HStack { Text("常驻菜单栏，保持轻巧。").font(.system(size:23,weight:.semibold)); Spacer(); Text("示例数据").font(.system(size:11)).foregroundStyle(.secondary) }
            PreviewMenu(light:light).scaleEffect(1.45).frame(height:64)
            Text("Cursor 内 / 外模型剩余百分比   ·   金额自动缩略   ·   点开查看完整明细")
                .font(.system(size:12)).foregroundStyle(ink.opacity(0.55))
        }.padding(36).frame(width:840).background(light ? Color(red:0.965,green:0.98,blue:0.99) : Color(red:0.035,green:0.055,blue:0.085)).preferredColorScheme(light ? .light : .dark)
    }
}
func exportPreview<V:View>(_ view:V, to path:URL) {
    let hosting = NSHostingView(rootView:view)
    hosting.appearance = NSAppearance(named:.darkAqua)
    let size = hosting.fittingSize
    hosting.frame = NSRect(origin:.zero,size:size)
    let window = NSWindow(contentRect:hosting.frame,styleMask:.borderless,backing:.buffered,defer:false)
    window.contentView = hosting;window.backgroundColor = NSColor.black
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until:Date().addingTimeInterval(0.25))
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds) else { fatalError("Bitmap creation failed") }
    hosting.cacheDisplay(in:hosting.bounds,to:bitmap)
    try! bitmap.representation(using:.png,properties:[:])!.write(to:path)
    print("Rendered \(path.lastPathComponent): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
}
let previewApp = NSApplication.shared
previewApp.setActivationPolicy(.prohibited)
let previewMeter = Meter()
let previewDate = ISO8601DateFormatter().date(from:"2030-01-15T02:24:00Z")!
previewMeter.limits = Limits(primary:nil,secondary:WindowQuota(usedPercent:5,windowDurationMins:10080,resetsAt:Date().addingTimeInterval(3*86400+8*3600+60).timeIntervalSince1970),planType:nil)
previewMeter.cursorQuota = CursorQuota(modelPools:[.init(name:"内部模型",usedPercent:0),.init(name:"外部模型",usedPercent:15)],pools:[.init(name:"套餐额度",used:3,limit:20,remaining:17)],reset:ISO8601DateFormatter().date(from:"2030-02-01T00:00:00Z"),message:"")
previewMeter.hasKey = true
previewMeter.balances = [Balance(currency:"CNY",total_balance:"128.50",granted_balance:"8.50",topped_up_balance:"120.00")]
previewMeter.codexDate = previewDate; previewMeter.cursorDate = previewDate; previewMeter.deepDate = previewDate
let outputDirectory = URL(fileURLWithPath:CommandLine.arguments[1])
exportPreview(PreviewHero(meter:previewMeter),to:outputDirectory.appendingPathComponent("overview.png"))
exportPreview(MenuHero(),to:outputDirectory.appendingPathComponent("menubar.png"))

exportPreview(PreviewHero(meter:previewMeter,light:true),to:outputDirectory.appendingPathComponent("overview-light.png"))
exportPreview(MenuHero(light:true),to:outputDirectory.appendingPathComponent("menubar-light.png"))
