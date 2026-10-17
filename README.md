# Stem Eye

The iPad half of the **stem reader**. Stem Eye is a screen broadcast, the same kind of thing as a Zoom screen share. While djay runs, it sends small, shrunk pieces of djay's screen to the lighting Controller over the home Wi-Fi: the Neural Mix stem lanes, the mixer and the transport row. That's about 12 frames a second and around half a megabyte a second.

The Controller (build 17c or later) reads djay's own beat grid and stems from those pieces. That's how it knows the drops, breaks and builds a few bars before they happen. Nothing is recorded or kept on the iPad.

You never need a Mac. GitHub's Mac builds the app, tests it against one of your djay screen recordings, and sends it to TestFlight.

```
 iPad: djay  ──(ReplayKit: every screen frame)──>  Stem Eye broadcast extension
                                                     │  crops + shrinks (TileSampler), RGB565, deflate, XOR deltas
                                                     ▼
                         POST http://<Controller>:8080/sr/push   ~12 / s, one at a time, clock-synced
                                                     ▼
             Controller 17c: the stem reader (worker thread) ─> STEM DROPS, the CC's STEM card
```

## Sunday night: from the Apple account to the app on the iPad

You only do this once. After that, every new version is one button on GitHub.

1. **Apple Developer Program.** Finish enrolling at developer.apple.com. Then open **Membership details** and copy your **Team ID** (10 characters).
2. **API key for GitHub.**
   - Go to **App Store Connect › Users and Access › Integrations › App Store Connect API**. The first time, it asks you to request access. Then press **+** to make a *Team* key: name `GitHub`, access **Admin**.
   - Download the `AuthKey_XXXXXXXXXX.p8` file. Apple only lets you download it once, so keep it somewhere safe.
   - Copy the **Key ID** (in the key's row) and the **Issuer ID** (above the list).
3. **Put them on GitHub.** In this repo, go to **Settings › Secrets and variables › Actions**.
   - **Secrets** tab:
     - `ASC_KEY_ID` = the Key ID
     - `ASC_ISSUER_ID` = the Issuer ID
     - `ASC_KEY_P8` = the whole text of the .p8 file (open it in Notepad, copy everything including the BEGIN/END lines)
   - **Variables** tab:
     - `TEAM_ID` = your Team ID
     - Optional: `CONTROLLER` = the Controller's address (like `192.168.1.50`), baked in as the default
     - Optional: `BUNDLE_PREFIX` (default `com.mikeylegs`, which makes the app `com.mikeylegs.djayreader` and its broadcast `com.mikeylegs.djayreader.broadcast`)
4. **First run.** Go to **Actions › Stem Eye › Run workflow**, tick **upload**, and press Run. It registers the two app IDs with Apple. The first time, it then stops with *"No App Store Connect app … yet"*. That's expected.
5. **Make the app record** (once). Go to **App Store Connect › Apps › + › New App**:
   - Platform: iOS
   - Name: anything not already taken on the App Store, e.g. `Stem Eye` or `Stem Eye Mike`
   - Language: English
   - Bundle ID: pick `com.mikeylegs.djayreader`
   - SKU: `djayreader`
6. **Run the workflow again** with **upload** ticked. It takes about 10 minutes and ends with *"Sent build … to App Store Connect"*.
7. **TestFlight.**
   - In App Store Connect, open the app › **TestFlight**. Wait for the build to finish processing (5–30 minutes; Apple emails you).
   - Under **Internal Testing**, press **+**, make a group (e.g. `Me`), add yourself, and add the build.
   - On the iPad, install **TestFlight** from the App Store, sign in with the same Apple ID, and install **Stem Eye**.
8. **On the iPad.**
   - Open Stem Eye. Type the Controller's address (the host in your CC link, like `192.168.1.50`) and tap **Test connection**.
   - iPadOS asks to allow **Local Network**: say **yes**. It should then say *"Connected: stem reader 17c"*.
9. **Watch djay.**
   - Tap the round button, pick **Stem Eye**, then **Start Broadcast**. After the 3-2-1, open djay: full screen, landscape, the two-deck view with the Neural Mix lanes showing.
   - The red pill at the top of the screen means it's running. Tap it to stop. Control Center works too.
10. **CC.** The STEM card shows the iPad live: frames per second, what it reads, the next drop. **STEM DROPS** (CC › SHOW) stays **OFF** until you switch it on.

## Every day after that

- Start the broadcast before a set from the app, or from Control Center: long-press Screen Recording › Stem Eye › Start Broadcast.
- The picture finds its own way up. If it starts upside down, Stem Eye turns it round after about 6 s and remembers that for next time.
- If the screen stands still (djay paused), Stem Eye sends a tiny heartbeat every second. The Controller keeps its last reading.

## When something's off

| You see | Do this |
|---|---|
| Test: *Couldn't reach it* | Same Wi-Fi as the Controller? Controller running? Address right (port 8080 unless your CC link shows another)? Settings › Privacy & Security › **Local Network** › Stem Eye on. |
| Test: *Controller without the stem reader* | Run Controller build 17c or later. |
| Broadcast stops at once: *enter the Controller's address* | Open Stem Eye, type the address, Test once. |
| Status: *Controller sees djay: not yet* | djay full screen, landscape, two-deck view with stem lanes. Wait 6 s for the automatic rotation. Still nothing: try **Rotation** 90° (and 270°). |
| Status: *the picture is portrait* (only with a manual Rotation) | Turn the iPad to landscape, or set Rotation back to Automatic. |
| Workflow: *Missing in the repository settings* | Step 3. |
| Workflow: *No App Store Connect app* | Step 5. |
| Workflow: *refused the API key (401)* | Key ID / Issuer ID / .p8 text don't match. Make a new key (Admin) and paste all three again. |
| Workflow: an `error:` about signing or profiles | Check that the API key has **Admin** access and that `TEAM_ID` is the same team. |
| Workflow: *needs Xcode 26* or no `macos-26` runner | Set the repository variable `RUNNER` to the newest macOS image GitHub offers. |

## What GitHub checks on every push (no Apple account needed)

`ci/check.sh` compiles the app's own frame code (`Broadcast/TileSampler.swift`, `Broadcast/Pipeline.swift`) for the Mac. It feeds that code an 18-second djay screen recording (`ci/djay-clip.mp4`, from your 10-16 23:48 recording, 40–58 s), decoded the way ReplayKit hands frames over. The other end is a stand-in Controller (`ci/reader-server.js`) running the Controller's real stem reader (`ci/sr-block.js`) and its real packet decoding. It must show:

- **The same tiles every way up.** A picture turned 90/180/270° gives the same tiles byte for byte. So do BGRA and video-range pictures, and a half-size capture lands on the same crops.
- **The reader works on the app's frames, live.** It sees djay's decks, reads the 140 BPM grid, and calls the drop at bar 97 within 0.1 s of where it lands, at least 2 s ahead.
- **Recovery.** Lost packets come back as whole tiles. Frame times sync to the Controller's clock. Heartbeats arrive while the screen stands still. The thumbnail arrives.
- **Rotation.** A portrait picture with the *wrong* orientation tag gets turned round by itself.

Then `ci/compile.sh` builds the real app and extension for an iPad, without signing.

## Files

| Path | What |
|---|---|
| `StemEye/` | The app: address + Test, the broadcast button, the broadcast's status |
| `Broadcast/` | The ReplayKit extension: `SampleHandler` (ReplayKit glue), `Pipeline` (frames → Controller), `TileSampler` (crops → tiles) |
| `Shared/` | Settings + status shared through the keychain (no App Group to register), the tile program |
| `project.yml` | The Xcode project, generated by XcodeGen on GitHub's Mac |
| `ExportOptions.plist` | App Store signing + upload |
| `ci/` | The check (clip, stand-in Controller, Swift test), compile / upload scripts, the App Store Connect API helper |

The tile program (which pieces of the screen, how shrunk, how often) comes from the Controller (`GET /sr/program`). Changing the reading doesn't need a new app build.

## Notes

- Private repo: GitHub counts Mac minutes ×10 against the free 2,000 a month. One run is about 6–8 Mac minutes, so roughly 25 runs a month. The check runs on pushes that touch the app.
- Every upload needs a new build number. The workflow numbers each build from its run (and re-run attempt), so that's automatic.
- The app needs iPadOS 17 or later. The protocol is described at the top of `Broadcast/Pipeline.swift` and in the Controller's HANDOFF (STEM READER).
