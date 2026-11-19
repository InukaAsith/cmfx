# CMFX

An iPhone companion for the **CMF Watch Pro 2** with the patched app-loader firmware
([cmf-watch-sdk](https://github.com/InukaAsith)): it runs next to Nothing X, which keeps its connection and health sync.

- **Faces, Apps, Firmware, phone services**: everything from FMC Companion (watch-face catalogue, app store and
  installs, loader and firmware updates, calendar, reminders, weather, notifications for watch apps).
- **Hub**: the phone half of the watch apps:
  - **Spotify**: now playing with art, play/pause/skip, crown volume, like, playlists, search and play, add to
    a playlist, Spotify Connect output device. Your own Spotify developer app (PKCE); control needs Premium.
  - **Gemini**: streamed answers into the watch's chat bubbles, with your own API key.
  - **Offline Maps**: pick a region, it is built on the phone in the Nothing dark style and saved on the watch.
  - **Navigation**: MapKit directions, turn by turn on the watch. Location only while a route is on.
  - **Photos**: a photo drawn on the round panel.
- **Look**: TwinDesk's theme engine (Liquid Glass on iOS 26, glass cards, accent swatches with Nothing red,
  light/dark), TwinDesk's bottom bar.
- **Battery**: nothing polls. The watch wakes the app over BLE when one of its apps talks; services work only
  while their watch app is open or while you use them here. No analytics.

## Install

Download `CMFX.ipa` from the latest [Build iOS](../../actions/workflows/build-ios.yml) run (or a release) and
sideload it with AltStore, SideStore or any signing tool. iOS 17 or later.

## Build

```bash
brew install xcodegen
ios/build.sh                       # → ios/dist/CMFX.ipa, unsigned
(cd ios/HubKit && swift test)      # the watch protocols, byte for byte against cmf-watch-sdk's hosts
```

## Licence

GPL-3.0 (see LICENSE). Contains code from FMC Companion (MIT, THIRD_PARTY_FMC_LICENSE) and TwinDesk (GPL-3.0).
Map data © OpenStreetMap contributors.
