import UIKit
import Capacitor
import Network
import WebKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        TidalOriginProxy.shared.start()
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Called when the app was launched with a url. Feel free to add additional processing here,
        // but if you want the App API to support tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        // Called when the app was launched with a url. Feel free to add additional processing here,
        // but if you want the App API to support tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

}

class MainViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        if let script = TidalOriginProxy.shared.makeUserScript() {
            bridge?.webView?.configuration.userContentController.addUserScript(script)
        }
    }
}

final class TidalOriginProxy: NSObject {
    static let shared = TidalOriginProxy()

    private let spoofedOrigin = "https://listen.tidal.com"
    private var listener: NWListener?
    private let ready = DispatchSemaphore(value: 0)
    private(set) var port: UInt16 = 0

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            let listener = try NWListener(using: params, on: .any)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self, case .ready = state, let port = listener.port else { return }
                self.port = port.rawValue
                self.ready.signal()
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self = self else { return }
                Task { await self.handle(connection) }
            }
            listener.start(queue: DispatchQueue(label: "tf.monochrome.tidal-proxy"))
        } catch {
            NSLog("[TidalOriginProxy] failed to start: \(error)")
        }
    }
    func makeUserScript() -> WKUserScript? {
        if port == 0 {
            _ = ready.wait(timeout: .now() + 2)
        }
        guard port != 0 else { return nil }
        let source = TidalOriginProxy.injectedJS.replacingOccurrences(of: "__PORT__", with: String(port))
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    private func handle(_ connection: NWConnection) async {
        connection.start(queue: DispatchQueue(label: "tf.monochrome.tidal-proxy.conn"))
        defer { connection.cancel() }
        do {
            var buffer = Data()
            let separator = Data([13, 10, 13, 10])
            while buffer.range(of: separator) == nil {
                let chunk = try await receive(connection, max: 16384)
                if chunk.isEmpty { return }
                buffer.append(chunk)
                if buffer.count > 65536 { return }
            }
            guard let headerEnd = buffer.range(of: separator),
                  let headerText = String(data: buffer.subdata(in: 0..<headerEnd.lowerBound), encoding: .utf8) else { return }
            var rest = buffer.subdata(in: headerEnd.upperBound..<buffer.count)

            var lines = headerText.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst()
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else { return }
            let method = String(parts[0])
            var target = String(parts[1])
            if target.hasPrefix("/") { target.removeFirst() }

            guard let url = URL(string: target),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = url.host?.lowercased(), host == "tidal.com" || host.hasSuffix(".tidal.com") else {
                try await respond(connection, status: 403, body: Data("forbidden".utf8))
                return
            }

            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }

            var body: Data?
            if let lengthString = headers["content-length"], let length = Int(lengthString), length > 0 {
                while rest.count < length {
                    let chunk = try await receive(connection, max: min(length - rest.count, 1 << 20))
                    if chunk.isEmpty { break }
                    rest.append(chunk)
                }
                if rest.count >= length {
                    body = Data(rest.prefix(length))
                }
            }

            var currentURL = url
            var fetch: StreamingFetch?
            var httpResponse: HTTPURLResponse?
            var redirects = 0
            while redirects <= 5 {
                guard let currentHost = currentURL.host?.lowercased(),
                      currentHost == "tidal.com" || currentHost.hasSuffix(".tidal.com") else {
                    try await respond(connection, status: 403, body: Data("forbidden redirect".utf8))
                    return
                }
                let request = makeRequest(url: currentURL, method: method, headers: headers, body: body)
                let next = StreamingFetch()
                let response = try await next.response(for: request)
                if [301, 302, 303, 307, 308].contains(response.statusCode),
                   let location = response.value(forHTTPHeaderField: "Location"),
                   let redirectURL = URL(string: location, relativeTo: currentURL),
                   redirects < 5 {
                    next.cancel()
                    currentURL = redirectURL
                    redirects += 1
                    continue
                }
                fetch = next
                httpResponse = response
                break
            }
            guard let finalFetch = fetch, let finalResponse = httpResponse else {
                try await respond(connection, status: 502, body: Data("bad gateway".utf8))
                return
            }

            let hopByHop: Set<String> = ["connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade"]
            var head = "HTTP/1.1 \(finalResponse.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: finalResponse.statusCode))\r\n"
            for (key, value) in finalResponse.allHeaderFields {
                let name = String(describing: key)
                if hopByHop.contains(name.lowercased()) { continue }
                head += "\(name): \(value)\r\n"
            }
            head += "Access-Control-Allow-Origin: *\r\n"
            head += "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, PATCH, OPTIONS\r\n"
            head += "Access-Control-Allow-Headers: *\r\n"
            head += "Connection: close\r\n\r\n"
            try await send(connection, Data(head.utf8))

            for try await chunk in finalFetch.stream {
                try await send(connection, chunk)
            }
        } catch {
        }
    }

    private func makeRequest(url: URL, method: String, headers: [String: String], body: Data?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let skip: Set<String> = ["host", "connection", "keep-alive", "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade", "content-length", "origin", "referer", "accept-encoding"]
        for (key, value) in headers where !skip.contains(key) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(spoofedOrigin, forHTTPHeaderField: "Origin")
        request.setValue(spoofedOrigin + "/", forHTTPHeaderField: "Referer")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.httpBody = body
        return request
    }

    private func respond(_ connection: NWConnection, status: Int, body: Data) async throws {
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
        head += "Content-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        try await send(connection, Data(head.utf8) + body)
    }

    private func receive(_ connection: NWConnection, max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }


    private static let injectedJS = """
(function () {
    if (window.__tidalOriginPatched) return;
    window.__tidalOriginPatched = true;
    window.__tidalOriginExtension = true;

    var PROXY = 'http://127.0.0.1:__PORT__/';

    function rewrite(u) {
        if (typeof u !== 'string') return u;
        if (u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) return u;
        try {
            var abs = new URL(u, location.href);
            if (abs.protocol !== 'http:' && abs.protocol !== 'https:') return u;
            var h = abs.hostname.toLowerCase();
            if (h !== 'tidal.com' && !h.endsWith('.tidal.com')) return u;
            return PROXY + abs.href;
        } catch (e) {
            return u;
        }
    }

    if (window.fetch) {
        var ofetch = window.fetch;
        window.fetch = function (input, init) {
            try {
                if (typeof input === 'string') {
                    input = rewrite(input);
                } else if (input instanceof URL) {
                    input = rewrite(input.href);
                } else if (typeof Request !== 'undefined' && input instanceof Request) {
                    var r = rewrite(input.url);
                    if (r !== input.url) input = new Request(r, input);
                }
            } catch (e) {}
            return ofetch.call(this, input, init);
        };
    }

    var oopen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
        var args = Array.prototype.slice.call(arguments);
        try { args[1] = rewrite(String(url)); } catch (e) {}
        return oopen.apply(this, args);
    };

    function patchSrc(proto) {
        if (!proto) return;
        var d = Object.getOwnPropertyDescriptor(proto, 'src');
        if (!d || !d.set || !d.get) return;
        Object.defineProperty(proto, 'src', {
            configurable: true,
            enumerable: d.enumerable,
            get: function () { return d.get.call(this); },
            set: function (v) { d.set.call(this, rewrite(String(v))); }
        });
    }
    patchSrc(window.HTMLMediaElement && window.HTMLMediaElement.prototype);
    patchSrc(window.HTMLSourceElement && window.HTMLSourceElement.prototype);

    var oset = Element.prototype.setAttribute;
    Element.prototype.setAttribute = function (name, value) {
        try {
            if (String(name).toLowerCase() === 'src' && /^(AUDIO|VIDEO|SOURCE)$/.test(this.tagName || '')) {
                value = rewrite(String(value));
            }
        } catch (e) {}
        return oset.call(this, name, value);
    };
})();
"""
}

private final class StreamingFetch: NSObject, URLSessionDataDelegate {
    private(set) var stream: AsyncThrowingStream<Data, Error>!
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var session: URLSession?

    func response(for request: URLRequest) async throws -> HTTPURLResponse {
        stream = AsyncThrowingStream<Data, Error> { [weak self] continuation in
            self?.continuation = continuation
        }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        self.session = session
        return try await withCheckedThrowingContinuation { continuation in
            self.responseContinuation = continuation
            session.dataTask(with: request).resume()
        }
    }

    func cancel() {
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            responseContinuation?.resume(throwing: URLError(.badServerResponse))
            responseContinuation = nil
            completionHandler(.cancel)
            return
        }
        responseContinuation?.resume(returning: http)
        responseContinuation = nil
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let responseContinuation = responseContinuation {
            self.responseContinuation = nil
            responseContinuation.resume(throwing: error ?? URLError(.unknown))
        }
        if let error = error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
