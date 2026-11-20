# NowBar

A menu-bar Now Playing controller for macOS whose floating HUD stays usable inside Mission Control: it fades in and out with the trackpad swipe, and its buttons and seek bar work while Mission Control is open.

## Build and install

```bash
./build.sh               # build, install to /Applications/NowBar.app, relaunch
./build.sh --no-install  # build only, into build/NowBar.app
```

Needs `media-control` (`brew install media-control`) and Accessibility permission. The build signs with the self-signed `NowBar Dev` identity when it exists, so the Accessibility grant survives rebuilds.

**One copy only.** `/Applications/NowBar.app` is the only copy that should stay on the Mac (Spotlight lists every other one). `build.sh` unregisters and deletes its staging bundle after installing. Check with `mdfind 'kMDItemCFBundleIdentifier == "com.nowbar.app"'`.

Debug flags on the installed binary (quit the running copy first so two taps don't both act):

```bash
/Applications/NowBar.app/Contents/MacOS/NowBar --verbose    # log state, taps, swipes to stderr
/Applications/NowBar.app/Contents/MacOS/NowBar --selftest   # open MC, click play/pause on the HUD, verify, restore
```

The app icon is drawn by `packaging/make_icon.swift`; run `swift packaging/make_icon.swift` after changing it and commit `packaging/NowBar.icns`.

## How it works (and what was learned the hard way)

**Now Playing.** MediaRemote is entitlement-gated since macOS 15.4, so NowBar runs one long-lived `media-control stream --micros`. Each line is `{"type":"data","diff":bool,"payload":{…}}`: `diff:false` is a full state (`{}` = nothing playing, and every new stream opens with one), `diff:true` carries only changed keys, and a `null` value means the key was removed. Artwork arrives in the stream only when it changes, about 30 ms after a track change. Spotify issues a new `contentItemIdentifier` on every play, pause and seek, so it can't identify a track. Commands are separate `media-control` calls on a serial queue, with optimistic HUD updates that lapse after 2 s if the stream never confirms them.

**Mission Control detection.** NowBar polls the window list (every 0.2 s): two or more full-screen Dock windows at layer ≥ 0 means Mission Control is open. The Dock's `AXExposeShowAllWindows` notification arrives ~270 ms later than the poll, so it only confirms. `AXExposeExit` lands a few ms before the Dock's windows are torn down; hiding on it is what prevents a leftover full-opacity HUD.

**Event taps.**
- A HID tap (clicks, keys) and a session tap (hover relocation) are enabled only while Mission Control is open. Disabling a tap delivers `tapDisabledByUserInput` to its own callback: re-enable there only while MC is active, and never disable from inside the callback (that loops).
- An always-on, listen-only tap takes only CGS event type 30 (Dock swipes; field 110 = 23). Field 132 is the phase (1 began, 2 changed, 4 ended, 8 cancelled), 123 the axis (2 = vertical), double 124 the progress (0→±1), and double 129 the release velocity. The HUD's opacity follows the progress; the release velocity predicts the outcome.

`probes/` holds the experiments that established the window layers, click delivery and tap behaviour inside Mission Control.
