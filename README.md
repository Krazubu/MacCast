# Cast Mirror

A macOS menu bar app that mirrors the screen and system sound to a Chromecast or a
TV with Cast built in, the way Chrome's "Cast screen" does, without Chrome.

It uses the same protocol as Chrome:

1. **Discovery**: Bonjour `_googlecast._tcp`. Devices without video output, such as
   speaker groups, are skipped.
2. **Control channel**: TLS on port 8009 with length-prefixed `CastMessage` protobufs.
   The app launches the mirroring receiver (`0F5096E8`) and negotiates the streams
   with an `OFFER`/`ANSWER` on `urn:x-cast:com.google.cast.webrtc`.
3. **Cast Streaming**: H.264 (VideoToolbox, hardware) and Opus 10 ms (AudioToolbox).
   Each frame is encrypted with AES-128-CTR and sent as Cast RTP over UDP. The app
   sends RTCP sender reports for A/V sync. It handles the receiver's feedback:
   ACKs, retransmission of lost packets, and a new key frame when the picture is lost.
4. **Capture**: ScreenCaptureKit captures the chosen display and the system sound. The
   app's own sound is excluded. When the screen is static, the last image is resent
   every 0.5 s to keep the stream alive.

## Install

```bash
./scripts/install-app.sh
```

This builds `build/Cast Mirror.app`, copies it to `/Applications`, and opens it. Building
needs the Xcode command line tools, and the app needs macOS 14 or later.

On first use, macOS asks for two permissions:

- **Local network**: needed to find and reach the Cast devices.
- **Screen & System Audio Recording**: turn it on in System Settings › Privacy &
  Security, then relaunch the app.

The app is signed ad hoc. After a rebuild, macOS may ask for the screen recording
permission again.

## Use

Click the TV icon in the menu bar, then click a device to start mirroring. Click it
again, or choose *Arrêter la diffusion*, to stop. The menu also lets you pick:

- **Écran**: which display to mirror, when there are several.
- **Qualité**: 1080p (6 Mbit/s) or 720p (3.5 Mbit/s).
- **Latence**: the receiver's buffer. 200 ms is snappier, 800 ms copes better with
  weak Wi-Fi.
- **Diffuser le son**: turns the system sound on or off.
- **Ouvrir à la connexion**: starts the app at login.

Changing a setting while mirroring restarts the stream. The log is at
`~/Library/Logs/CastMirror.log`.

## Command line

The same binary can be used for testing:

```bash
"build/Cast Mirror.app/Contents/MacOS/CastMirror" --cast "Living Room" --pattern --seconds 20
```

| Option | Effect |
| --- | --- |
| `--pattern` | sends a test pattern and a beep instead of the screen (needs no permission) |
| `--no-audio` | video only |
| `--720` | 720p instead of 1080p |
| `--delay <ms>` | receiver target delay (default 400) |
| `--seconds <n>` | stops after n seconds (default 30) |
| `--list` | lists the devices found |

Every 2 seconds it logs how many frames were sent and acknowledged by the receiver.
