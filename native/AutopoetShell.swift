// AutopoetShell — the native macOS front of the Autopoet desktop app (wb-402zq).
//
// A real AppKit application owns everything macOS cares about — the window,
// the WKWebView, the Dock tile, the menu bar, reopen, fullscreen, and the TCC
// identity (usage strings + entitlements ride THIS process's bundle:
// /Applications/Autopoet.app) — and the BEAM release runs behind it as a plain
// HEADLESS child (AUTOPOET_HEADLESS=1) serving http://127.0.0.1:<port>.
//
// This replaces the wx window + the ap_mac_window.m shim lane for the GUI:
// the Elixir runtime is untouched and stays platform-agnostic; only the shell
// is native. Env plumbing stays in Resources/launch.sh (spawned, not exec'd).
//
// Page contract:
//   * the page's custom stoplights call win("minimize"|"maximize"|"close");
//     the client posts those through webkit.messageHandlers.autopoet when the
//     bridge exists (this shell), else falls back to POST /win/:action (wx).
//     "maximize" toggles REAL fullscreen — same semantics as the wx lane.
//   * getUserMedia: WKUIDelegate grants the WebKit-layer ask for our own
//     localhost surface; macOS TCC still owns the real device prompt, which
//     lands on this app (usage strings present in Info.plist).

import Cocoa
import WebKit

// The top strip of the frameless window: dragging it moves the window,
// double-click zooms — the native titlebar affordances the hidden bar owned.
final class DragStrip: NSView {
  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 { window?.zoom(nil) } else { window?.performDrag(with: event) }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKUIDelegate, WKScriptMessageHandler {
  var window: NSWindow!
  var webView: WKWebView!
  var runtime: Process?
  var quitting = false

  var port: String { ProcessInfo.processInfo.environment["AUTOPOET_PORT"] ?? "4477" }
  var appURL: URL { URL(string: "http://127.0.0.1:\(port)/")! }
  var probeURL: URL { URL(string: "http://127.0.0.1:\(port)/auth/state.json")! }

  func applicationDidFinishLaunching(_ note: Notification) {
    buildMenu()
    spawnRuntime()
    buildWindow()
    showSplash()
    waitForServer(deadline: Date().addingTimeInterval(90))
  }

  // ── the BEAM child ─────────────────────────────────────────────────────────
  // launch.sh owns all env plumbing (per-install secret, seed, data dirs, log);
  // the shell adds only HEADLESS (no wx window — this shell IS the window).
  func spawnRuntime() {
    guard let res = Bundle.main.resourcePath else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [res + "/launch.sh"]
    var env = ProcessInfo.processInfo.environment
    env["AUTOPOET_HEADLESS"] = "1"
    p.environment = env
    p.terminationHandler = { [weak self] _ in
      DispatchQueue.main.async {
        // the app cannot outlive its brain — but don't fight an in-progress quit
        guard let self, !self.quitting else { return }
        self.quitting = true
        NSApp.terminate(nil)
      }
    }
    do { try p.run(); runtime = p } catch {
      NSLog("[autopoet-shell] runtime spawn failed: \(error)")
    }
  }

  // ── the window (hiddenInset look; the page's stoplights are the chrome) ────
  func buildWindow() {
    let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let w = NSWindow(
      contentRect: area,
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    w.title = "autopoet"
    w.titleVisibility = .hidden
    w.titlebarAppearsTransparent = true
    w.collectionBehavior.insert(.fullScreenPrimary)
    w.backgroundColor = NSColor.windowBackgroundColor
    w.isReleasedWhenClosed = false
    for b: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
      w.standardWindowButton(b)?.isHidden = true
    }

    let config = WKWebViewConfiguration()
    config.userContentController.add(self, name: "autopoet")
    config.mediaTypesRequiringUserActionForPlayback = []
    // getUserMedia inside WKWebView: modern WebKit supports it officially, but
    // these embedder preferences still gate it on some OS versions. KVC onto
    // each key ONLY when its setter exists — an unguarded setValue on a
    // renamed key raises an uncatchable NSException in Swift.
    let prefs = config.preferences
    let flips: [(String, Bool)] = [("mediaDevicesEnabled", true),
                                   ("mediaStreamEnabled", true),
                                   ("mediaCaptureRequiresSecureConnection", false)]
    for (key, val) in flips {
      let setter = NSSelectorFromString("set\(key.prefix(1).uppercased() + key.dropFirst()):")
      if prefs.responds(to: setter) { prefs.setValue(val, forKey: key) }
    }

    let wv = WKWebView(frame: w.contentView!.bounds, configuration: config)
    wv.autoresizingMask = [.width, .height]
    wv.uiDelegate = self
    w.contentView!.addSubview(wv)

    // native drag/zoom affordance across the very top (WKWebView swallows
    // mouse events, so the hidden titlebar can't drag through it)
    // 7px — parity with the wx drag strip: tucks above #toprow (7px) without
    // covering any page control
    let strip = DragStrip(frame: NSRect(x: 0, y: w.contentView!.bounds.height - 7,
                                        width: w.contentView!.bounds.width, height: 7))
    strip.autoresizingMask = [.width, .minYMargin]
    w.contentView!.addSubview(strip)

    w.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window = w
    webView = wv
  }

  // a quiet theme-aware holding card until the runtime answers
  func showSplash() {
    let html = """
    <!doctype html><meta charset="utf-8"><style>
      html,body{height:100%;margin:0;display:grid;place-items:center;
        background:#fbfbf9;font:13px ui-monospace,monospace;color:#67707c}
      @media(prefers-color-scheme:dark){html,body{background:#101318;color:#8a95a2}}
      .p{animation:pulse 1.6s ease infinite}
      @keyframes pulse{0%,100%{opacity:.9}50%{opacity:.35}}
      @media(prefers-reduced-motion:reduce){.p{animation:none}}
    </style><div class="p">autopoet is waking up…</div>
    """
    webView.loadHTMLString(html, baseURL: nil)
  }

  func waitForServer(deadline: Date) {
    var req = URLRequest(url: probeURL)
    req.timeoutInterval = 2
    URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        if let http = resp as? HTTPURLResponse, http.statusCode < 500 {
          self.webView.load(URLRequest(url: self.appURL))
        } else if Date() < deadline {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.waitForServer(deadline: deadline) }
        } else {
          let log = NSHomeDirectory() + "/Library/Application Support/Autopoet/autopoet.log"
          self.webView.loadHTMLString(
            "<!doctype html><meta charset='utf-8'><body style='font:13px ui-monospace,monospace;padding:40px'>" +
            "the runtime didn't come up. log: <code>\(log)</code>", baseURL: nil)
        }
      }
    }.resume()
  }

  // ── WebKit media-capture ask → grant (our own localhost surface only) ──────
  func webView(_ webView: WKWebView,
               requestMediaCapturePermissionFor origin: WKSecurityOrigin,
               initiatedByFrame frame: WKFrameInfo,
               type: WKMediaCaptureType,
               decisionHandler: @escaping (WKPermissionDecision) -> Void) {
    NSLog("[autopoet-shell] media capture ask (type=%ld origin=%@) — granting", type.rawValue, origin.host)
    decisionHandler(.grant)
  }

  // ── the page's stoplights ──────────────────────────────────────────────────
  func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.name == "autopoet", let cmd = message.body as? String else { return }
    switch cmd {
    case "minimize":   window.miniaturize(nil)
    case "maximize":   window.toggleFullScreen(nil)   // green = REAL fullscreen (wx-lane parity)
    case "zoom":       window.zoom(nil)
    case "fullscreen": window.toggleFullScreen(nil)
    case "close":      NSApp.terminate(nil)
    default: break
    }
  }

  // ── app citizenship ────────────────────────────────────────────────────────
  func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    return false
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

  func applicationWillTerminate(_ note: Notification) {
    quitting = true
    // launch.sh exec's the release which exec's beam — one pid chain, SIGTERM
    // gives the BEAM its orderly shutdown
    runtime?.terminate()
  }

  // Minimal real menu bar: without an Edit menu, cmd-C/V/X/A are dead inside
  // the webview — the single most "not a real Mac app" tell for text fields.
  func buildMenu() {
    let main = NSMenu()

    let appItem = NSMenuItem(); main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "About Autopoet", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide Autopoet", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit Autopoet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu

    let editItem = NSMenuItem(); main.addItem(editItem)
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit

    let viewItem = NSMenuItem(); main.addItem(viewItem)
    let view = NSMenu(title: "View")
    view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
    viewItem.submenu = view

    let winItem = NSMenuItem(); main.addItem(winItem)
    let win = NSMenu(title: "Window")
    win.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
    win.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
    win.addItem(.separator())
    win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    winItem.submenu = win
    NSApp.windowsMenu = win

    NSApp.mainMenu = main
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
