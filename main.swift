// Menu bar app that listens on localhost and shows POSTed messages as notifications.
import AppKit
import Network
import ServiceManagement
import UserNotifications

let listenHost = "127.0.0.1"
let listenPort: NWEndpoint.Port = 8765
let maxHeaderBytes = 16 * 1024
let maxBodyBytes = 64 * 1024
let requestTimeout = 5.0
let maxRecent = 10

enum Parsed {
    case incomplete
    case respond(Int, [String: String])
    case notify(Data)
}

func parseRequest(_ buffer: Data) -> Parsed {
    guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
        return buffer.count > maxHeaderBytes ? .respond(400, ["error": "headers too large"]) : .incomplete
    }

    let lines = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        .components(separatedBy: "\r\n")
    let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
    guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
        return .respond(400, ["error": "malformed request"])
    }
    let method = requestLine[0]
    let path = requestLine[1]

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        headers[line[..<colon].lowercased()] = value
    }

    // Browsers send Origin on cross-site requests; this stops any web page
    // you visit from POSTing to localhost.
    if headers["origin"] != nil {
        return .respond(403, ["error": "browser requests are not allowed"])
    }

    if method == "GET" && path == "/health" { return .respond(200, ["status": "ok"]) }
    if path != "/notify" { return .respond(404, ["error": "not found"]) }
    if method != "POST" { return .respond(405, ["error": "use POST"]) }

    guard let length = headers["content-length"].flatMap({ Int($0) }), length >= 0 else {
        return .respond(411, ["error": "content-length required"])
    }
    if length > maxBodyBytes { return .respond(413, ["error": "body too large"]) }

    let body = buffer[headerEnd.upperBound...]
    return body.count < length ? .incomplete : .notify(Data(body.prefix(length)))
}

final class HTTPServer {
    typealias NotifyHandler = (_ title: String, _ message: String, _ done: @escaping (String?) -> Void) -> Void

    private let onNotify: NotifyHandler
    private let onStatus: (String) -> Void
    private var listener: NWListener?

    init(onNotify: @escaping NotifyHandler, onStatus: @escaping (String) -> Void) {
        self.onNotify = onNotify
        self.onStatus = onStatus
    }

    // All server callbacks run on the main queue.
    func start() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(listenHost), port: listenPort)

        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.onStatus("Listening on \(listenHost):\(listenPort.rawValue)")
                case .failed(let error):
                    self?.reportFailure(error.localizedDescription)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            reportFailure(error.localizedDescription)
        }
    }

    private func reportFailure(_ error: String) {
        NSLog("server failed: %@", error)
        onStatus("Can't listen on \(listenHost):\(listenPort.rawValue)")
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) { connection.cancel() }
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            switch parseRequest(buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    self.respond(connection, 400, ["error": "incomplete request"])
                } else {
                    self.read(connection, buffer: buffer)
                }
            case .respond(let status, let body):
                self.respond(connection, status, body)
            case .notify(let body):
                self.handleNotify(connection, body)
            }
        }
    }

    private func handleNotify(_ connection: NWConnection, _ body: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            respond(connection, 400, ["error": "body must be a JSON object"])
            return
        }
        guard let message = json["message"] as? String, !message.isEmpty else {
            respond(connection, 400, ["error": "message is required"])
            return
        }
        let suppliedTitle = json["title"] as? String ?? ""
        let title = suppliedTitle.isEmpty ? "Doorbell" : suppliedTitle

        onNotify(title, message) { [weak self] error in
            if let error {
                self?.respond(connection, 500, ["error": "notification failed: \(error)"])
            } else {
                self?.respond(connection, 200, ["status": "sent"])
            }
        }
    }

    private func respond(_ connection: NWConnection, _ status: Int, _ body: [String: String]) {
        let reasons = [
            200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
            405: "Method Not Allowed", 411: "Length Required",
            413: "Payload Too Large", 500: "Internal Server Error",
        ]
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(status) \(reasons[status] ?? "")\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(json.count)\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + json, completion: .contentProcessed { _ in connection.cancel() })
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private struct Received {
        let title: String
        let message: String
        let date: Date
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let timeFormatter = DateFormatter()
    private var recent: [Received] = []
    private var serverStatus = "Starting…"
    private var server: HTTPServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        timeFormatter.dateFormat = "HH:mm"
        statusItem.button?.image = NSImage(systemSymbolName: "bell", accessibilityDescription: "Doorbell")

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { _, error in
            if let error { NSLog("notification authorization failed: %@", error.localizedDescription) }
        }

        let server = HTTPServer(
            onNotify: { [weak self] title, message, done in
                MainActor.assumeIsolated { self?.deliver(title: title, message: message, done: done) }
            },
            onStatus: { [weak self] status in
                MainActor.assumeIsolated { self?.serverStatus = status }
            }
        )
        server.start()
        self.server = server

        // Skip this when running from the DMG, whose path disappears on eject.
        let path = Bundle.main.bundlePath
        if path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/") {
            do {
                try SMAppService.mainApp.register()
            } catch {
                NSLog("start at login failed: %@", error.localizedDescription)
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        addLabel(serverStatus, to: menu)
        menu.addItem(.separator())

        let test = NSMenuItem(title: "Send Test Notification", action: #selector(sendTest), keyEquivalent: "")
        test.target = self
        menu.addItem(test)
        menu.addItem(.separator())

        addLabel("Recent", to: menu)
        if recent.isEmpty {
            addLabel("No notifications yet", to: menu)
        }
        for item in recent {
            let text = "\(item.title): \(item.message)".replacingOccurrences(of: "\n", with: " ")
            addLabel("\(timeFormatter.string(from: item.date))  \(text.prefix(70))", to: menu)
        }
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // Banners are hidden for the frontmost app unless the delegate asks for them.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    private func addLabel(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func sendTest() {
        deliver(title: "Doorbell", message: "Test notification") { error in
            if let error { NSLog("test notification failed: %@", error) }
        }
    }

    private func deliver(title: String, message: String, done: @escaping (String?) -> Void) {
        recent.insert(Received(title: title, message: message, date: Date()), at: 0)
        recent = Array(recent.prefix(maxRecent))

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)

        UNUserNotificationCenter.current().add(request) { error in
            let description = error?.localizedDescription
            DispatchQueue.main.async { done(description) }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
