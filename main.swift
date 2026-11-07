// Menu bar app that listens on the network and shows POSTed messages as notifications.
import AppKit
import Network
import ServiceManagement
import UserNotifications

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

func loadToken() -> String {
    let key = "token"
    if let token = UserDefaults.standard.string(forKey: key) { return token }
    let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    UserDefaults.standard.set(token, forKey: key)
    return token
}

func isLoopback(_ endpoint: NWEndpoint) -> Bool {
    guard case .hostPort(let host, _) = endpoint else { return false }
    switch host {
    case .ipv4(let address): return address.isLoopback
    case .ipv6(let address): return address.isLoopback || address.asIPv4?.isLoopback == true
    default: return false
    }
}

func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let a = Array(a.utf8), b = Array(b.utf8)
    guard a.count == b.count else { return false }
    return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}

func parseRequest(_ buffer: Data, requiredToken: String?) -> Parsed {
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

    if let requiredToken, !constantTimeEqual(headers["authorization"] ?? "", "Bearer \(requiredToken)") {
        return .respond(401, ["error": "invalid token"])
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

    private let token: String
    private let onNotify: NotifyHandler
    private let onStatus: (String) -> Void
    private var listener: NWListener?

    init(token: String, onNotify: @escaping NotifyHandler, onStatus: @escaping (String) -> Void) {
        self.token = token
        self.onNotify = onNotify
        self.onStatus = onStatus
    }

    // All server callbacks run on the main queue.
    func start() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: parameters, on: listenPort)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.onStatus("Listening on port \(listenPort.rawValue)")
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
        onStatus("Can't listen on port \(listenPort.rawValue)")
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

            // Requests from this Mac don't need the token.
            let requiredToken = isLoopback(connection.endpoint) ? nil : self.token
            switch parseRequest(buffer, requiredToken: requiredToken) {
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
            200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
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

func renderMarkdown(_ markdown: String) -> NSAttributedString {
    let bodyFont = NSFont.systemFont(ofSize: 14)
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
    guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
        return NSAttributedString(string: markdown, attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor])
    }

    let result = NSMutableAttributedString()
    var lastBlock: Int?
    var lastRoot: Int?
    var lastCell: Int?
    var lastListItem: Int?

    for run in parsed.runs {
        let components = run.presentationIntent?.components ?? []
        var isCell = false
        var cellID: Int?
        var blockID: Int?
        var listItem: (id: Int, ordinal: Int, index: Int)?

        for (index, component) in components.enumerated() {
            switch component.kind {
            case .tableCell:
                isCell = true
                cellID = component.identity
            case .listItem(let ordinal):
                if listItem == nil { listItem = (component.identity, ordinal, index) }
            default:
                break
            }
            if blockID == nil, !(isCell && cellID == component.identity) { blockID = component.identity }
        }

        var font = bodyFont
        var color = NSColor.labelColor
        var background: NSColor?
        var indent: CGFloat = 0
        var isCodeBlock = false

        for component in components {
            switch component.kind {
            case .header(let level):
                font = .boldSystemFont(ofSize: CGFloat(max(15, 26 - 2 * level)))
            case .codeBlock:
                font = .monospacedSystemFont(ofSize: 13, weight: .regular)
                background = .quaternaryLabelColor
                isCodeBlock = true
            case .blockQuote:
                color = .secondaryLabelColor
                indent += 20
            case .tableHeaderRow:
                font = .boldSystemFont(ofSize: 14)
            case .orderedList, .unorderedList:
                indent += 20
            default:
                break
            }
        }

        let inline = run.inlinePresentationIntent ?? []
        if inline.contains(.code) { font = .monospacedSystemFont(ofSize: 13, weight: .regular) }
        if inline.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }

        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        paragraph.lineSpacing = 2
        paragraph.defaultTabInterval = 140

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        if let background { attributes[.backgroundColor] = background }
        if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        // Messages come from other apps, so only web links are clickable.
        if let link = run.link, link.scheme == "http" || link.scheme == "https" { attributes[.link] = link }

        if blockID != lastBlock {
            // Items of one list or table sit on adjacent lines; separate blocks get a gap.
            let root = components.last?.identity
            if result.length > 0 {
                let separator = root == lastRoot ? "\n" : "\n\n"
                result.append(NSAttributedString(string: separator, attributes: [.font: bodyFont]))
            }
            lastBlock = blockID
            lastRoot = root
            lastCell = cellID
            if let listItem, listItem.id != lastListItem {
                lastListItem = listItem.id
                var isOrdered = false
                if listItem.index + 1 < components.count, case .orderedList = components[listItem.index + 1].kind {
                    isOrdered = true
                }
                let marker = isOrdered ? "\(listItem.ordinal). " : "• "
                result.append(NSAttributedString(string: marker, attributes: attributes))
            }
        } else if cellID != lastCell {
            result.append(NSAttributedString(string: "\t", attributes: attributes))
            lastCell = cellID
        }

        var text = String(parsed[run.range].characters)
        if isCodeBlock, text.hasSuffix("\n") { text.removeLast() }
        result.append(NSAttributedString(string: text, attributes: attributes))
    }

    return result
}

@MainActor
final class MessageWindow {
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    private let textView: NSTextView

    init() {
        let scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        window.contentView = scrollView
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show(title: String, message: String) {
        window.title = title
        textView.textStorage?.setAttributedString(renderMarkdown(message))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private struct Received {
        let title: String
        let message: String
        let date: Date
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let timeFormatter = DateFormatter()
    private let token = loadToken()
    private let messageWindow = MessageWindow()
    private let doorbellSound = Bundle.main.url(forResource: "doorbell", withExtension: "wav")
        .flatMap { NSSound(contentsOf: $0, byReference: true) }
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
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("notification authorization failed: %@", error.localizedDescription) }
        }

        let server = HTTPServer(
            token: token,
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
        let copyToken = NSMenuItem(title: "Copy Token", action: #selector(copyToken), keyEquivalent: "")
        copyToken.target = self
        menu.addItem(copyToken)
        menu.addItem(.separator())

        addLabel("Recent", to: menu)
        if recent.isEmpty {
            addLabel("No notifications yet", to: menu)
        }
        for item in recent {
            let plain = renderMarkdown(item.message).string
            let text = "\(item.title): \(plain)".replacingOccurrences(of: "\n", with: " ")
            let entry = NSMenuItem(
                title: "\(timeFormatter.string(from: item.date))  \(text.prefix(70))",
                action: #selector(showRecent(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = item
            menu.addItem(entry)
        }
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // Banners are hidden for the frontmost app unless the delegate asks for them.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let title = info["title"] as? String, let message = info["message"] as? String {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.messageWindow.show(title: title, message: message) }
            }
        }
        completionHandler()
    }

    private func addLabel(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func sendTest() {
        let message = """
        # Doorbell

        **Markdown** works, with `inline code` and [links](https://github.com/thamcheongkit/doorbell).

        - First item
        - Second item
        """
        deliver(title: "Doorbell", message: message) { error in
            if let error { NSLog("test notification failed: %@", error) }
        }
    }

    @objc private func showRecent(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? Received else { return }
        messageWindow.show(title: item.title, message: item.message)
    }

    @objc private func copyToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
    }

    private func deliver(title: String, message: String, done: @escaping (String?) -> Void) {
        recent.insert(Received(title: title, message: message, date: Date()), at: 0)
        recent = Array(recent.prefix(maxRecent))

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = renderMarkdown(message).string
        content.userInfo = ["title": title, "message": message]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            let description = error?.localizedDescription
            DispatchQueue.main.async {
                if description == nil { MainActor.assumeIsolated { self?.playSound() } }
                done(description)
            }
        }
    }

    // The app plays the sound itself because macOS can fall back to its default
    // sound for a bundled file. It still follows the app's sound setting.
    private func playSound() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let isEnabled = settings.soundSetting == .enabled
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard isEnabled else { return }
                    self?.doorbellSound?.stop()
                    self?.doorbellSound?.play()
                }
            }
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
