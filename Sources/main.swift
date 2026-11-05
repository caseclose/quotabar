import Cocoa
import SwiftUI
import Security
import ServiceManagement
import CryptoKit

struct WindowQuota: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
    var remaining: Int { Int(max(0, min(100, 100-usedPercent)).rounded(.down)) }
    var label: String {
        guard let m = windowDurationMins else { return "额度窗口" }
        if m % 1440 == 0 { return "\(m/1440) 天额度" }
        if m % 60 == 0 { return "\(m/60) 小时额度" }
        return "\(m) 分钟额度"
    }
    var resetText: String {
        guard let t = resetsAt else { return "重置时间未知" }
        let s = Int(t-Date().timeIntervalSince1970)
        if s <= 0 { return "等待刷新重置状态" }
        return s >= 86400 ? "\(s/86400)天 \(s%86400/3600)小时后重置" : "\(s/3600)小时 \(s%3600/60)分后重置"
    }
}
struct Limits: Decodable { let primary: WindowQuota?; let secondary: WindowQuota?; let planType: String? }
struct Balance: Decodable, Identifiable {
    let currency: String; let total_balance: String; let granted_balance: String; let topped_up_balance: String
    var id: String { currency }
    var display: String { (currency == "CNY" ? "¥" : currency == "USD" ? "$" : currency+" ")+total_balance }
}
struct BalanceReply: Decodable { let is_available: Bool; let balance_infos: [Balance] }
struct MeterError: LocalizedError { let message: String; var errorDescription: String? { message } }

enum KeyStore {
    static let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.QuotaBar.DeepSeek",kSecAttrAccount as String:"api-key"]
    static func read() -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data:data,encoding:.utf8)
    }
    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary,nil) == errSecSuccess else { throw MeterError(message:"无法写入钥匙串") }; return
        }
        guard status == errSecSuccess else { throw MeterError(message:"无法更新钥匙串") }
    }
    static func remove() { SecItemDelete(query as CFDictionary) }
}

func fetchCodex() throws -> Limits {
    let paths = [UserDefaults.standard.string(forKey:"codexPath") ?? "", "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
    guard let path = paths.first(where:{ FileManager.default.isExecutableFile(atPath:$0) }) else { throw MeterError(message:"未找到 Codex CLI，请在设置中选择") }
    let p = Process(); let input = Pipe(); let output = Pipe()
    p.executableURL = URL(fileURLWithPath:path); p.arguments = ["app-server","--listen","stdio://"]
    p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
    try p.run()
    let timeout = DispatchWorkItem { if p.isRunning { p.terminate(); DispatchQueue.global().asyncAfter(deadline:.now()+2) { if p.isRunning { kill(p.processIdentifier,SIGKILL) } } } }
    DispatchQueue.global().asyncAfter(deadline:.now()+25,execute:timeout)
    defer { timeout.cancel(); try? input.fileHandleForWriting.close(); if p.isRunning { p.terminate(); DispatchQueue.global().asyncAfter(deadline:.now()+2) { if p.isRunning { kill(p.processIdentifier,SIGKILL) } } }; try? output.fileHandleForReading.close() }
    func send(_ obj:[String:Any]) throws { var d = try JSONSerialization.data(withJSONObject:obj); d.append(10); try input.fileHandleForWriting.write(contentsOf:d) }
    try send(["id":1,"method":"initialize","params":["clientInfo":["name":"quota_bar","title":"QuotaBar","version":"1.0.0"]]])
    var buffer = Data()
    while true {
        let chunk = output.fileHandleForReading.availableData
        if chunk.isEmpty { throw MeterError(message:"Codex 连接超时或已关闭") }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of:10) {
            let line = buffer[..<newline]; buffer.removeSubrange(...newline)
            guard let obj = try? JSONSerialization.jsonObject(with:line) as? [String:Any], let id = obj["id"] as? Int else { continue }
            if obj["error"] != nil { throw MeterError(message:"Codex 读取失败，请检查登录状态") }
            if id == 1 { try send(["method":"initialized"]); try send(["id":2,"method":"account/rateLimits/read"]) }
            if id == 2 {
                guard let result = obj["result"] as? [String:Any] else { throw MeterError(message:"额度响应为空") }
                let buckets = result["rateLimitsByLimitId"] as? [String:Any]
                guard let limits = (buckets?["codex"] ?? result["rateLimits"]) as? [String:Any] else { throw MeterError(message:"账号未提供 Codex 额度") }
                return try JSONDecoder().decode(Limits.self,from:JSONSerialization.data(withJSONObject:limits))
            }
        }
    }
}

func compactAmount(_ value: Double, symbol: String) -> String {
    guard value.isFinite else { return "—" }
    let amount = max(0,value)
    if amount >= 1_000_000 { return symbol + String(format:"%.1fm",floor(amount / 100_000) / 10) }
    if amount >= 1_000 { return symbol + String(format:"%.1fk",floor(amount / 100) / 10) }
    if amount > 0 && amount < 1 { return symbol + String(format:"%.2f",amount) }
    return symbol + String(Int(amount))
}

struct CursorSession: Codable { let accessToken: String; let refreshToken: String; let selectedTeamId: Int? }
enum CursorStore {
    static let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.QuotaBar.Cursor",kSecAttrAccount as String:"session"]
    static func read() -> CursorSession? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary,&item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(CursorSession.self,from:data)
    }
    static func save(_ session: CursorSession) throws {
        let data = try JSONEncoder().encode(session)
        let status = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary,nil) == errSecSuccess else { throw MeterError(message:"无法保存 Cursor 登录") }; return
        }
        guard status == errSecSuccess else { throw MeterError(message:"无法更新 Cursor 登录") }
    }
}
struct CursorQuota {
    struct Pool: Identifiable { let name: String; let used: Double; let limit: Double; let remaining: Double; var id: String { name } }
    struct ModelPool: Identifiable {
        let name: String
        let usedPercent: Double?
        var id: String { name }
        var remaining: Double? { usedPercent.map { (max(0,min(100,100-$0)) * 10).rounded() / 10 } }
        var text: String { remaining.map { String(format:"%.1f%%",$0) } ?? "—" }
    }
    let modelPools: [ModelPool]
    let pools: [Pool]
    let reset: Date?
    let message: String
    var menuText: String {
        guard modelPools.contains(where:{$0.remaining != nil}) else { return "—" }
        return modelPools.map { $0.remaining.map { String(Int(floor($0))) } ?? "—" }.joined(separator:"/") + "%"
    }
    static func parse(_ data: Data) throws -> CursorQuota {
        guard let obj = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw MeterError(message:"Cursor 额度格式异常") }
        func number(_ value: Any?) -> Double? { if let n = value as? NSNumber { return n.doubleValue }; if let s = value as? String { return Double(s) }; return nil }
        var pools: [Pool] = []
        let planFields = obj["planUsage"] as? [String:Any] ?? [:]
        let modelPools = [("auto","内部模型"),("api","外部模型")].map { prefix,label -> ModelPool in
            let direct = number(planFields[prefix+"PercentUsed"])
            let derived: Double? = {
                guard let spent = number(planFields[prefix+"Spend"]), let limit = number(planFields[prefix+"Limit"]), limit > 0 else { return nil }
                return 100 * spent / limit
            }()
            return ModelPool(name:label,usedPercent:direct ?? derived)
        }
        if let plan = obj["planUsage"] as? [String:Any], let limit = number(plan["limit"]), limit > 0 {
            let used = number(plan["includedSpend"]) ?? 0
            pools.append(Pool(name:"套餐额度",used:used/100,limit:limit/100,remaining:(number(plan["remaining"]) ?? max(0,limit-used))/100))
        }
        if let spend = obj["spendLimitUsage"] as? [String:Any] {
            for (prefix,label) in [("individual","个人消费限额"),("pooled","团队共享额度"),("overall","总消费限额")] {
                if let limit = number(spend[prefix+"Limit"]), limit > 0 {
                    let used = number(spend[prefix+"Used"]) ?? 0
                    pools.append(Pool(name:label,used:used/100,limit:limit/100,remaining:(number(spend[prefix+"Remaining"]) ?? max(0,limit-used))/100))
                }
            }
        }
        let end = number(obj["billingCycleEnd"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970:$0 > 1e12 ? $0/1000 : $0) : nil }
        return CursorQuota(modelPools:modelPools,pools:pools,reset:end,message:obj["displayMessage"] as? String ?? "账号未提供固定额度上限")
    }
}
final class CursorClient {
    private var loginGeneration = 0
    private var loginCompletion: ((Result<Void,Error>) -> Void)?
    private var loginTask: URLSessionDataTask?
    private var loginWatchdog: DispatchWorkItem?
    private var loginURL: URL?
    private let loginSession: URLSession
    private let openLoginURL: (URL) -> Bool
    private let saveLoginSession: (CursorSession) throws -> Void
    private let loginTimeout: TimeInterval
    private let pollInterval: TimeInterval
    init(loginSession: URLSession = .shared,
         openLoginURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         saveLoginSession: @escaping (CursorSession) throws -> Void = { try CursorStore.save($0) },
         loginTimeout: TimeInterval = 90, pollInterval: TimeInterval = 2) {
        self.loginSession = loginSession; self.openLoginURL = openLoginURL
        self.saveLoginSession = saveLoginSession; self.loginTimeout = loginTimeout; self.pollInterval = pollInterval
    }
    func cancelLogin() {
        finishLogin(generation:loginGeneration,result:.failure(NSError(domain:NSCocoaErrorDomain,code:NSUserCancelledError)))
    }
    func reopenLogin() {
        guard let url = loginURL, loginCompletion != nil else { return }
        if !openLoginURL(url) { finishLogin(generation:loginGeneration,result:.failure(MeterError(message:"无法打开默认浏览器，请重试"))) }
    }
    private func finishLogin(generation: Int, result: Result<Void,Error>) {
        guard generation == loginGeneration, let callback = loginCompletion else { return }
        loginCompletion = nil; loginGeneration += 1
        loginTask?.cancel(); loginTask = nil
        loginWatchdog?.cancel(); loginWatchdog = nil; loginURL = nil
        callback(result)
    }
    func login(_ completion: @escaping (Result<Void,Error>) -> Void) {
        cancelLogin()
        loginGeneration += 1; let generation = loginGeneration
        loginCompletion = completion
        var bytes = [UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else {
            finishLogin(generation:generation,result:.failure(MeterError(message:"无法创建登录会话"))); return
        }
        func base64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") }
        let verifier = base64(Data(bytes)); let challenge = base64(Data(SHA256.hash(data:Data(verifier.utf8)))); let uuid = UUID().uuidString
        var parts = URLComponents(string:"https://cursor.com/loginDeepControl")!
        parts.queryItems = [URLQueryItem(name:"challenge",value:challenge),URLQueryItem(name:"uuid",value:uuid),URLQueryItem(name:"mode",value:"login"),URLQueryItem(name:"supportsSelectedTeamLogin",value:"true")]
        loginURL = parts.url!
        guard openLoginURL(parts.url!) else { finishLogin(generation:generation,result:.failure(MeterError(message:"无法打开默认浏览器，请重试"))); return }
        let deadline = Date().addingTimeInterval(loginTimeout)
        let watchdog = DispatchWorkItem { [weak self] in
            self?.finishLogin(generation:generation,result:.failure(MeterError(message:"登录等待已结束，可重新登录")))
        }
        loginWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline:.now()+loginTimeout,execute:watchdog)
        func poll() {
            guard generation == self.loginGeneration, self.loginCompletion != nil else { return }
            if Date() >= deadline { self.finishLogin(generation:generation,result:.failure(MeterError(message:"登录等待已结束，可重新登录"))); return }
            var url = URLComponents(string:"https://api2.cursor.sh/auth/poll")!
            url.queryItems = [URLQueryItem(name:"uuid",value:uuid),URLQueryItem(name:"verifier",value:verifier)]
            var request = URLRequest(url:url.url!); request.timeoutInterval = 15
            self.loginTask = self.loginSession.dataTask(with:request) { data,response,error in
                DispatchQueue.main.async {
                    guard generation == self.loginGeneration, self.loginCompletion != nil else { return }
                    guard Date() < deadline else { self.finishLogin(generation:generation,result:.failure(MeterError(message:"登录等待已结束，可重新登录"))); return }
                    let status = (response as? HTTPURLResponse)?.statusCode
                    if let data = data, status == 200, let session = try? JSONDecoder().decode(CursorSession.self,from:data) {
                        do { try self.saveLoginSession(session); self.finishLogin(generation:generation,result:.success(())) }
                        catch { self.finishLogin(generation:generation,result:.failure(error)) }
                    } else if status == 400 || status == 401 || status == 403 || status == 410 {
                        self.finishLogin(generation:generation,result:.failure(MeterError(message:"登录已拒绝或失效，请重试")))
                    } else { DispatchQueue.main.asyncAfter(deadline:.now()+self.pollInterval,execute:poll) }
                }
            }
            self.loginTask?.resume()
        }
        poll()
    }
    func refresh(allowRenew: Bool = true, _ completion: @escaping (Result<CursorQuota,Error>) -> Void) {
        guard let session = CursorStore.read() else { completion(.failure(MeterError(message:"请使用默认浏览器登录 Cursor"))); return }
        var request = URLRequest(url:URL(string:"https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("Bearer \(session.accessToken)",forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("1",forHTTPHeaderField:"Connect-Protocol-Version")
        var body: [String:Any] = ["includePooledUsage":true]
        if let team = session.selectedTeamId { body["teamId"] = team }
        request.httpBody = try? JSONSerialization.data(withJSONObject:body)
        URLSession.shared.dataTask(with:request) { data,response,error in
            if (response as? HTTPURLResponse)?.statusCode == 401 && allowRenew {
                self.renew(session) { result in
                    switch result { case .success: self.refresh(allowRenew:false,completion)
                    case .failure(let error): completion(.failure(error)) }
                }
                return
            }
            let result = Result<CursorQuota,Error> {
                if error != nil { throw MeterError(message:"Cursor 网络连接失败") }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data = data else { throw MeterError(message:status == 401 ? "Cursor 登录已过期，请重新登录" : "Cursor 读取失败（\(status)）") }
                return try CursorQuota.parse(data)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
    private func renew(_ session: CursorSession, completion: @escaping (Result<Void,Error>) -> Void) {
        var request = URLRequest(url:URL(string:"https://api2.cursor.sh/oauth/token")!)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject:["grant_type":"refresh_token","client_id":"KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB","refresh_token":session.refreshToken])
        URLSession.shared.dataTask(with:request) { data,response,error in
            let result = Result<Void,Error> {
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data = data,
                      let obj = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                      obj["shouldLogout"] as? Bool != true, let token = obj["access_token"] as? String, !token.isEmpty else {
                    throw MeterError(message:"Cursor 登录已过期，请在默认浏览器重新登录")
                }
                try CursorStore.save(CursorSession(accessToken:token,refreshToken:token,selectedTeamId:session.selectedTeamId))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

}

final class Meter: ObservableObject {
    let cursorClient = CursorClient()
    @Published var cursorQuota: CursorQuota?
    @Published var cursorError: String?
    @Published var cursorDate: Date?
    @Published var cursorBusy = false
    @Published var cursorLoginBusy = false
    @Published var cursorLoginMessage: String?
    @Published var limits: Limits?
    @Published var balances: [Balance] = []
    @Published var codexError: String?
    @Published var deepError: String?
    @Published var codexDate: Date?
    @Published var deepDate: Date?
    @Published var codexBusy = false
    @Published var deepBusy = false
    @Published var hasKey = false
    @Published var available = true
    var changed: (() -> Void)?
    var windows: [WindowQuota] { [limits?.primary,limits?.secondary].compactMap{$0} }
    func refresh() {
        if !codexBusy {
            codexBusy = true
            DispatchQueue.global(qos:.utility).async {
                let result = Result { try fetchCodex() }
                DispatchQueue.main.async {
                    self.codexBusy = false
                    switch result {
                    case .success(let value): self.limits = value; self.codexDate = Date(); self.codexError = nil
                    case .failure(let e): self.codexError = e.localizedDescription
                    }
                    self.changed?()
                }
            }
        }
        refreshDeep()
        refreshCursor()
    }
    func refreshCursor() {
        guard !cursorBusy else { return }
        cursorBusy = true
        cursorClient.refresh { result in
            self.cursorBusy = false
            switch result {
            case .success(let value): self.cursorQuota = value; self.cursorError = nil; self.cursorDate = Date()
            case .failure(let error): self.cursorError = error.localizedDescription
            }
            self.changed?()
        }
    }
    func loginCursor() {
        guard !cursorLoginBusy else { return }; cursorLoginMessage = nil; cursorLoginBusy = true
        cursorClient.login { result in
            self.cursorLoginBusy = false
            switch result {
            case .success: self.cursorQuota = nil; self.refreshCursor()
            case .failure(let error):
                self.cursorLoginMessage = (error as NSError).code == NSUserCancelledError ? nil : error.localizedDescription
                self.changed?()
            }
        }
    }
    func refreshDeep() {
        guard !deepBusy else { return }
        guard let key = KeyStore.read(), !key.isEmpty else { hasKey = false; balances = []; deepDate = nil; changed?(); return }
        hasKey = true; deepBusy = true
        var request = URLRequest(url:URL(string:"https://api.deepseek.com/user/balance")!); request.timeoutInterval = 20
        request.setValue("Bearer \(key)",forHTTPHeaderField:"Authorization")
        URLSession.shared.dataTask(with:request) { data,response,error in
            let result: Result<BalanceReply,Error> = Result {
                if error != nil { throw MeterError(message:"DeepSeek 网络连接失败") }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else { throw MeterError(message:code == 401 ? "API Key 无效，请重新设置" : "DeepSeek 请求失败（\(code)）") }
                return try JSONDecoder().decode(BalanceReply.self,from:data ?? Data())
            }
            DispatchQueue.main.async {
                self.deepBusy = false
                switch result {
                case .success(let value): self.balances = value.balance_infos; self.available = value.is_available; self.deepDate = Date(); self.deepError = nil
                case .failure(let e): self.deepError = e.localizedDescription
                }
                self.changed?()
            }
        }.resume()
    }
}

struct QuotaRing: View {
    let quota: WindowQuota
    var body: some View {
        VStack(spacing:12) {
            ZStack {
                Circle().stroke(.white.opacity(0.09),lineWidth:9)
                Circle().trim(from:0,to:CGFloat(quota.remaining)/100).stroke(quota.remaining < 15 ? Color.orange : Color.white,style:StrokeStyle(lineWidth:9,lineCap:.round)).rotationEffect(.degrees(-90))
                VStack(spacing:2) { Text("\(quota.remaining)%").font(.system(size:32,weight:.semibold,design:.rounded)); Text("剩余").font(.caption).foregroundStyle(.secondary) }
            }.frame(width:115,height:115)
            Text(quota.label).font(.system(size:13,weight:.medium))
            Text(quota.resetText).font(.system(size:11)).foregroundStyle(.secondary)
        }
    }
}
struct FrostedBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct BrandLabel: View {
    let title: String
    let asset: String
    var body: some View {
        HStack(spacing:8) {
            if let url = Bundle.main.url(forResource:asset,withExtension:"png"), let image = NSImage(contentsOf:url) {
                Image(nsImage:image).renderingMode(.template).resizable().scaledToFit().frame(width:24,height:24)
            }
            Text(title).font(.system(size:16,weight:.semibold))
        }
    }
}

struct Panel: View {
    @ObservedObject var meter: Meter
    var settings: () -> Void
    var columnWidth: CGFloat { meter.windows.count > 1 ? 250 : 180 }
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            HStack { Image(systemName:"chart.donut").foregroundStyle(.mint); Text("QuotaBar").font(.system(size:19,weight:.semibold)); Spacer(); Text("用量一览").font(.caption).foregroundStyle(.secondary) }
            HStack(alignment:.top,spacing:24) {
                VStack(alignment:.leading,spacing:18) {
                    BrandLabel(title:"Codex",asset:"codex")
                    if meter.windows.isEmpty { Text(meter.codexBusy ? "读取额度中…" : "暂无额度").foregroundStyle(.secondary).frame(width:140,height:130) }
                    HStack(spacing:20) { ForEach(Array(meter.windows.enumerated()),id:\.offset) { _, q in QuotaRing(quota:q) } }
                    if let error = meter.codexError { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true) }
                    stamp(meter.codexDate)
                }.frame(width:columnWidth,alignment:.leading)
                Rectangle().fill(.white.opacity(0.10)).frame(width:1)
                VStack(alignment:.leading,spacing:18) {
                    BrandLabel(title:"Cursor",asset:"cursor")
                    if let value = meter.cursorQuota {
                        ForEach(value.modelPools) { pool in
                            VStack(alignment:.leading,spacing:8) {
                                HStack(alignment:.firstTextBaseline) {
                                    Text(pool.text).font(.system(size:32,weight:.semibold,design:.rounded))
                                    Text("剩余").font(.caption).foregroundStyle(.secondary)
                                }
                                Text(pool.name + (pool.name == "内部模型" ? " · Cursor Models" : " · Other Models")).font(.system(size:11)).foregroundStyle(.secondary)
                                if let remaining = pool.remaining { ProgressView(value:Double(remaining),total:100).tint(.white) }
                                else { Text("接口暂未提供该额度池").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        if !value.pools.isEmpty {
                            DisclosureGroup("金额与团队限额") {
                                VStack(alignment:.leading,spacing:10) {
                                    ForEach(value.pools) { pool in
                                        VStack(alignment:.leading,spacing:3) {
                                            Text(pool.name)
                                            Text(String(format:"剩余 $%.2f / $%.2f",max(0,pool.remaining),pool.limit)).lineLimit(2)
                                        }
                                    }
                                }.font(.system(size:10)).foregroundStyle(.secondary).padding(.top,8)
                            }.font(.caption)
                        }
                        if let reset = value.reset { Text("重置于 \(reset.formatted(date:.abbreviated,time:.shortened))").font(.system(size:11)).foregroundStyle(.secondary) }
                    } else { Text(meter.cursorBusy ? "读取额度中…" : "连接 Cursor 账号").font(.caption).foregroundStyle(.secondary) }
                    if let error = meter.cursorError { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true) }
                    if meter.cursorLoginBusy {
                        VStack(alignment:.leading,spacing:8) {
                            Text("等待浏览器登录 · 最长 90 秒").font(.system(size:10)).foregroundStyle(.secondary)
                            HStack {
                                Button("重新打开 ↗") { meter.cursorClient.reopenLogin() }
                                Spacer()
                                Button("取消登录") { meter.cursorClient.cancelLogin() }
                            }.buttonStyle(.plain).foregroundStyle(.cyan).font(.caption).focusable(false)
                        }
                    } else {
                        Button("浏览器登录 ↗") { meter.loginCursor() }.buttonStyle(.plain).foregroundStyle(.cyan).focusable(false)
                    }
                    if let message = meter.cursorLoginMessage { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
                    Button("网站明细 ↗") { NSWorkspace.shared.open(URL(string:"https://cursor.com/dashboard/usage")!) }.buttonStyle(.plain).foregroundStyle(.cyan).focusable(false)
                    stamp(meter.cursorDate)
                }.frame(width:columnWidth,alignment:.leading)
                Rectangle().fill(.white.opacity(0.10)).frame(width:1)
                VStack(alignment:.leading,spacing:18) {
                    BrandLabel(title:"DeepSeek",asset:"deepseek")
                    if !meter.hasKey {
                        VStack(spacing:14) { Image(systemName:"key.horizontal").font(.system(size:28)).foregroundStyle(.secondary); Text("连接 API 余额").font(.caption); Button("设置 API Key",action:settings).buttonStyle(.bordered) }.frame(width:150,height:130)
                    } else if meter.balances.isEmpty {
                        Text(meter.deepBusy ? "读取余额中…" : "暂无余额").frame(width:150,height:130)
                    } else {
                        ForEach(meter.balances) { b in
                            VStack(alignment:.leading,spacing:8) {
                                Text(b.display).font(.system(size:29,weight:.semibold,design:.rounded)).minimumScaleFactor(0.6).lineLimit(1)
                                Text("\(b.currency) 可用余额").foregroundStyle(.secondary).font(.caption)
                                Text("充值 \(b.topped_up_balance) · 赠金 \(b.granted_balance)").font(.system(size:10)).foregroundStyle(.secondary)
                            }.frame(width:170,alignment:.leading)
                        }
                        if !meter.available { Text("余额不足以调用 API").font(.caption).foregroundStyle(.orange) }
                    }
                    if let error = meter.deepError { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true) }
                    stamp(meter.deepDate)
                }.frame(width:columnWidth,alignment:.leading)
            }.fixedSize(horizontal:false,vertical:true)
            Divider()
            HStack {
                Button { meter.refresh() } label: { Label("刷新",systemImage:"arrow.clockwise") }.disabled(meter.codexBusy || meter.deepBusy).focusable(false)
                Text("每 60 秒更新").font(.system(size:11)).foregroundStyle(.secondary)
                Spacer()
                Button("设置",action:settings)
                Button { NSApp.terminate(nil) } label: { Image(systemName:"power") }.help("退出 QuotaBar")
            }.buttonStyle(.plain)
        }.padding(24).frame(width:columnWidth * 3 + 146).background { FrostedBackground().overlay(Color(red:0.075,green:0.09,blue:0.12).opacity(0.22)) }.preferredColorScheme(.dark)
    }
    @ViewBuilder func stamp(_ date: Date?) -> some View {
        if let date = date { Text("更新于 \(date.formatted(date:.omitted,time:.standard))").font(.system(size:10)).foregroundStyle(.secondary) }
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    lazy var meter = Meter(); var item: NSStatusItem!; let panel = NSPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false); var timer: Timer?; var outsideMonitor: Any?; var localMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        item.button?.image = nil
        item.button?.imagePosition = .imageLeading
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize:12,weight:.medium)
        item.button?.target = self; item.button?.action = #selector(toggle)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView:Panel(meter:meter,settings:{ [weak self] in self?.settings() }))
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 18
        panel.contentView?.layer?.masksToBounds = true
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { [weak self] _ in self?.panel.orderOut(nil) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.keyDown]) { [weak self] event in
            if (event.type == .keyDown && event.keyCode == 53) || (event.type != .keyDown && event.window != self?.panel && event.window != self?.item.button?.window) { self?.panel.orderOut(nil) }
            return event
        }
        meter.changed = { [weak self] in self?.updateTitle() }
        updateTitle(); meter.refresh()
        if !UserDefaults.standard.bool(forKey:"shownWelcomePanel") {
            UserDefaults.standard.set(true,forKey:"shownWelcomePanel")
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.toggle() }
        }
        timer = Timer.scheduledTimer(withTimeInterval:60,repeats:true) { [weak self] _ in self?.meter.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in self?.meter.refresh() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !panel.isVisible { toggle() }
        return true
    }
    func updateTitle() {
        let quota = meter.windows.map { "\($0.remaining)%" }.joined(separator:"/")
        let balance = meter.balances.map { b in
            guard let value = Double(b.total_balance) else { return "—" }
            return compactAmount(value,symbol:b.currency == "CNY" ? "¥" : b.currency == "USD" ? "$" : b.currency)
        }.joined(separator:"/")
        let cursor = meter.cursorQuota?.menuText ?? "—"
        let title = NSMutableAttributedString()
        func add(_ text: String) { title.append(NSAttributedString(string:text,attributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:11,weight:.medium),.foregroundColor:NSColor.labelColor])) }
        func icon(_ name: String) {
            if let url = Bundle.main.url(forResource:name,withExtension:"png"), let image = NSImage(contentsOf:url) {
                let original = image
                let image = NSImage(size:NSSize(width:15,height:15),flipped:false) { rect in
                    original.draw(in:rect)
                    NSColor.white.setFill(); rect.fill(using:.sourceAtop)
                    return true
                }
                image.isTemplate = true
                let attachment = NSTextAttachment(); attachment.image = image; attachment.bounds = NSRect(x:0,y:-3,width:15,height:15)
                title.append(NSAttributedString(attachment:attachment))
            }
        }
        icon("codex"); add("\(quota.isEmpty ? "—" : quota)\(meter.codexError != nil ? "!" : "") ")
        icon("cursor"); add("\(cursor)\(meter.cursorError != nil ? "!" : "") ")
        icon("deepseek"); add("\(balance.isEmpty ? "—" : balance)\(meter.deepError != nil ? "!" : "")")
        item.button?.attributedTitle = title
        if panel.isVisible { placePanel() }
        item.button?.toolTip = "Codex 剩余 \(quota) · Cursor 内/外剩余 \(meter.cursorQuota?.menuText ?? "—") · DeepSeek \(meter.balances.map(\.display).joined(separator:" / "))\n菜单栏金额为缩略值；点击查看精确额度。! 表示刷新失败。"
    }
    func placePanel() {
        guard let button = item.button, let window = button.window, let content = panel.contentView else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds,to:nil))
        let screen = window.screen ?? NSScreen.main!
        let available = screen.visibleFrame
        let size = content.fittingSize
        let width = min(size.width,available.width-16)
        let height = min(size.height,available.height-24)
        let x = max(available.minX+8,min(anchor.midX-width/2,available.maxX-width-8))
        let top = min(anchor.minY-8,available.maxY-8)
        panel.setFrame(NSRect(x:x,y:top-height,width:width,height:height),display:true)
    }
    @objc func toggle() {
        if panel.isVisible { panel.orderOut(nil) } else { placePanel(); panel.orderFrontRegardless() }
    }
    func settings() {
        panel.orderOut(nil); NSApp.activate(ignoringOtherApps:true)
        let alert = NSAlert(); alert.messageText = "QuotaBar 设置"; alert.informativeText = "DeepSeek API Key 仅保存到本机钥匙串。留空保留现有 Key。Codex 使用本机已登录的 CLI。"
        alert.addButton(withTitle:"保存"); alert.addButton(withTitle:"取消"); alert.addButton(withTitle:"删除 Key")
        let v = NSView(frame:NSRect(x:0,y:0,width:360,height:135))
        let key = NSSecureTextField(frame:NSRect(x:0,y:100,width:360,height:24)); key.placeholderString = "DeepSeek API Key（sk-…）"; v.addSubview(key)
        let path = NSTextField(frame:NSRect(x:0,y:57,width:360,height:24)); path.placeholderString = "Codex CLI 路径（可留空自动检测）"; path.stringValue = UserDefaults.standard.string(forKey:"codexPath") ?? ""; v.addSubview(path)
        let login = NSButton(checkboxWithTitle:"登录 Mac 时启动",target:nil,action:nil); login.frame = NSRect(x:0,y:10,width:300,height:24); login.state = SMAppService.mainApp.status == .enabled ? .on : .off; v.addSubview(login)
        alert.accessoryView = v
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            do {
                let value = key.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
                if !value.isEmpty { try KeyStore.save(value); meter.balances = []; meter.deepDate = nil }
                UserDefaults.standard.set(path.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),forKey:"codexPath")
                if login.state == .on && SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                if login.state == .off && SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                meter.deepError = nil; meter.refresh()
            } catch { let a = NSAlert(); a.messageText = "设置未完全保存"; a.informativeText = error.localizedDescription; a.runModal() }
        } else if response == .alertThirdButtonReturn { KeyStore.remove(); meter.deepError = nil; meter.refreshDeep() }
    }
}

if CommandLine.arguments.contains("--test-login") { runLoginLifecycleTests(); exit(0) }
if CommandLine.arguments.contains("--cursor-login") {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let client = CursorClient()
    client.login { result in
        switch result { case .success: print("Cursor login saved in Keychain"); exit(0)
        case .failure(let error): print(error.localizedDescription); exit(1) }
    }
    app.run()
}
if CommandLine.arguments.contains("--check-cursor") {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let client = CursorClient()
    client.refresh { result in
        switch result {
        case .success(let quota): print("Cursor model pools: " + quota.modelPools.map { "\($0.name)=\($0.text), used=\($0.usedPercent.map(String.init(describing:)) ?? "unknown")" }.joined(separator:"; ")); print("Cursor live check: " + quota.pools.map { "\($0.name): remaining=\($0.remaining), limit=\($0.limit)" }.joined(separator:"; ")); exit(0)
        case .failure(let error): print(error.localizedDescription); exit(1)
        }
    }
    app.run()
}
if CommandLine.arguments.contains("--set-deepseek-key") {
    do {
        guard let key = readLine(), !key.isEmpty else { throw MeterError(message:"Missing key on stdin") }
        try KeyStore.save(key)
        print("DeepSeek key saved in macOS Keychain")
        exit(0)
    } catch { print(error.localizedDescription); exit(1) }
}
if CommandLine.arguments.contains("--check-deepseek") {
    guard let key = KeyStore.read() else { print("No key in Keychain"); exit(1) }
    var r = URLRequest(url:URL(string:"https://api.deepseek.com/user/balance")!); r.timeoutInterval = 20
    r.setValue("Bearer \(key)",forHTTPHeaderField:"Authorization")
    let semaphore = DispatchSemaphore(value:0)
    var ok = false
    URLSession.shared.dataTask(with:r) { data,response,error in
        defer { semaphore.signal() }
        guard (response as? HTTPURLResponse)?.statusCode == 200, let data = data, let reply = try? JSONDecoder().decode(BalanceReply.self,from:data) else { print("DeepSeek check failed (no credentials logged)"); return }
        print("DeepSeek live check: " + reply.balance_infos.map(\.display).joined(separator:", "))
        ok = true
    }.resume()
    _ = semaphore.wait(timeout:.now()+25)
    exit(ok ? 0 : 1)
}
if CommandLine.arguments.contains("--self-test") {
    let q = WindowQuota(usedPercent:1,windowDurationMins:10080,resetsAt:nil)
    precondition(q.remaining == 99 && q.label == "7 天额度")
    precondition(WindowQuota(usedPercent:101,windowDurationMins:300,resetsAt:0).remaining == 0)
    precondition(WindowQuota(usedPercent:0.1,windowDurationMins:300,resetsAt:nil).remaining == 99)
    let data = Data(#"{"primary":{"usedPercent":1,"windowDurationMins":10080},"secondary":null,"planType":"prolite"}"#.utf8)
    let decoded = try! JSONDecoder().decode(Limits.self,from:data)
    precondition(decoded.secondary == nil && decoded.primary!.remaining == 99)
    let b = try! JSONDecoder().decode(BalanceReply.self,from:Data(#"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"0.00","granted_balance":"0","topped_up_balance":"0"},{"currency":"USD","total_balance":"2.50","granted_balance":"0.50","topped_up_balance":"2"}]}"#.utf8))
    precondition(!b.is_available && b.balance_infos.map(\.display) == ["¥0.00","$2.50"])
    let cursor = try! CursorQuota.parse(Data(#"{"planUsage":{"includedSpend":125,"remaining":875,"limit":1000},"spendLimitUsage":{"individualLimit":2500,"individualUsed":500,"individualRemaining":2000,"pooledLimit":"100000","pooledUsed":12345,"pooledRemaining":"87655"},"billingCycleEnd":"1893456000000"}"#.utf8))
    precondition(cursor.pools.count == 3 && cursor.pools[0].remaining == 8.75 && cursor.pools[1].limit == 25 && cursor.pools[2].remaining == 876.55)
    let unknown = try! CursorQuota.parse(Data(#"{"enabled":false}"#.utf8))
    precondition(unknown.pools.isEmpty && unknown.menuText == "—")
    let modelQuota = try! CursorQuota.parse(Data(#"{"planUsage":{"autoPercentUsed":12.25,"apiPercentUsed":0}}"#.utf8))
    precondition(modelQuota.menuText == "87/100%")
    let dashboardQuota = try! CursorQuota.parse(Data(#"{"planUsage":{"autoPercentUsed":0.02,"apiPercentUsed":0.2}}"#.utf8))
    precondition(dashboardQuota.menuText == "100/99%" && dashboardQuota.modelPools[0].text == "100.0%" && dashboardQuota.modelPools[1].text == "99.8%")
    let missingPool = try! CursorQuota.parse(Data(#"{"planUsage":{"autoPercentUsed":105}}"#.utf8))
    precondition(missingPool.menuText == "0/—%")
    precondition(compactAmount(4200.50,symbol:"¥") == "¥4.2k" && compactAmount(123.45,symbol:"¥") == "¥123")
    print("PASS: quota conversion, optional windows, multi-currency balances, Cursor cents and scoped limits, unknown limits")
    exit(0)
}
if CommandLine.arguments.contains("--check") {
    do { let limits = try fetchCodex(); print("Codex live check: " + [limits.primary,limits.secondary].compactMap{$0}.map { "\($0.label) remaining=\($0.remaining)%" }.joined(separator:", ")); exit(0) } catch { print(error.localizedDescription); exit(1) }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.run()
