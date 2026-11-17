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
again, or choose *Stop Casting*, to stop.

If a device doesn't show up, for example on a network that blocks mDNS (guest Wi-Fi,
some mesh routers, VLANs), choose *Cast to › IP Address…* and type its address. You can
find it in the Google Home app or in your router's list of devices. The app asks the
device for its name, and remembers the last five addresses in the *Cast to* list.
*Forget IP Addresses* clears them. Use a fixed address (a DHCP reservation on the
router), or the remembered entry may point to the wrong device later.

The menu also lets you pick:

- **Mode**: *Mirror Display* shows a Mac display on the TV. *Extended Display* turns the
  TV into a second screen instead. The app creates a 1920x1080 HiDPI virtual display
  (1280x720 in 720p) to the right of the main display, and streams it. You can drag
  windows onto it, or move it in System Settings › Displays. When the cast stops, it
  disappears and macOS moves its windows back. *Display* and *Optimize For* only
  apply to mirroring, so they are hidden in this mode.
- **Display**: which display to mirror, when there are several.
- **Optimize For**: *The Mac Display* leaves the Mac display alone, and the TV shows
  it with black bars if the shapes differ. *The HD Video Stream* gives the desktop,
  for the duration of the cast, the exact shape and size of the picture sent to the TV.
  That is 1920x1080, or 1280x720 in 720p, because Cast receivers don't report their own
  screen size and always show a 16:9 stream. The app creates a virtual display of that
  size (HiDPI) and makes the Mac display mirror it. The desktop then has the TV's shape,
  with black bars on the Mac's own panel, and the app streams the virtual display, so
  the picture fills the TV at full resolution. A Mac display that is already 16:9 is
  left alone. While mirroring, the Mac's panel probably runs at 60 Hz and without HDR.
  Everything comes back when the cast stops or the app quits. Changes only last for the
  login session, and the virtual display disappears with the app, so a crash leaves
  nothing behind. The virtual display relies on a private macOS API (`CGVirtualDisplay`,
  see `Sources/CGVirtualDisplay.h`), which a future macOS could change.
- **Quality**: 1080p (6 Mbit/s) or 720p (3.5 Mbit/s).
- **Latency**: the receiver's buffer. 200 ms is snappier, 800 ms copes better with
  weak Wi-Fi.
- **Cast Sound**: turns the system sound on or off.
- **Open at Login**: starts the app at login.

Changing a setting while casting restarts the stream. The app is in English, or in French
on a Mac set to French.

While casting, the app keeps the Mac's display from going to sleep on its own, like a
video player does: a sleeping display would stop the capture. If you put the Mac to
sleep, close the lid or turn the display off yourself, the app stops the cast cleanly
first and puts the displays back. It casts to the same device again when you wake the
Mac, retrying for a few seconds while Wi-Fi reconnects. The log is at
`~/Library/Logs/CastMirror.log`.

## Command line

The same binary can be used for testing:

```bash
"build/Cast Mirror.app/Contents/MacOS/CastMirror" --cast "Living Room" --pattern --seconds 20
```

| Option | Effect |
| --- | --- |
| `--cast <name or IP>` | casts to the first device whose name contains the text, or straight to an IP address without discovery |
| `--pattern` | sends a test pattern and a beep instead of the screen (needs no permission) |
| `--no-audio` | video only |
| `--720` | 720p instead of 1080p |
| `--delay <ms>` | receiver target delay (default 400) |
| `--seconds <n>` | stops after n seconds (default 30) |
| `--list` | lists the devices found |
| `--modes` | shows what *Optimize For › The HD Video Stream* would do on each display, without changing anything |
| `--optimize-test [s] [--extend]` | applies *Optimize For › The HD Video Stream* to the main display (or, with `--extend`, creates the extended screen) for s seconds (default 5), then restores it |

Every 2 seconds it logs how many frames were sent and acknowledged by the receiver.
