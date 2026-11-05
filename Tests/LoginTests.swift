import Foundation

private final class LoginMockProtocol: URLProtocol {
    static var status = 404
    static var stall = false
    static var delay: TimeInterval = 0
    private var delivery: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api2.cursor.sh" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard !Self.stall else { return }
        let status = Self.status
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let response = HTTPURLResponse(url:self.request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!
            self.client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            let data = status == 200 ? Data(#"{"accessToken":"test-only-access","refreshToken":"test-only-refresh","selectedTeamId":1}"#.utf8) : Data("{}".utf8)
            self.client?.urlProtocol(self,didLoad:data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        delivery = work
        DispatchQueue.global().asyncAfter(deadline:.now()+Self.delay,execute:work)
    }
    override func stopLoading() { delivery?.cancel() }
}

func runLoginLifecycleTests() {
    func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until:Date().addingTimeInterval(0.005)) }
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [LoginMockProtocol.self]
    let session = URLSession(configuration:config)
    var saves = 0; var opened: [URL] = []
    let client = CursorClient(loginSession:session,openLoginURL:{ opened.append($0); return true },saveLoginSession:{ _ in saves += 1 },loginTimeout:0.10,pollInterval:0.01)
    var results: [Result<Void,Error>] = []

    // Closing a browser tab sends no callback. A completely stalled request must still time out.
    LoginMockProtocol.stall = true
    client.login { results.append($0) }
    pump(0.25)
    precondition(results.count == 1 && saves == 0)
    if case .success = results[0] { preconditionFailure("Stalled login succeeded") }

    // Reopen the same attempt, then cancel immediately; no stale success may save credentials.
    results = []; opened = []; LoginMockProtocol.stall = false; LoginMockProtocol.status = 200; LoginMockProtocol.delay = 0.05
    client.login { results.append($0) }; client.reopenLogin()
    precondition(opened.count == 2 && opened[0] == opened[1])
    client.cancelLogin(); pump(0.20)
    precondition(results.count == 1 && saves == 0)
    if case .failure(let error) = results[0] { precondition((error as NSError).code == NSUserCancelledError) }
    else { preconditionFailure("Cancellation succeeded") }

    // Retry works after cancellation. Success completes once; its timeout cannot fire later.
    results = []; LoginMockProtocol.delay = 0
    client.login { results.append($0) }; pump(0.20)
    precondition(results.count == 1 && saves == 1)
    if case .failure = results[0] { preconditionFailure("Retry failed") }
    client.cancelLogin(); pump(0.03); precondition(results.count == 1)

    // Permanent rejection and browser launch failure must promptly return to an idle state.
    results = []; LoginMockProtocol.status = 403
    client.login { results.append($0) }; pump(0.08)
    precondition(results.count == 1 && saves == 1)
    let unavailable = CursorClient(loginSession:session,openLoginURL:{ _ in false },saveLoginSession:{ _ in preconditionFailure("Unexpected save") })
    var failedOpen = false
    unavailable.login { if case .failure = $0 { failedOpen = true } }
    precondition(failedOpen)
    session.invalidateAndCancel()
    print("PASS: independent timeout, reopen same attempt, cancel ignores late success, retry, completion once, rejection, browser launch failure")
}
