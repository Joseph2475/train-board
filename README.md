# TrainBoard

A live train departure board as a native macOS desktop widget. Styled like the real thing: time, destination, platform, and expected columns, with delayed and cancelled trains colour-coded. Departed trains drop off the board on the minute. Amber-on-black in dark mode, ink-on-paper in light mode.

Six networks, all keyless - pick any station per widget:
- **UK Rail** - live Darwin-backed departures from [traini.ac](https://traini.ac), falling back to the public [Huxley2](https://huxley2.azurewebsites.net) proxy
- **Caltrain** - live predictions from caltrain.com's own feed, optional 511.org fallback
- **Switzerland** - transport.opendata.ch, real platforms and delays
- **Ireland** - Irish Rail's official realtime feed
- **Portugal** - CP's own travel API: Lisbon suburban, Porto urban, IC/AP intercity
- **NET Trams (Nottingham)** - Traveline timetable data (NET publishes no live tracking; real-time lights up automatically if they ever do)

UK data is served by traini.ac, built by [Alistair (@alistaiir)](https://x.com/alistaiir) - cheers Ali.

## Install

Grab `TrainBoard.zip` from the [latest release](https://github.com/Joseph2475/train-board/releases/latest), unzip, drag `TrainBoard.app` into Applications, and open it. Releases are notarized - no security warnings.

Then: right-click the desktop > Edit Widgets > search "Train Board" and add widgets in small, medium, or large. Right-click any widget > **Edit Train Board** to pick its station - add as many widgets as you like, each with its own station.

## Build from source

Needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). First copy `Shared/Secrets.example.swift` to `Shared/Secrets.swift` and set a [free 511.org key](https://511.org/open-data/token) (only used as the Caltrain fallback; any placeholder string builds fine). Then:

```sh
xcodegen generate
xcodebuild -project TrainBoard.xcodeproj -scheme TrainBoard -configuration Release -derivedDataPath build build
cp -R build/Build/Products/Release/TrainBoard.app /Applications/
```

Made by [@joseph_moylan2](https://x.com/joseph_moylan2)
