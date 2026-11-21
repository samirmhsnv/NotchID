# NotchID

**Face ID–style unlock for your Mac, with a Dynamic Island animation in the notch.**

![NotchID: the notch shows a green check after recognising your face, next to the enrolment and settings windows](docs/screenshots/hero.png)

NotchID is a small menu-bar app. When your Mac's lock screen comes up, it looks at you through the
built-in camera. If it recognises you, the notch plays an iPhone-style unlock animation and NotchID
unlocks the real macOS lock screen.

> [!IMPORTANT]
> This is a convenience tool, not a security feature. Read [How it works](#how-it-works) and
> [Limits](#honest-limits) before you use it.

## Features

- **Face recognition on the Mac**: uses Apple's Vision framework (face detection, landmarks and
  feature prints) on the built-in or an external camera. Everything runs on your Mac.
- **Attention check**: your eyes must be open, so it won't unlock while you're asleep in front of the screen.
- **Optional blink check**: for liveness. You have to blink, which stops a printed photo from unlocking.
- **iPhone-style enrolment**: a circular camera view with a ring of 90 ticks that turn green as you
  roll your head. You do two passes, just like on iPhone.
- **Dynamic Island in the notch**: your avatar → the Face ID glyph scanning → a green check → *"Welcome back, Name"*.
  A failed match shakes the glyph red.
- **Two unlock styles**:
  - *Open the desktop*: unlock as soon as you're recognised.
  - *Stay on Lock Screen until I press a key or swipe*: like iPhone. An open padlock appears with
    *"Press any key or swipe up to open"*.
- **Works on the lock screen**: the notch animation is drawn above the macOS lock screen.
- Strictness slider, live *Test recognition*, open at login, and a ⌘L *Lock Screen* shortcut in the menu.
- Works without a notch too: the island then drops down from the top centre of the screen.

### The notch animation

![The six notch phases: avatar, scanning, recognised, press a key to open, welcome back, and failed](docs/screenshots/notch-phases.png)

### Setup and settings

| Enrolment (mid-scan) | Done | Settings |
| --- | --- | --- |
| ![Enrolment screen: circular camera view with a ring of ticks partly lit green](docs/screenshots/enroll-scanning.png) | ![Face ID is now set up](docs/screenshots/enroll-done.png) | ![NotchID Settings window](docs/screenshots/settings.png) |

*The screenshots are rendered by the app itself (`--render-screenshots`) using an illustrated
placeholder face and a made-up name.*

## How it works

1. **Enrolment.** For each camera frame, Vision finds your face, checks your eyes are open and
   computes a *feature print* (a numeric description of the face image). NotchID keeps about 30
   straight-on prints and up to 24 angled prints from your head roll. It then sets a match threshold
   from how much your own straight-on prints differ from each other. A cropped frame becomes your avatar.
2. **Watching for the lock screen.** NotchID listens for `com.apple.screenIsLocked`, display wake
   and any keyboard or mouse activity while locked. Any of these starts a scan of up to 12 seconds
   (moving the mouse or pressing a key is like raising an iPhone).
3. **Matching.** A frame counts as a match when its print is close enough to your enrolled prints,
   your eyes are open, and (if enabled) you've blinked. Two matching frames are needed.
4. **Unlocking.** Apple doesn't allow third-party apps to replace or unlock the login window. So
   NotchID does what you would do: it **types your login password** into the lock screen and
   presses Return, using synthesised keyboard events (`CGEvent`). This needs the Accessibility
   permission. Your password is checked against your account with OpenDirectory when you save it,
   and stored in your login Keychain.
5. **Notch on the lock screen.** The notch panel is moved into a high-level window space through
   the private SkyLight framework, the same trick other notch utilities use. That is what lets it
   show above the lock screen.

### Honest limits

- **It isn't Apple's Face ID.** iPhone Face ID uses a TrueDepth 3D sensor and the Secure Enclave.
  Macs only have a regular 2D camera, so NotchID is much easier to fool. A good photo or video of you
  may work, especially with the blink check off. Someone who looks like you may work.
  Use it where that risk is acceptable.
- **It types your real password.** If NotchID or your account is compromised, so is the password
  it stores. It is kept in your Keychain, but it is still your password.
- **FileVault and the boot screen aren't covered.** NotchID only runs after you've logged in, so
  you still type your password after a restart.
- **Private API.** Showing the notch on the lock screen uses private SkyLight calls. macOS 27 refuses
  them to ordinary apps, so there the scan runs out of sight and the animation plays right after you're
  unlocked. Unlocking itself works either way.
- **Local signing.** `build.sh` creates a self-signed code-signing identity in its own keychain
  (`scripts/sign.sh`, the key never leaves your Mac) so Accessibility, Camera and Keychain approvals
  survive rebuilds. Whoever can use that identity can sign a program that passes for NotchID and
  reads the saved password, so it is guarded: the signing keychain has a random password, kept in
  your login keychain where no app can read it without a macOS prompt (that entry is recreated after
  every build, so a mistaken *Always Allow* doesn't last); and the keychain is locked again right
  after signing. If signing fails for another
  reason, `build.sh` falls back to ad-hoc signing, and then you have to re-allow Accessibility after
  every rebuild.
- The camera has to see you. It works poorly in very dark rooms or with the lid nearly closed.

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon or Intel Mac with a camera (a notch is optional)
- Xcode **Command Line Tools** (`xcode-select --install`). Full Xcode isn't needed.

## Install

Paste in Terminal:

```bash
curl -fsSL https://github.com/samirmhsnv/NotchID/releases/latest/download/NotchID.zip -o /tmp/NotchID.zip && { pkill -x NotchID; sleep 1; rm -rf /Applications/NotchID.app; ditto -x -k /tmp/NotchID.zip /Applications && open /Applications/NotchID.app; }
```

The same line updates an installed copy. The release is a universal build (Apple Silicon and Intel)
with an ad-hoc signature, so after each update macOS asks again for Accessibility and for Keychain
access to the saved password. Downloaded the zip in a browser instead? Run
`xattr -dr com.apple.quarantine /Applications/NotchID.app` once before opening it.

## Build from source

```bash
git clone <your-fork-url> NotchID
cd NotchID
./build.sh                       # builds build/NotchID.app (release, signed with a local identity)
# macOS asks to let "security" use "NotchID signing keychain": click Allow (not Always Allow)
cp -R build/NotchID.app /Applications/
open /Applications/NotchID.app
```

NotchID has no Dock icon. Look for the Face ID icon in the menu bar.

> **Note for contributors:** the Command Line Tools SDK can't expand SwiftUI's `@State` macro.
> Use `@StateObject` with the `Box<T>` helper in `NotchView.swift` instead.

To make a release, run `./build.sh --release` and attach `build/NotchID.zip` to a GitHub release:

```bash
./build.sh --release
gh release create v1.0.0 build/NotchID.zip --title "NotchID 1.0.0" --generate-notes
```

The decisions behind a scan (two matching frames in a row, the blink, eye openness, the enrolment
threshold and what setup is missing) live in `Sources/NotchIDCore` and have tests. Run them with
`./test.sh`, which also works with only the Command Line Tools installed.

To regenerate the README screenshots:

```bash
build/NotchID.app/Contents/MacOS/NotchID --render-screenshots docs/screenshots
```

## Setup

1. **Scan your face.** The enrolment window opens on first launch (or choose *Set Up Face ID…* in
   the menu). Click *Get Started*, put your face in the circle and slowly roll your head until all
   the ticks are green. Then do it a second time.
2. **Allow the camera** when macOS asks.
3. **Save your Mac login password** in *Settings → Password*. It's checked before it's saved.
4. **Allow Accessibility** in *Settings → Permissions*. macOS opens *System Settings → Privacy &
   Security → Accessibility*; turn on NotchID there.
5. Try it: choose **Lock Screen** (⌘L) from the menu and look at your Mac.

The menu shows whether unlocking is ready. If something is missing, *Settings* tells you what.

## Settings

| Setting | What it does |
| --- | --- |
| **Unlock this Mac with Face ID** | Main on/off switch (also in the menu). |
| **When Face ID recognises you** | *Open the desktop* unlocks straight away. *Stay on Lock Screen until I press a key or swipe* shows the open padlock and waits for a key press or trackpad swipe, like iPhone. |
| **Require a blink** | Also requires a blink during the scan. Slightly slower, but stops still photos. |
| **Strictness** | How closely a face must match. It's set automatically when you enrol. Move it toward *Strict* if it accepts other people, toward *Loose* if it rejects you. |
| **Test recognition** | Shows live whether you're recognised and how close the match is. |
| **Mac login password** | The password NotchID types for you. *Change…* or *Remove* it at any time. |
| **Permissions** | Status of Camera and Accessibility, with buttons to allow them. |
| **Your name** | The name in *"Welcome back, …"*. |
| **Open NotchID at login** | Registers NotchID as a login item. |

The menu also has **Play Unlock Animation** to preview the notch, and **Set Up Face ID…** to enrol again.

## For other notch apps

NotchID posts two distributed notifications around every animation, so an app that also draws in
the notch can keep out of the way:

```swift
let center = DistributedNotificationCenter.default()
center.addObserver(forName: .init("app.notchid.notch.began"), object: nil, queue: .main) { _ in /* step aside */ }
center.addObserver(forName: .init("app.notchid.notch.ended"), object: nil, queue: .main) { _ in /* come back */ }
```

Every `began` is followed by an `ended`. An animation usually lasts a few seconds; on the lock
screen it runs as long as the camera looks for you.

## Privacy

- Face data never leaves your Mac. NotchID makes no network requests.
- Your face prints (`face.prints`) and avatar (`avatar.png`) are stored in
  `~/Library/Application Support/NotchID`. NotchID stores feature prints, not video. The avatar is a
  single cropped frame from enrolment.
- Your login password is stored in your login Keychain (service `app.notchid.login-password`).
- Settings live in the app's `UserDefaults`.

To remove everything: choose *Remove* next to the password in Settings (or delete the
`app.notchid.login-password` item in Keychain Access), quit NotchID, then delete the app and
`~/Library/Application Support/NotchID`.

## Troubleshooting

| Problem | Try this |
| --- | --- |
| Recognised, but the Mac doesn't unlock | Check Accessibility in *Settings → Permissions*. If it was granted to an older build, run `tccutil reset Accessibility app.notchid.NotchID` and allow it again. `~/Library/Logs/NotchID.log` shows each step. |
| `./build.sh` asks to let *security* use "NotchID signing keychain" | Click *Allow* (enter your login password if asked). That unlocks the signing key for this build only. *Deny* stops the build. |
| A dialog asks for the password of the "notchid-signing" keychain | Click *Cancel*. Only `build.sh` needs that keychain, and it unlocks it with the stored random password. |
| macOS asks NotchID for Keychain access | Choose *Always Allow* once. NotchID reads the password at launch so the Lock Screen never prompts. |
| "That isn't your Mac login password" | Use the password for your macOS user account, not your Apple Account password. |
| Doesn't recognise me | Re-enrol in the light you normally use, use *Test recognition*, and move *Strictness* toward *Loose*. Take off sunglasses. |
| Recognises someone else | Move *Strictness* toward *Strict* and turn on *Require a blink*. |
| No animation on the lock screen | macOS 27 doesn't let apps draw over the lock screen ([#8](https://github.com/samirmhsnv/NotchID/issues/8)). Unlocking still works, and NotchID plays the animation as soon as you're unlocked. *Settings* says when this applies. |
| Camera light stays on | It turns off when the scan ends (at most about 12 s). Quit NotchID if it doesn't. |
| The menu bar icon vanishes | A crowded menu bar hides items behind the notch. Open NotchID again (Spotlight or Finder) to get *Settings*, quit some menu bar apps, or hold ⌘ and drag the Face ID icon further right. |
| Nothing happens on lock | The menu must say *Face ID unlock is on*. Otherwise open *Settings* to see what's missing. |

## Disclaimer

NotchID is an independent, unofficial project. It is not affiliated with or endorsed by Apple.
"Face ID", "Dynamic Island" and "macOS" are trademarks of Apple Inc., used here only to describe
what the app is like. NotchID weakens your Mac's lock screen in exchange for convenience. Use it
at your own risk; the software is provided "as is" under the [MIT License](LICENSE).
