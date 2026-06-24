# ChloroFrame

**ALPHA / EXPERIMENTAL: do not treat this as a daily driver yet.**

ChloroFrame needs a lot more testing, hardening, packaging, and real-world
validation. Expect bugs, crashes, stream instability, performance regressions,
broken edge cases, signing/helper rough edges, and behavior that has not been
audited across hardware, host, display, and network configurations. If you need
a reliable game-streaming client today, use Moonlight.

**Testing help wanted:** if you are the kind of person who is always tinkering,
does not mind trying rough new software, and can tolerate alpha-quality bugs,
please test ChloroFrame and open GitHub issues for anything broken, confusing,
or hardware/network-specific. Good reports with Mac model, macOS version,
Apollo or Sunshine version, codec/HDR settings, and logs are especially useful.

**Maintainer disclosure:** I am a backend-heavy full-stack developer, not
someone with prior professional experience in real-time streaming, media
pipelines, FEC, codecs, or low-latency transport code. I started this project to
learn macOS development and to see how far I could get building an Apollo
client that is almost entirely native to macOS.

**AI-assisted codebase:** I used AI heavily while building this project. That is
disclosed upfront for people who are reasonably cautious about trying or
depending on AI-assisted code. Treat this repository as experimental software:
read the code, test carefully, and assume there are mistakes.

ChloroFrame is a native macOS client for Apollo, a fork of Sunshine. It is built
around Apple's media stack: SwiftUI for the app, Metal for rendering,
VideoToolbox for video decode, Network.framework and POSIX sockets for
transport, and CoreAudio with libopus for audio playback.

## Relationship To Moonlight

ChloroFrame owes a lot to Moonlight. Much of the core streaming and protocol
work in this repository is a direct Swift translation or adaptation of
`moonlight-common-c`: RTSP negotiation, RTP packet handling, FEC behavior, ENet
control messages, codec setup, and a number of hard-earned protocol details.

Thank you to the Moonlight and moonlight-qt developers for doing the difficult
protocol and compatibility work in public. This project is not a dig at
moonlight-qt, and it is not a claim that moonlight-qt does not work. Moonlight
is the mature client people should use when they need reliability. ChloroFrame
is an experiment in learning macOS development and exploring what an
Apple-native client could look like.

## Why Not Just Use Moonlight?

For most people, Moonlight is still the right answer today. ChloroFrame exists
for a different reason.

First, I am a lifelong learner, and this is one of many projects I have taken on
to learn Swift and macOS development by building something real.

Second, Moonlight is built on `moonlight-common-c`, an impressive
platform-independent library. I wanted to see what would happen if parts of that
work were translated into Swift and shaped around Apple's frameworks directly:
VideoToolbox, Metal, CoreAudio, Network.framework, and macOS app lifecycle APIs.
The experiment is whether a native macOS implementation can remove some
redundancy, use platform-specific APIs more directly, and make different
performance tradeoffs.

Third, on my own setup I consistently see stuttering, microstuttering, and audio
crackles with both the moonlight-qt release build and Moonlight nightly builds.
That does not mean Moonlight is broken for everyone, and it does not take away
from the work the Moonlight developers have done. This does not even mean
ChloroFrame solves that problem entirely. It was simply enough of a reason for
me to start experimenting with a native macOS client instead of giving up
without trying first, and to see if I could learn something useful in the
process.

## Apollo And Sunshine Compatibility

This project is developed and tested against Apollo, a fork of Sunshine. I do
not currently use upstream Sunshine, and I have not tested ChloroFrame against
upstream Sunshine.

It may work with Sunshine where Apollo and Sunshine share the same protocol
behavior, but please treat upstream Sunshine compatibility as unverified. If you
run into issues using ChloroFrame with Sunshine, please open a GitHub issue with
your Sunshine version, macOS version, Mac model, codec/HDR settings, and any
useful logs.

## Current Status

Implemented, but still alpha:

- Pairing with Apollo hosts and launching host apps.
- H.264 and HEVC video decode through VideoToolbox.
- HDR10/PQ streaming path for HEVC streams when the host app and display support
  HDR.
- Metal rendering with NV12/P010 texture paths and display-link frame pacing.
- RTP video assembly with FEC recovery.
- Opus audio decode (vendored libopus by default, or macOS's built-in AudioToolbox
  decoder as an opt-in, 100%-Apple path) through CoreAudio pull playback, with an
  adaptive jitter buffer, clock-drift correction, crossfaded (click-free) buffer
  corrections, waveform-repeat underrun concealment, and Opus FEC/PLC gap concealment.
- Optional Wi-Fi airtime suppression while streaming via a privileged helper: brings
  `awdl0` down and reversibly suspends locationd's periodic positioning scan (both
  restored on stop), to reduce the periodic Wi-Fi stalls that cause audio dropouts.
- Keyboard and mouse input over the Apollo control channel, with custom remapping of
  the fn/control/option/command modifier keys, an fn-layer latch, and a reserved
  ⌃⌥⌘ control-prefix (held: hold it to reveal an in-stream controls overlay).

Known gaps:

- AWDL + locationd suppression now works, but requires a correctly signed helper that
  the user approves once in System Settings. During development, Debug rebuilds re-sign
  the binary and can staleness the helper registration (re-register from Settings to fix).
- Audio output-device and config-change handling (AVAudioEngine reconfiguration)
  and LAN audio encryption are not implemented. Some delivery jitter remains on noisy
  Wi-Fi; it is now concealed click-free rather than eliminated.
- Controller/gamepad input works (GameController.framework), including remapping buttons and
  back paddles to gamepad combos or host keyboard chords; see controller-mapping.md. Current
  controller limitations:
  - Only a single controller is fully supported. Multiple controllers at once, and telling
    apart two of the same model, are not handled.
  - The setup window's controller selection is not linked to a specific HID device
    (GameController exposes no USB vendor/product id), so per-controller config is keyed to the
    first connected HID controller.
  - Extra (paddle) buttons are recoverable only when the controller actually emits a distinct
    HID bit. Pads that fold them into a standard input in firmware (or emit nothing) expose
    nothing to bind. Learned buttons are scoped by vendor/product id and do not transfer to a
    different controller model.
  - Source combos fire only when all sources are held on the same poll tick; the chord-tap
    delay (holding back a standalone press that might become a combo) is not implemented, so a
    fast standalone press can leak before its combo completes.
  - Controller motion, touchpad surface, rumble/haptics, and battery are not wired up. Touch
    and pen input are not implemented.
  - Config files are JSON in ~/Library/Application Support/ChloroFrame/Controllers; the schema
    is still changing during alpha, so configs may need to be recreated after updates.
- The stream is fullscreen-only for now: it auto-enters fullscreen on connect and exits on
  disconnect. There is no windowed mode yet, and the "Toggle Full Screen" menu item (⌘⌃F) is
  currently a non-functional no-op.
- Bonjour/mDNS host discovery is still a placeholder.

## Controller Support

ChloroFrame has native controller support built on Apple's GameController.framework, set up from
an opt-in window (Settings, Input, Controller). A standard controller passes through to the host
as-is. On top of that you can:

- Identify "extra" buttons macOS does not expose (back paddles and similar), and give them labels.
- Rebind any known or labeled button, alone or as a combo, to a host gamepad combo or a host
  keyboard chord. Keyboard targets are picked on an on-screen Windows keyboard, so the keys go
  straight to the host and are never intercepted by macOS (Win, F-keys, and media keys included).
- Save it all per controller as a JSON config you can import or remove.

See controller-mapping.md for the design, and the controller limitations under Known gaps above.

### Planned

The goal is to make controlling a host with a controller efficient and painless, and to make back
buttons genuinely useful. Planned work, roughly in order of intent (not commitments or timelines):

- **Combo timing.** A configurable millisecond gap between the keys in a chord. Example: a back
  button bound to Alt+Tab with a 50 ms delay between the Alt press and the Tab press on the host,
  for hosts or apps that need the keys staggered rather than sent together.
- **Trigger modes / layers.** A binding should fire on more than just "all sources held". Modes:
  - Press (today): fires as soon as the combo is held, releases on let-go.
  - Release: fires only when the combo is released (back button + A on release does Alt+Tab).
  - Hold: fires only after the combo is held for a configurable time (back button + A held for,
    say, 2 seconds does Alt+Tab).
- **Stick as mouse.** An optional layer where the left and/or right stick drives the host mouse,
  so a user can navigate their host desktop with the controller.
- **Apollo client-side scripts.** Apollo can trigger scripts from the client side; expose an easy
  way to configure those and fire them from a controller binding.

## How To Use

Download the latest build from the GitHub Releases page:

<https://github.com/AmanBhardwaj25/ChloroFrame/releases>

Releases are still alpha builds. Expect issues, and prefer Moonlight if you need
a dependable daily-driver client.

## Requirements For Local Build And Contribution

- Apple Silicon Mac. Intel Macs are not supported.
- macOS with Xcode installed.
- An Apollo host reachable on the local network.
- For HDR: HEVC enabled, host HDR enabled, and an HDR-capable Mac display.
- For future AWDL suppression work: a correctly signed app and privileged
  helper. Public forks will need to update bundle identifiers, Team ID, and
  signing settings.

The checked-in Xcode project currently targets macOS 26.1. Adjust the
deployment target in Xcode if you want to experiment with older macOS versions.

## Build

Open `ChloroFrame.xcodeproj` in Xcode and run the `ChloroFrame` scheme.

For a command-line build that skips code signing:

```sh
xcodebuild -project ChloroFrame.xcodeproj -scheme ChloroFrame CODE_SIGNING_ALLOWED=NO build
```

That unsigned build is useful for source-level iteration. Future work on the
AWDL helper requires a signed app/helper pair with matching bundle identifiers
and requirement strings in:

- `ChloroFrame.xcodeproj/project.pbxproj`
- `ChloroFrame/Info.plist`
- `ChloroFrameHelper/Info.plist`
- `ChloroFrame/Resources/fullstacksandbox.com.ChloroFrame.Helper.plist`

## Repository Layout

- `ChloroFrame/`: main SwiftUI macOS app.
- `ChloroFrame/Network/`: Apollo HTTP, RTSP, ENet, RTP, and FEC code.
- `ChloroFrame/Video/`: VideoToolbox decode and Metal presentation.
- `ChloroFrame/Audio/`: Opus decode and CoreAudio playback.
- `ChloroFrame/Input/`: keyboard and mouse input translation.
- `ChloroFrameHelper/`: privileged SMAppService daemon that brings `awdl0` down and
  suspends/resumes locationd during a stream (Wi-Fi airtime suppression).
- `clear_pairing.sh`: local utility for clearing stored pairing credentials.

## License

ChloroFrame is licensed under the **GNU General Public License v3 (GPLv3)**.
See `LICENSE` for the full text and `NOTICE` for attribution.

Much of ChloroFrame's core streaming and protocol code is a direct Swift
translation or adaptation of [`moonlight-common-c`](https://github.com/moonlight-stream/moonlight-common-c),
which is part of the Moonlight Game Streaming project and licensed under GPLv3.
Because ChloroFrame is a derivative work of that code, ChloroFrame as a whole is
released under GPLv3 as well. Copyright (C) 2026 Aman Bhardwaj and the Moonlight
Game Streaming Project contributors.

Note: GPLv3 is generally considered incompatible with distribution through
Apple's App Store / TestFlight (the same constraint that affects other GPL apps,
e.g. VLC). If you redistribute ChloroFrame through those channels, make sure you
have the necessary permission from the upstream copyright holders.

Vendored Opus headers and the static `libopus.a` in `ChloroFrame/Vendor/opus`
remain under the upstream Opus license. If you distribute binaries, include the
Opus license notice with your distribution.

The Reed-Solomon FEC code in `ChloroFrame/Network/FEC/` (both the C
implementation and its Swift translation) is derived from the scalar
(OBLAS_TINY) path of [nanors](https://github.com/sleepybishop/nanors) by
Joseph Calderon, used under the MIT License (GPL-compatible). The full license
notice is included in `nanors_impl.c`.
