// 「校园网 v6 免流」的 Mac 外壳：一个窗口（里面是本机面板 http://127.0.0.1:9090/ui）+ 菜单栏图标
// （运行状态、暂停 / 重新启用、今天的流量）。真正干活的是 sing-box 和本地助手（root 服务），
// 这个 App 只是界面：退出它不影响免流。
// 编译：cli.js --package 用 swiftc 编出 arm64 + x86_64 合成通用二进制（见 cli.js 的 macApp），最低 macOS 13。
import AppKit
import ServiceManagement
import WebKit

let PANEL = URL(string: "http://127.0.0.1:9090/ui/")!
let HELPER = URL(string: "http://127.0.0.1:9091/")!
let SHOW_NOTE = Notification.Name("io.github.concrise.neu-v6-free.show")

/// 本地助手写的面板密钥（root:admin 640，管理员账户能读）。读不到就让面板自己要密钥
func panelSecret() -> String? {
    var dirs = ["/usr/local/etc/neu-v6-free"]
    if let more = try? FileManager.default.contentsOfDirectory(atPath: "/usr/local/etc") {
        dirs += more.sorted().map { "/usr/local/etc/" + $0 }
    }
    for d in dirs {
        if let s = try? String(contentsOfFile: d + "/panel-secret", encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
    }
    return nil
}

/// 本机请求不走任何代理
let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.connectionProxyDictionary = [:]
    c.timeoutIntervalForRequest = 4
    return URLSession(configuration: c)
}()

func getJSON(_ path: String, _ done: @escaping ([String: Any]?) -> Void) {
    session.dataTask(with: URL(string: path, relativeTo: HELPER)!) { data, resp, _ in
        let ok = (resp as? HTTPURLResponse)?.statusCode == 200
        let obj = ok ? data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } : nil
        DispatchQueue.main.async { done(obj) }
    }.resume()
}

func bytes(_ n: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
}

/// 助手 /health 的结果
struct Status {
    var helper = false  // 助手有没有响应
    var singbox = false
    var safeReason: String?  // 不为空 = 已暂停（安全模式）
    var fallback: String?  // 连不上免流服务器时，原来选的入口
    var version = ""
    var latest: String?  // 有新版本时的版本号

    init() {}
    init(_ h: [String: Any]) {
        helper = true
        singbox = h["singbox"] as? Bool ?? false
        if let s = h["safe_mode"] as? [String: Any] { safeReason = s["reason"] as? String ?? "已暂停" }
        if let f = h["server_fallback"] as? [String: Any] { fallback = f["previous"] as? String ?? "" }
        version = h["version"] as? String ?? ""
        if let u = h["update"] as? [String: Any], u["available"] as? Bool == true { latest = u["latest"] as? String }
    }

    var running: Bool { helper && singbox && safeReason == nil }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate,
    WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate
{
    var item: NSStatusItem!
    var window: NSWindow?
    var web: WKWebView!
    var status = Status()
    var today: [String: Any]?
    var busy: String?  // 正在暂停 / 重新启用时显示在菜单第一行
    enum Page { case none, panel, status, error }
    var shown = Page.none  // 窗口里现在是什么
    var polled = false  // 第一次状态检查回来之前窗口先空着，免得闪一下出错页
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    // MARK: 启动

    func applicationDidFinishLaunching(_ n: Notification) {
        // 已经开着一个：让它把窗口拿出来，自己退出
        let me = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != me })
        {
            DistributedNotificationCenter.default().postNotificationName(SHOW_NOTE, object: nil, deliverImmediately: true)
            exit(0)
        }
        DistributedNotificationCenter.default().addObserver(
            forName: SHOW_NOTE, object: nil, queue: .main) { [weak self] _ in self?.showWindow() }

        NSApp.mainMenu = mainMenu()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = icon(.problem)
        item.button?.toolTip = "校园网 v6 免流"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        firstRunLoginItem()
        poll()
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.poll() }

        // 开机自动启动时只放菜单栏图标；用户自己打开时直接给窗口
        let ev = NSAppleEventManager.shared().currentAppleEvent
        let asLoginItem = ev?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !asLoginItem && !CommandLine.arguments.contains("--background") { showWindow() }
    }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    // MARK: 状态

    func poll() {
        getJSON("health") { [weak self] h in
            guard let self else { return }
            self.status = h.map(Status.init) ?? Status()
            self.polled = true
            self.item.button?.image = self.icon(self.status.running ? .on : (self.status.safeReason != nil ? .paused : .problem))
            // 面板由 sing-box 提供：sing-box 起来 / 停掉时，窗口跟着换成面板 / 状态页
            if self.window?.isVisible == true && self.wanted != self.shown { self.load() }
            self.relaunchIfUpdated()
        }
        getJSON("traffic") { [weak self] t in
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            self?.today = (t?["days"] as? [String: Any])?[f.string(from: Date())] as? [String: Any]
        }
    }

    /// 一键更新换掉了磁盘上的 App：重新打开自己，用上新版
    func relaunchIfUpdated() {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let d = NSDictionary(contentsOf: plist), let v = d["CFBundleShortVersionString"] as? String,
            v != version
        else { return }
        let bg = window?.isVisible == true ? "" : " --args --background"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"\(bg)", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    enum Look { case on, paused, problem }

    /// 菜单栏图标：运行中是实心的「v6」，暂停是空心的，出问题是感叹号（都是模板图，跟随深浅色）
    func icon(_ look: Look) -> NSImage {
        if look == .problem {
            let i = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "有问题")!
            i.isTemplate = true
            return i
        }
        let img = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { r in
            let box = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1.5), xRadius: 3.5, yRadius: 3.5)
            let text = NSAttributedString(string: "v6", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .heavy), .foregroundColor: NSColor.black,
            ])
            let s = text.size()
            let at = NSPoint(x: (r.width - s.width) / 2, y: (r.height - s.height) / 2 + 0.5)
            NSColor.black.set()
            if look == .on {
                box.fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                text.draw(at: at)
            } else {
                box.lineWidth = 1.2
                box.stroke()
                text.draw(at: at)
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = look == .on ? "正在免流" : "已暂停"
        return img
    }

    // MARK: 菜单栏菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let st = status
        let head: String
        if let b = busy { head = b }
        else if !st.helper { head = "本地助手没有响应（服务没装好，或正在重启）" }
        else if let r = st.safeReason { head = "⏸ 已暂停：\(r)" }
        else if !st.singbox { head = "sing-box 没有运行" }
        else { head = "● 正在免流" }
        info(menu, head)
        if st.running, st.fallback != nil { info(menu, "连不上免流服务器，暂时走「不用服务器」，能连上后自动切回") }
        if st.helper, let t = today {
            let server = (t["server"] as? [String: Any])?.values.compactMap { ($0 as? NSNumber)?.doubleValue }.reduce(0, +) ?? 0
            let v6 = (t["v6"] as? NSNumber)?.doubleValue ?? 0, v4 = (t["v4"] as? NSNumber)?.doubleValue ?? 0
            info(menu, "今天：v6 \(bytes(v6)) · 服务器 \(bytes(server)) · v4（计费）\(bytes(v4))")
        }
        menu.addItem(.separator())
        add(menu, "打开面板", #selector(openPanel), "o")
        let pause = add(menu, st.running ? "暂停（回到普通网络）" : "重新启用", #selector(togglePause), "")
        pause.isEnabled = st.helper && busy == nil && (st.running || st.safeReason != nil || !st.singbox)
        if let v = st.latest { add(menu, "有新版本 \(v)，去更新…", #selector(openUpdate), "") }
        menu.addItem(.separator())
        let login = add(menu, "开机时自动打开", #selector(toggleLogin), "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        info(menu, "版本 \(st.version.isEmpty ? version : st.version)")
        add(menu, "退出（免流照常运行）", #selector(quit), "q")
    }

    func info(_ menu: NSMenu, _ title: String) {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        menu.addItem(i)
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        menu.addItem(i)
        return i
    }

    @objc func openPanel() { showWindow() }

    @objc func openUpdate() {
        showWindow()
        if shown == .panel { web.load(URLRequest(url: URL(string: "#settings", relativeTo: PANEL)!)) }
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func togglePause() {
        guard let secret = panelSecret() else {
            return alert("读不到面板密钥", "当前账户不是管理员，或者没装好。可以在面板里暂停 / 重新启用。")
        }
        let pausing = status.running
        if pausing {
            let a = NSAlert()
            a.messageText = "暂停免流？"
            a.informativeText = "sing-box 会停下，电脑回到普通网络（v4 计费）。之后在这里点「重新启用」。"
            a.addButton(withTitle: "暂停")
            a.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        busy = pausing ? "正在暂停……" : "正在重新启用……（要十几秒确认能上网）"
        var req = URLRequest(url: URL(string: pausing ? "pause" : "resume", relativeTo: HELPER)!)
        req.httpMethod = "POST"
        req.httpBody = Data()
        req.timeoutInterval = 120
        req.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        session.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let msg = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["error"] as? String
            DispatchQueue.main.async {
                self.busy = nil
                self.poll()
                if code != 200 { self.alert(pausing ? "暂停失败" : "重新启用失败", msg ?? err?.localizedDescription ?? "错误 \(code)") }
            }
        }.resume()
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("没能修改开机启动", error.localizedDescription + "\n可以在「系统设置 → 通用 → 登录项」里手动添加。")
        }
    }

    /// 第一次打开时默认加入登录项，这样重启后菜单栏图标还在
    func firstRunLoginItem() {
        guard !UserDefaults.standard.bool(forKey: "loginItemSet") else { return }
        try? SMAppService.mainApp.register()
        UserDefaults.standard.set(true, forKey: "loginItemSet")
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: 窗口

    func showWindow() {
        if window == nil { makeWindow() }
        NSApp.setActivationPolicy(.regular)  // 开着窗口时在程序坞里有图标
        window!.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)  // 关掉窗口后只留菜单栏图标
    }

    func makeWindow() {
        let conf = WKWebViewConfiguration()
        // 面板（9090）和助手状态页（9091）各自从 localStorage 取密钥：没有就填上，等于自动登录
        if let s = panelSecret(), let js = try? JSONSerialization.data(withJSONObject: [s]),
            let arr = String(data: js, encoding: .utf8)
        {
            let src = """
                if (location.hostname === "127.0.0.1" && ["9090", "9091"].includes(location.port)) {
                  try { if (!localStorage.getItem("neu-secret")) localStorage.setItem("neu-secret", \(arr)[0]); } catch (e) {}
                }
                """
            conf.userContentController.addUserScript(
                WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        web = WKWebView(frame: .zero, configuration: conf)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")  // 加载前不闪白

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "校园网 v6 免流"
        w.minSize = NSSize(width: 720, height: 480)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = web
        w.center()
        w.setFrameAutosaveName("main")
        window = w
        load()
    }

    /// sing-box 在运行就开面板，否则开助手的状态页（能看原因、重新启用）；助手也不在就给出错页
    var wanted: Page { status.helper && status.singbox ? .panel : (status.helper ? .status : .error) }

    func load() {
        guard web != nil, polled else { return }
        shown = wanted
        switch shown {
        case .panel: web.load(URLRequest(url: PANEL))
        case .status: web.load(URLRequest(url: HELPER))
        default: web.loadHTMLString(errorPage, baseURL: nil)
        }
    }

    let errorPage = """
        <!doctype html><meta charset="utf-8"><style>
        body{font:15px/1.7 -apple-system,"PingFang SC",sans-serif;max-width:560px;margin:80px auto;padding:0 20px;color:#1c2027}
        @media (prefers-color-scheme: dark){body{color:#e6e8ec;background:#1c1e22}}
        code{font:13px ui-monospace,Menlo,monospace}</style>
        <h2>本地服务没有响应</h2>
        <p>sing-box 和本地助手都连不上，可能正在重启，或者没装好。这个窗口会自动重试。</p>
        <p>一直这样的话：重新运行安装包；或在终端运行
        <code>sudo launchctl kickstart -k system/local.neu-v6-free.helper</code>。</p>
        """

    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        // 面板打不开（sing-box 刚停）：先显示出错页，下一轮状态检查再换成该显示的页面
        shown = .error
        w.loadHTMLString(errorPage, baseURL: nil)
    }

    // 本机页面在窗口里开，别的网址（GitHub 等）交给默认浏览器；面板导出的文件走下载
    func webView(
        _ w: WKWebView, decidePolicyFor a: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if a.shouldPerformDownload { return decisionHandler(.download) }
        let url = a.request.url
        let local = ["127.0.0.1", "localhost"].contains(url?.host ?? "")
        if let url, !local, ["http", "https"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ w: WKWebView, navigationAction a: WKNavigationAction, didBecome d: WKDownload) { d.delegate = self }

    func webView(_ w: WKWebView, navigationResponse r: WKNavigationResponse, didBecome d: WKDownload) { d.delegate = self }

    func download(
        _ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename name: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let p = NSSavePanel()
        p.nameFieldStringValue = name
        p.beginSheetModal(for: window!) { completionHandler($0 == .OK ? p.url : nil) }
    }

    func webView(
        _ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction,
        windowFeatures f: WKWindowFeatures
    ) -> WKWebView? {
        if let url = a.request.url { NSWorkspace.shared.open(url) }  // target="_blank"
        return nil
    }

    // 面板用到的 alert / confirm / prompt：WKWebView 默认什么都不显示，要自己弹
    func webView(
        _ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let a = NSAlert()
        a.messageText = m
        a.beginSheetModal(for: window!) { _ in completionHandler() }
    }

    func webView(
        _ w: WKWebView, runJavaScriptConfirmPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let a = NSAlert()
        a.messageText = m
        a.addButton(withTitle: "确定")
        a.addButton(withTitle: "取消")
        a.beginSheetModal(for: window!) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(
        _ w: WKWebView, runJavaScriptTextInputPanelWithPrompt p: String, defaultText d: String?,
        initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (String?) -> Void
    ) {
        let a = NSAlert()
        a.messageText = p
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = d ?? ""
        a.accessoryView = field
        a.addButton(withTitle: "确定")
        a.addButton(withTitle: "取消")
        a.beginSheetModal(for: window!) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    // MARK: 菜单栏最上面的程序菜单（没有「编辑」菜单的话，输入框里 ⌘C / ⌘V 不起作用）

    @objc func reloadPage() { load() }
    @objc func zoomIn() { web?.pageZoom = min((web?.pageZoom ?? 1) + 0.1, 2) }
    @objc func zoomOut() { web?.pageZoom = max((web?.pageZoom ?? 1) - 0.1, 0.6) }
    @objc func zoomReset() { web?.pageZoom = 1 }

    func mainMenu() -> NSMenu {
        let bar = NSMenu()
        func sub(_ title: String, _ items: [(String, Selector?, String, AnyObject?)]) {
            let m = NSMenu(title: title)
            for (t, s, k, target) in items {
                if t == "-" { m.addItem(.separator()); continue }
                let i = NSMenuItem(title: t, action: s, keyEquivalent: k)
                i.target = target
                m.addItem(i)
            }
            let top = NSMenuItem()
            top.submenu = m
            bar.addItem(top)
        }
        sub("校园网 v6 免流", [
            ("关于 校园网 v6 免流", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", nil),
            ("-", nil, "", nil),
            ("隐藏", #selector(NSApplication.hide(_:)), "h", nil),
            ("退出（免流照常运行）", #selector(quit), "q", self),
        ])
        sub("编辑", [
            ("撤销", Selector(("undo:")), "z", nil), ("重做", Selector(("redo:")), "Z", nil), ("-", nil, "", nil),
            ("剪切", #selector(NSText.cut(_:)), "x", nil), ("拷贝", #selector(NSText.copy(_:)), "c", nil),
            ("粘贴", #selector(NSText.paste(_:)), "v", nil), ("全选", #selector(NSText.selectAll(_:)), "a", nil),
        ])
        sub("显示", [
            ("重新载入", #selector(reloadPage), "r", self), ("-", nil, "", nil),
            ("放大", #selector(zoomIn), "+", self), ("缩小", #selector(zoomOut), "-", self),
            ("实际大小", #selector(zoomReset), "0", self),
        ])
        sub("窗口", [
            ("最小化", #selector(NSWindow.performMiniaturize(_:)), "m", nil),
            ("关闭", #selector(NSWindow.performClose(_:)), "w", nil),
        ])
        return bar
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
