# Logic Bridge — Stem Generator

Stem Generator is a macOS Audio Unit v3 with a Logic-hosted SwiftUI editor. It goes in an Audio FX slot and passes audio through while you compose requests and audition takes. The bundle that registers it has no separate generation window.

## macOS installer

[Installer releases](https://github.com/VagabondInc/logic-bridge/releases)

Build the universal Apple Installer package with:

```sh
./script/package_installer.sh
```

The package installs **Logic Bridge.app** in Applications, including the Stem Generator AUv3 and the demo. During a GUI installation on the startup volume, it registers the Audio Unit as the current desktop user and opens a writable demo copy in Logic Pro. The copy lives at `~/Music/Logic Bridge/Logic Bridge Demo.logicx`. Reopening Logic Bridge opens that copy and keeps any edits. A headless install can open the demo later by launching Logic Bridge.

The four-bar **Afterglow** demo contains original backing audio for testing Cycle Audio. Insert Stem Generator on its Audio FX slot, enable Cycle over the first four bars, and configure a generation endpoint to try the workflow. The Logic project was generated using the MIT-licensed [LogicProFormatWriter at 9935ca8](https://github.com/jonkubis/LogicProFormatWriter/tree/9935ca88a3fad4c4232eb9dd755149e9cc9b9b65). Its license is bundled alongside the demo.

The default output is an unsigned local package with ad hoc-signed code. To build a distribution-signed package, set `LOGIC_BRIDGE_APPLICATION_SIGN_IDENTITY` and `LOGIC_BRIDGE_INSTALLER_SIGN_IDENTITY` to the matching Developer ID identities. Submit that signed package to Apple's notary service and staple it before distributing it to users. [Apple packaging guidance](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)

## Build and register

Requirements are macOS 14 or later, Xcode and XcodeGen. Run the Codex **Run** action or:

```sh
./script/build_and_run.sh --verify
```

This builds and validates `dist/LogicBridgeAudioUnit.app`, which embeds `StemGenerator.appex`. Keep the app bundle at this path after registration. If Logic was open during registration, reopen it so it refreshes its Audio Unit catalog. In a mono or stereo channel’s **Audio FX** slot, choose **Audio Units → Logic Bridge → Stem Generator**.

## Workflow

1. Insert **Stem Generator** on the track you want to use as context. For the project mix, insert it on **Stereo Out** after the effects you want included. The plug-in captures the signal at that insert position.
2. Turn on Logic’s **Cycle** and position its locators around the desired audio. Enable **Use Cycle Audio**. Pick an instrument, describe the part, and choose the influence settings.
3. Choose **Connect service** and enter a generation endpoint. Click **Generate Stem** and let Logic play through the selected Cycle. If playback is already past the left locator, the plug-in waits for the next pass. It attaches one mono or stereo 16-bit WAV and sends the captured tempo, time signature, cycle start, and beat count in the same request. The capture limit is 20 MiB. An interrupted pass is discarded.
4. With **Use Cycle Audio** off, you can still attach a reference WAV or work from the prompt alone. Audition returned takes in the editor, drag them to the Tracks area, or use **Save WAV** to keep a copy. Keep imported audio with the Logic project before removing the plug-in.
5. **Auto Insert** is disabled. An arrangement insertion adapter would need a separate, verified host integration.

Capture is armed only by **Generate Stem** and can be cancelled. The plug-in passes audio through during capture. Audio goes to the configured generation endpoint with the prompt. Suno sign-in authenticates its MCP resource separately. Take files are temporary until saved or copied into your project.

## Verification on Logic Pro 11.2.2

The locally registered AU passed Apple's `auval` checks, including mono and stereo rendering. In an unsaved Logic project, the Audio FX insert displayed the custom editor. Playback of a silent test region supplied 120 BPM, 4/4, and a 16-beat Cycle starting at beat zero. Clicking **Generate Stem** sent those values to a local test endpoint, displayed its returned take, and **Save WAV** exported a valid audio file. The endpoint was disconnected after testing. Dragging a take onto the arrangement and live provider generation remain unverified.

## Generation service contract

The plug-in includes an HTTP client. It needs an endpoint you control or are authorized to use. Suno exposes an [official API sign-in](https://platform.suno.com/), but the publicly visible description does not document access to Bridge’s stem generation contract. Suno account authentication and live stem generation are pending an authorized service with the required capabilities.

The endpoint receives a single JSON POST with `Content-Type: application/json` and optional `Authorization: Bearer …`. HTTPS is required except for loopback development. The endpoint and non-secret OAuth settings are remembered. Access tokens stay in memory for the current editor session.

### Sign in with Suno

In **Connect service → Sign in with Suno**, Logic Bridge registers a public native client with Suno’s published OAuth service and opens the default browser. Suno returns a one-time authorization code to a temporary listener bound to `127.0.0.1`. The plug-in verifies OAuth state, exchanges the code using S256 PKCE, and retains the access token in memory for this editor. The token is requested for Suno’s MCP resource. A successful sign-in shows **Suno account connected**.

The local Audio Unit passed validation, and a test in a hosted Audio Unit editor completed Suno’s live browser authorization and token exchange. The loopback test rejected an incorrect state. The separate generation client still uses the configured generation endpoint. Suno authorizes MCP separately from calls made by the Studio web app. [Suno MCP setup](https://suno.com/mcp) · [Resource metadata](https://api.suno.com/.well-known/oauth-protected-resource/mcp) · [OAuth server metadata](https://studio-api-prod.suno.com/.well-known/oauth-authorization-server/api/v2/external/oauth)

### Browser sign-in for a generation endpoint

In **Connect service → Browser sign-in**, enter the generation URL, your provider’s authorization and token URLs, the public client ID registered for Logic Bridge, and any required scope. Register `com.local.logicbridge.audio:/oauth/callback` as the redirect URI. The provider must support the authorization-code grant with S256 PKCE and return an access token accepted by your generation endpoint. Logic Bridge opens the browser through Authentication Services, validates the returned state and callback, and uses the access token for generation. Sign in again when it expires. The bearer-token option also remains available.

The token exchange and authenticated WAV request passed against a local provider fixture. An incorrect callback state was rejected. The browser settings were verified in a hosted plug-in window. The interactive browser round trip and a live Suno connection remain unverified.

```json
{
  "prompt": "Soft electric piano chords with a swung rhythm",
  "instrument": "Keys",
  "tempoBPM": 108,
  "timeSignatureNumerator": 4,
  "timeSignatureDenominator": 4,
  "durationBeats": 16,
  "cycleStartBeat": 16,
  "key": "A minor",
  "weirdness": 35,
  "styleInfluence": 65,
  "audioInfluence": 50,
  "reference": { "filename": "guide.wav", "wav": "<base64 WAV>" }
}
```

- The three influence settings use integers from 0 to 100. Optional `cycleStartBeat`, `key`, `audioInfluence` and `reference` are omitted when unavailable. Beat counts use quarter-note units. Cycle captures and attached WAVs are capped at 20 MiB. A capture uses the filename `Logic Cycle.wav` and the same reference field as an attachment.
- Respond with HTTP 2xx and a playable RIFF/WAVE file under 100 MB. Redirects, non-2xx status and invalid audio are surfaced to the user. Cancel stops the plug-in’s request. A service may continue work after the client disconnects.
- The service owns stem generation, duration, musical alignment, and any provider billing.

## Suno Bridge investigation

REA 6.9.0 was built from the supplied local source. The per-user launcher is `~/.local/bin/rea`. REA's production stdio self-test completed and matched all 255 tools and six prompts. The project uses the CLI for reproducible local inspections.

| Evidence | Observation |
| --- | --- |
| Bundle metadata (`evidence/suno-plist.json`, local), Contents inventory (`evidence/suno-layout.json`, local), Mach-O (`evidence/suno-macho.bundle.json`, local) | Suno Bridge 0.7.33 has bundle ID `com.suno.link`. Its `suno-link` executable is arm64-only and links the bundled Electron Framework. REA examined 262 directory entries within its scan and skipped 14 symlinks. |
| ASAR inventory (`evidence/suno-asar-inventory.bundle.json`, local), Startup analysis (`evidence/suno-startup.bundle.json`, local) | The archive contains the Electron entry `electron/main.cjs`, `electron/api/loadApi.cjs`, and a compiled renderer. The selected preload analysis observed one Electron context-bridge API with 133 exposed members. Manifest metadata describes importing DAW projects into Suno Studio. |
| Partial JavaScript analysis (`evidence/suno-javascript.bundle.json`, local), timeout details (`evidence/suno-javascript.json`, local) | The broader JavaScript analysis reached its 45-second per-source deadline during `electron/main.cjs`. Renderer semantics remain unexamined. A focused text read of the REA-extracted main file observed Electron window setup and the same Ableton track-creation and clip-creation message literals present in the bundled Python handler sources. |

The packaged Python directory `Contents/Resources/suno-control` exposes an Ableton Control Surface entry point in `__init__.py`. The socket code in `suno_control/osc_server.py` defaults to UDP loopback with listener port 11000 and reply port 11001. In `suno_control/track.py`, the arrangement-clip handler calls Ableton's track object with an audio file path and beat position. Together these observations identify a desktop-to-DAW boundary. Runtime message flow, Suno account integration, and end-to-end audio transfer were outside this static inspection.

The file references in this section identify local investigation records. The public repository contains the app, plug-in, and original demo.

### Sign-in evidence

The shipped preload exposes sign-in, phase updates, profile updates, and sign-out over Electron IPC. The main process generates OAuth state and an S256 PKCE verifier, binds a temporary loopback listener, opens the system browser, validates the returned state, and exchanges the authorization code with its verifier. Static code also shows access-token refresh and encrypted session storage through Electron `safeStorage`. The macOS bundle declares the separate `suno-link` URL scheme. These findings describe the shipped Bridge client from static code, without an authenticated run. REA preload analysis (`evidence/suno-startup.bundle.json`, local) · REA main member extraction (`evidence/suno-auth-main-extract.json`, local) · REA bundle metadata (`evidence/suno-plist.json`, local)

Suno publishes an [API sign-in](https://platform.suno.com/) and [browser authorization for MCP](https://suno.com/mcp). The signed-in Studio tab displayed the start of a user-initiated drum generation. Its observed resource URLs included Studio agent steps, tool executions, and render-state requests. The tab inventory exposes URLs, leaving the generating request, body, and permission requirements unverified. Access to Bridge-equivalent stem generation for this app remains unverified.

## Logic investigation

The installed Logic Pro 11.2.2 (6387) exposes standard document and window terminology in its scripting dictionary. It lists no dedicated track, region, transport, or audio-import verbs. REA also identified Apple’s built-in Logic Control and TouchOSC MIDI device bundles. Logic Mach-O (`evidence/logic-macho.bundle.json`, local) · Scripting dictionary (`evidence/logic-scripting-dictionary.sdef`, local) · Logic Control Mach-O (`evidence/logic-control-macho.bundle.json`, local) · TouchOSC metadata (`evidence/logic-touchosc-plist.json`, local)

Apple documents the Audio Unit host callbacks for musical tempo, meter, and cycle. Suno documents the prompt, instrument selector, advanced settings, and Auto Insert in its Bridge guide. [Audio Unit host context](https://developer.apple.com/documentation/audiotoolbox/auaudiounit) · [Suno Bridge setup and controls](https://help.suno.com/en/articles/14695169)

### Studio stem HAR

Original HAR records 6, 8, and 22 show the Studio agent selecting a drum part, a server-side context render, and a `stem_condition` generation. The render's clip ID matches the conditioning clip ID in the generation request. The context payload contains Studio arrangement state and timing, including a padded beat range. No mixed WAV was uploaded in that request. Records 48 and 57 are successful M4A playback responses for the two returned take IDs. The separate download responses deny access or report a rate limit. The original HAR contains web-session material and a browser-token header. It does not establish which credentials are required or whether an independently authorized client can call the Studio routes.

The REA evidence (`evidence/studio-stem-har.bundle.json`, local) covers a filtered local derivative with authentication headers and the generation session token stripped. The original capture remains unchanged. Cycle Audio sends its WAV plus Logic timing to the configured generation service. The automatic request passed a local fixture test using production capture and networking code. The new capture was not verified during playback in Logic itself.
