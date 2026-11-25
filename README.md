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
  - **Maps**: the map round you drawn by the watch itself from OpenStreetMap data (streets and their names, parks, water, places with pins by kind; zoom and move at once), search with a QWERTY or rotary keyboard, a place's times by car, bike and on foot, the route checked turn by turn, then navigation that buzzes as each turn comes.
  - **Navigation**: MapKit directions, turn by turn on the watch. Location only while a route is on.
  - **Photos**: a photo drawn on the round panel.
  - **Compass**: the iPhone's heading on a turning dial (the watch has no magnetometer).
- **Look**: TwinDesk's theme engine (Liquid Glass on iOS 26, glass cards, accent swatches with Nothing red,
  light/dark), TwinDesk's bottom bar.
- **Battery**: nothing polls. The watch wakes the app over BLE when one of its apps talks; services work only
  while their watch app is open or while you use them here. No analytics.

## Install

### What you need

- An iPhone on **iOS 17 or later**.
- A **CMF Watch Pro 2**, paired with **Nothing X** (keep Nothing X: it still does pairing and health sync).
- A computer (Mac or Windows) once, to set up a sideloading tool, and a free **Apple ID**.

### 1. Get the IPA

Download **`CMFX.ipa`** from the [latest release](../../releases/latest), or from the newest
[Build iOS](../../actions/workflows/build-ios.yml) run (Artifacts › CMFX-iOS, a zip with the IPA in it).

The IPA is unsigned. Your sideloading tool signs it with your Apple ID as it installs it.

### 2. Sideload it (pick one tool)

**AltStore** (Mac or Windows):

1. Install **AltServer** on the computer from [altstore.io](https://altstore.io) and start it.
2. Plug the iPhone in with a cable, unlock it and tap **Trust**. On Windows, iTunes and iCloud must be the versions
   from apple.com, not the Microsoft Store.
3. From AltServer's menu (the ◇ in the menu bar or tray): **Install AltStore › your iPhone**, and sign in with your
   Apple ID.
4. On the iPhone: **Settings › General › VPN & Device Management**, tap your Apple ID and **Trust** it.
5. Open **AltStore › My Apps › +**, pick `CMFX.ipa` (save it to Files first) and wait for it to install.

**SideStore** (no computer after setup): install SideStore as [sidestore.io](https://sidestore.io) explains, then
**My Apps › +** and pick `CMFX.ipa`.

**Sideloadly** (Mac or Windows): drop `CMFX.ipa` on Sideloadly with the iPhone plugged in, enter your Apple ID and
press **Start**.

Then, on iOS 16 or later:

- **Developer Mode**: **Settings › Privacy & Security › Developer Mode** on. The iPhone restarts; confirm with
  **Turn On**.
- If CMFX says "Untrusted Developer": **Settings › General › VPN & Device Management ›** your Apple ID **› Trust**.

With a free Apple ID an app stays signed for **7 days**, and at most 3 sideloaded apps can be active. AltStore and
SideStore refresh CMFX by themselves when they can (AltServer running on the same Wi-Fi for AltStore). If CMFX stops
opening, refresh it in **My Apps**. Your settings stay.

### 3. First launch

1. Open CMFX. Allow **Bluetooth** (needed) and **notifications** (watch apps ask through them).
2. **Watch** tab › **Connect**. CMFX finds the watch Nothing X is connected to and reads its firmware.
3. Location, Calendars, Reminders and Photos are asked for only when you turn on something that needs them.

### 4. The patched firmware

The watch needs the app-loader firmware once. **Watch › Firmware & App Loader**:

- **From fmc.tools**: **Check for updates**, then **Install** (or **Update**). It is about 57 MB.
- **From a file**: **Install firmware from a file…** and pick an OTA image for the CMF Watch Pro 2 (the patched
  firmware from fmc.tools, or one built with cmf-watch-sdk's `make fw-ota`). CMFX checks it before anything goes out.
- **Reinstall**: the same image again, for a watch that misbehaves after an update.

Before you start: charge the watch, keep the phone next to it, and **close Nothing X** (swipe it away). Keep CMFX
open until it says the firmware was sent. The watch then installs it and restarts by itself, which takes a few minutes.
If Nothing X can't see the watch afterwards, forget the watch in iOS Bluetooth settings and add it again in Nothing X.

### 5. The App Loader

On the same page, **App Loader › Install**. It's the one bundled with this CMFX build. The watch must be on its
**watch face** (not in an app or the Apps menu). Apps you already installed stay installed.

### 6. The watch apps

**Watch › Apps**. The top section, **Bundled with CMFX**, has every app made for CMFX, inside the IPA, so no store or
download is needed: Browser, Compass, Gemini, Mail, Maps, Navigation, Notes, Offline Maps, Photos, Speaker, Spotify,
Spotify Control, WhatsApp, YouTube Music.

- **Install all** puts every missing or older one on the watch, or tap **Install** or **Update** on one.
- **All** lists the FMC store's apps (Calendar, Reminders, Weather …) with **Get**.
- On the watch, open them from the Apps menu. Reorder them with **Edit** on the **Installed** list.

### 7. Permissions (Calendar, Reminders, Location …)

Store apps such as Calendar and Reminders read your phone's data through CMFX. Open **Watch › Apps ›** the app:

- **Allow <app> to access** lists Calendars, Reminders, Location, Weather and Send Notifications for every app on
  the watch, so you can allow them **before** the app first asks. Turning one on also asks iOS for its permission.
- **Show text on the watch** must be on for calendar titles and notification text to show; it's off by default.
- An app that asks for something you haven't answered sends a notification "‹app› wants …": tap it to answer.
- If iOS permission is off, the row says **Off in iOS Settings**: **Settings › CMFX** and turn it on.

### 8. The Hub (phone side of the watch apps)

Each service runs only while its app is open on the watch, or while you use it in CMFX.

- **Spotify**: your own Spotify developer app's Client ID (Premium needed for control).
- **Gemini**: your own API key.
- **Maps / Navigation**: allow Location (**Always** keeps turns coming with the phone locked). The map turns with the
  phone's compass when you stand still, and a red **N** on its rim shows north. If no update comes for 12 s, the
  watch says **No update · retrying** and asks the phone again every 5 s until it answers.
- **Compass**: the watch has no magnetometer, so Compass shows **where the iPhone points**. Hold the iPhone flat and
  in line with your arm. Allow Location for true north (else magnetic north). It buzzes as north passes the top mark.

### Troubleshooting

| What you see | What to do |
|---|---|
| "Close Nothing X first" | Swipe Nothing X away in the app switcher, then try again |
| An install says the app or Apps menu is open | Go back to the watch face, then try again |
| The watch isn't found | Bluetooth on, the watch close by and connected in Nothing X; pull to refresh on the Watch tab |
| A watch app says "Waiting for iPhone" | Open CMFX once; keep Bluetooth on. iOS wakes CMFX when the watch app talks |
| CMFX won't open after a week | Refresh it in AltStore / SideStore (the 7-day free signing ran out) |

## Build

```bash
brew install xcodegen
ios/build.sh                       # → ios/dist/CMFX.ipa, unsigned
(cd ios/HubKit && swift test)      # the watch protocols, byte for byte against cmf-watch-sdk's hosts
```

## Licence

GPL-3.0 (see LICENSE). Contains code from FMC Companion (MIT, THIRD_PARTY_FMC_LICENSE) and TwinDesk (GPL-3.0).
Map data © OpenStreetMap contributors.
