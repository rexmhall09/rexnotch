# RexNotch setup

RexNotch is a local fork of [Boring Notch](https://github.com/TheBoredTeam/boring.notch), based on its `dev` branch. It has its own app ID (`com.rexmh.rexnotch`) and settings, so it can coexist with an upstream installation. The app is distributed under the upstream GPL-3.0-or-later license.

## Build

Open `boringNotch.xcodeproj` and build the `boringNotch` scheme, or run `Tools/build-rexnotch.sh` for a locally signed app in `build/RexNotch.app`. Set `REXNOTCH_OUTPUT_DIR` to package it elsewhere. The underlying Xcode command is:

```sh
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch \
  -configuration Release -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
```

The product is `RexNotch.app`. The fork removes an unused `swift-collections` link that pulled in a Swift runtime symbol unavailable on macOS 26.6. Local ad-hoc builds need the embedded MediaRemoteAdapter framework signed with the same identity as the app; the packaged app handles that separately.

## Data and permissions

- **Closed notch:** Empty while idle. Volume, brightness, and incoming notification indicators appear transiently.
- **Expanded panel:** Claude and Codex session and weekly usage, Boring Notch's original calendar, Now Playing only while playback is active, and live CPU/GPU/RAM percentages in the header. The existing Boring Notch hover animation and controls remain in use.
- **Shelf:** Disabled in this fork; the panel always opens to the dashboard.
- **Usage:** RexNotch reads the existing Claude Code Keychain login and `~/.codex/auth.json`, then queries the two providers' usage endpoints directly. It refreshes expired access tokens through their OAuth endpoints. No credentials are sent to RexNotch's developer or stored outside the provider login locations. These usage endpoints may change.
- **Calendar:** EventKit requests Calendar access when you use the card. The app's bundle ID is new, so macOS will ask again even if Boring Notch already had access.
- **Notifications:** Boring Notch's Accessibility based mirroring is enabled by default. Approve Accessibility for RexNotch when requested. It mirrors visible banners; it does not read Notification Center history.
- **Volume and brightness:** The existing Boring Notch HUD and media key handling are retained.

RexNotch does not use the upstream Sparkle update feed, which would replace custom code with an upstream build.
