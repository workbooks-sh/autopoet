// Native macOS "inset title bar" shim for the Autopoet desktop window.
//
// The window is created by wx as a normal TITLED NSWindow (so it is miniaturizable
// and zoomable — those actions go through plain wx). This NIF only makes it LOOK
// frameless, the Electron `titleBarStyle: hiddenInset` recipe:
//   * titlebarAppearsTransparent + titleVisibility hidden + FullSizeContentView
//     → no title-bar strip; the web content fills the whole frame,
//   * the three native traffic lights are hidden → the page's own custom stoplights
//     (which drive /win/{minimize,maximize,close}) are the only visible controls.
//
// AppKit is MAIN-THREAD ONLY, and a NIF runs on a BEAM scheduler thread, so every
// call hops onto the Cocoa main queue (wx already runs that runloop). We locate the
// window by its title ("autopoet") rather than a handle — this OTP's wx binding has
// no wxWindow:getHandle/1. Every function is a safe no-op if the window isn't found.

#include <erl_nif.h>
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static NSString *term_to_nsstring(ErlNifEnv *env, ERL_NIF_TERM term) {
  ErlNifBinary bin;
  if (!enif_inspect_binary(env, term, &bin)) return nil;
  return [[NSString alloc] initWithBytes:bin.data length:bin.size encoding:NSUTF8StringEncoding];
}

// The app's REAL frame = the LARGEST window whose title matches. wx spawns several
// helper windows that ALSO carry the app title (tiny wxNSPanel strips) — a first-match
// walk once grabbed one of those and reopen "restored" an invisible 38px panel. Class
// filtering doesn't work either: wx's actual frame IS an NSPanel subclass (wxNSPanel).
// Area disambiguates: the frame is orders of magnitude bigger than any helper. And no
// [NSApp mainWindow] shortcut — a miniaturized window is never main, which is exactly
// when reopen needs to find it.
static NSWindow *find_window(NSString *title) {
  NSWindow *best = nil;
  for (NSWindow *w in [NSApp windows]) {
    if (title && ![[w title] isEqualToString:title]) continue;
    if (!best || (w.frame.size.width * w.frame.size.height >
                  best.frame.size.width * best.frame.size.height)) best = w;
  }
  return best ?: [NSApp mainWindow];
}

static void on_main(dispatch_block_t block) {
  dispatch_async(dispatch_get_main_queue(), block);
}

static ERL_NIF_TERM ok(ErlNifEnv *env) { return enif_make_atom(env, "ok"); }

// Confirms the NIF is loaded (the pure-Elixir stub returns :not_loaded).
static ERL_NIF_TERM loaded_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  return ok(env);
}

static ERL_NIF_TERM apply_inset_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  NSString *title = term_to_nsstring(env, argv[0]);
  on_main(^{
    NSWindow *w = find_window(title);
    if (!w) return;
    w.styleMask |= NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                   NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                   NSWindowStyleMaskFullSizeContentView;
    w.titlebarAppearsTransparent = YES;
    w.titleVisibility = NSWindowTitleHidden;
    // opt into REAL macOS fullscreen (its own Space, three-finger swipeable) — wx
    // frames don't set this, which is why the green action could only ever zoom
    w.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    [[w standardWindowButton:NSWindowCloseButton] setHidden:YES];
    [[w standardWindowButton:NSWindowMiniaturizeButton] setHidden:YES];
    [[w standardWindowButton:NSWindowZoomButton] setHidden:YES];
  });
  return ok(env);
}

// Native miniaturize (dock genie) — works because the window is titled+miniaturizable.
static ERL_NIF_TERM miniaturize_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  NSString *title = term_to_nsstring(env, argv[0]);
  on_main(^{ [find_window(title) miniaturize:nil]; });
  return ok(env);
}

// Native green-button zoom (fill the usable area ⇄ restore) — the real macOS toggle.
// Cocoa compares the ACTUAL frame against the standard (zoomed) frame, so this never
// desyncs the way a hand-tracked setSize toggle does after the user drags/resizes.
static ERL_NIF_TERM zoom_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  NSString *title = term_to_nsstring(env, argv[0]);
  on_main(^{ [find_window(title) zoom:nil]; });
  return ok(env);
}

// REAL macOS fullscreen (its own Space; three-finger swipe between fullscreen apps) —
// what users actually mean by the green button. Toggle: same call exits.
static ERL_NIF_TERM toggle_fullscreen_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  NSString *title = term_to_nsstring(env, argv[0]);
  on_main(^{
    NSWindow *w = find_window(title);
    // set fullscreen capability HERE, not just at apply_inset: wx rebuilds window
    // state on show and the boot-time behavior didn't stick (observed behavior=0 →
    // toggleFullScreen: was a silent no-op). Idempotent, so every toggle re-asserts.
    w.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    NSLog(@"[ap_mac_window] toggle_fullscreen (window=%@ style=%lx behavior=%lx)",
          w, (unsigned long)w.styleMask, (unsigned long)w.collectionBehavior);
    [w toggleFullScreen:nil];
  });
  return ok(env);
}

// Dock-click reopen — the REAL Cocoa contract. A Dock click on a running app sends
// applicationShouldHandleReopen:hasVisibleWindows: to the APP DELEGATE; wx/wxe leaves
// that unhandled (or the delegate nil), so the click does NOTHING — crucially even when
// the app is still the ACTIVE app (the normal state right after minimizing its own
// window), where an app-activation observer can never fire because the app never
// *becomes* active. We install our OWN delegate object that handles reopen and forwards
// every other selector to whatever delegate existed before (nil-safe).
static NSString *g_reopen_title = nil;
static id g_orig_delegate = nil;

@interface ApReopenDelegate : NSObject
@end

@implementation ApReopenDelegate
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)flag {
  NSWindow *w = find_window(g_reopen_title);
  NSLog(@"[ap_mac_window] reopen fired (hasVisible=%d, window=%@)", flag, w);
  if (w) {
    if ([w isMiniaturized]) [w deminiaturize:nil];
    [w makeKeyAndOrderFront:nil];   // also pulls the user to the window's Space
    [NSApp activateIgnoringOtherApps:YES];
  }
  return NO;  // handled — AppKit shouldn't try its own reopen dance
}
- (BOOL)respondsToSelector:(SEL)sel {
  return [super respondsToSelector:sel] || [g_orig_delegate respondsToSelector:sel];
}
- (id)forwardingTargetForSelector:(SEL)sel {
  return g_orig_delegate;
}
@end

static ApReopenDelegate *g_reopen_delegate = nil;

static ERL_NIF_TERM install_reopen_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  NSString *title = term_to_nsstring(env, argv[0]);
  on_main(^{
    g_reopen_title = title;
    g_orig_delegate = [NSApp delegate];
    g_reopen_delegate = [[ApReopenDelegate alloc] init];
    [NSApp setDelegate:(id)g_reopen_delegate];
    NSLog(@"[ap_mac_window] reopen installed (orig delegate=%@)", g_orig_delegate);
    // Belt-and-braces: when the app was INACTIVE (some other app frontmost), a Dock
    // click ALSO activates — restore on that signal too (and cmd-tab gets it free).
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidBecomeActiveNotification
                    object:NSApp
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                  NSWindow *w = find_window(title);
                  if (w && [w isMiniaturized]) [w deminiaturize:nil];
                }];
  });
  return ok(env);
}

// Media capture (mic/camera) inside the WKWebView. WebKit asks the webview's
// UIDelegate via requestMediaCapturePermissionForOrigin:…; wx's delegate doesn't
// implement it, so WebKit AUTO-DENIES getUserMedia — the page reports "mic blocked"
// and the app-level TCC prompt never even fires. We wrap the existing UIDelegate
// with a forwarding proxy that GRANTS (the webview only ever loads our own
// localhost surface; macOS TCC still gates the actual device with the system
// prompt, which can now finally appear).
static id g_orig_uidelegate = nil;

@interface ApWebViewUIDelegate : NSObject <WKUIDelegate>
@end

@implementation ApWebViewUIDelegate
- (void)webView:(WKWebView *)webView
    requestMediaCapturePermissionForOrigin:(WKSecurityOrigin *)origin
                          initiatedByFrame:(WKFrameInfo *)frame
                                      type:(WKMediaCaptureType)type
                           decisionHandler:(void (^)(WKPermissionDecision))decisionHandler {
  NSLog(@"[ap_mac_window] media capture request (type=%ld, origin=%@) — granting", (long)type, origin.host);
  decisionHandler(WKPermissionDecisionGrant);
}
- (BOOL)respondsToSelector:(SEL)sel {
  return [super respondsToSelector:sel] || [g_orig_uidelegate respondsToSelector:sel];
}
- (id)forwardingTargetForSelector:(SEL)sel {
  return g_orig_uidelegate;
}
@end

static ApWebViewUIDelegate *g_ui_delegate = nil;

static WKWebView *find_webview(NSView *v) {
  if ([v isKindOfClass:[WKWebView class]]) return (WKWebView *)v;
  for (NSView *s in v.subviews) {
    WKWebView *r = find_webview(s);
    if (r) return r;
  }
  return nil;
}

static ERL_NIF_TERM allow_media_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  NSString *title = term_to_nsstring(env, argv[0]);
  on_main(^{
    NSWindow *w = find_window(title);
    WKWebView *wv = w ? find_webview(w.contentView) : nil;
    if (!wv) { NSLog(@"[ap_mac_window] allow_media: no WKWebView found"); return; }
    g_orig_uidelegate = wv.UIDelegate;
    g_ui_delegate = [[ApWebViewUIDelegate alloc] init];
    wv.UIDelegate = (id)g_ui_delegate;
    // A bare WKWebView ships with media devices DISABLED on macOS (Safari flips a
    // WebKit preference that embedders must set themselves; wx doesn't). Without it
    // getUserMedia dies INSIDE WebKit — no permission callback, no TCC prompt, the
    // page just sees a rejection. KVC onto the (private) preference keys; each is
    // guarded, so a future WebKit renaming degrades to a no-op rather than a crash.
    WKPreferences *prefs = wv.configuration.preferences;
    @try { [prefs setValue:@YES forKey:@"mediaDevicesEnabled"]; } @catch (NSException *e) {}
    @try { [prefs setValue:@YES forKey:@"mediaStreamEnabled"]; } @catch (NSException *e) {}
    @try { [prefs setValue:@NO forKey:@"mediaCaptureRequiresSecureConnection"]; } @catch (NSException *e) {}
    NSLog(@"[ap_mac_window] media-capture grant installed (orig UIDelegate=%@, mediaDevices=%@)",
          g_orig_uidelegate, [prefs valueForKey:@"mediaDevicesEnabled"]);
  });
  return ok(env);
}

static ErlNifFunc funcs[] = {
  {"loaded", 0, loaded_nif},
  {"apply_inset", 1, apply_inset_nif},
  {"miniaturize", 1, miniaturize_nif},
  {"zoom", 1, zoom_nif},
  {"toggle_fullscreen", 1, toggle_fullscreen_nif},
  {"install_reopen", 1, install_reopen_nif},
  {"allow_media", 1, allow_media_nif},
};

ERL_NIF_INIT(Elixir.Autopoet.Window.Mac, funcs, NULL, NULL, NULL, NULL)
