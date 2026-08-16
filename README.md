# TrainBoard

A live train departure board as a native macOS desktop widget. Amber-on-black, styled like the real thing: time, destination, platform, and expected columns, with delayed and cancelled trains colour-coded. Departed trains drop off the board on the minute.

Supports two networks, switchable in the app:
- **UK Rail** - National Rail's live departure feed (via the public [Huxley2](https://huxley2.azurewebsites.net) proxy, no API key needed)
- **Caltrain** - live predictions from caltrain.com's own feed (no API key needed), with an optional 511.org fallback

## Install

Grab `TrainBoard.zip` from the [latest release](https://github.com/Joseph2475/train-board/releases/latest), then:

1. Unzip and drag `TrainBoard.app` into Applications.
2. Open it. macOS will block it (not notarized) - go to System Settings > Privacy & Security, scroll down, click **Open Anyway**.
3. Launch the app once, search for your station, and set it.
4. Right-click the desktop > Edit Widgets > search "Train Board" and add the widget. If it doesn't show in the list, log out and back in.

The app window is just settings - the widget runs on its own, app closed or not.

## Build from source

Needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). First copy `Shared/Secrets.example.swift` to `Shared/Secrets.swift` and set a [free 511.org key](https://511.org/open-data/token) (only used as the Caltrain fallback; any placeholder string builds fine). Then:

```sh
xcodegen generate
xcodebuild -project TrainBoard.xcodeproj -scheme TrainBoard -configuration Release -derivedDataPath build build
cp -R build/Build/Products/Release/TrainBoard.app /Applications/
```

Made by [@joseph_moylan2](https://x.com/joseph_moylan2)
