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

static NSString *term_to_nsstring(ErlNifEnv *env, ERL_NIF_TERM term) {
  ErlNifBinary bin;
  if (!enif_inspect_binary(env, term, &bin)) return nil;
  return [[NSString alloc] initWithBytes:bin.data length:bin.size encoding:NSUTF8StringEncoding];
}

// The app's window whose title matches; falls back to the main window.
static NSWindow *find_window(NSString *title) {
  if (title) {
    for (NSWindow *w in [NSApp windows]) {
      if ([[w title] isEqualToString:title]) return w;
    }
  }
  return [NSApp mainWindow];
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

// Dock-click reopen: wx never handles applicationShouldHandleReopen, so clicking the
// Dock icon of a running app with a miniaturized window does NOTHING. Observing app
// activation (a Dock click always activates) and deminiaturizing restores the native
// expectation; a plain cmd-tab to the minimized app restores it too (Chrome behavior).
static ERL_NIF_TERM install_reopen_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  NSString *title = term_to_nsstring(env, argv[0]);
  on_main(^{
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

static ErlNifFunc funcs[] = {
  {"loaded", 0, loaded_nif},
  {"apply_inset", 1, apply_inset_nif},
  {"miniaturize", 1, miniaturize_nif},
  {"zoom", 1, zoom_nif},
  {"install_reopen", 1, install_reopen_nif},
};

ERL_NIF_INIT(Elixir.Autopoet.Window.Mac, funcs, NULL, NULL, NULL, NULL)
