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

The experimental PyroWave codec (see below) needs a host running Vibeshine, a
Sunshine fork that adds a PyroWave encoder. Apollo and upstream Sunshine do not
offer PyroWave, so ChloroFrame never shows or uses it with them.

## PyroWave (Experimental)

[PyroWave](https://github.com/Themaister/pyrowave) is a very low latency,
intra-only wavelet codec by Hans-Kristian Arntzen. Every frame stands alone, so a
lost frame never needs a keyframe to recover, and decode is a few milliseconds on
the GPU. The tradeoff is bandwidth: it uses hundreds of Mbps where HEVC uses tens.

ChloroFrame decodes PyroWave natively in Metal. What works today:

- 4:2:0 and optional 4:4:4 chroma (Settings, "4:4:4 chroma (PyroWave)").
- 8-bit SDR, and 10-bit HDR10 when HDR is on, the display is HDR, and the host
  offers it. The host decides whether a 10-bit picture is HDR (PQ) or 10-bit SDR.
- Partial-frame recovery: a frame that lost a few packets is shown with the
  damaged blocks skipped instead of being dropped.
- A readiness check before every PyroWave launch (GPU, host, route, Wi-Fi band,
  bitrate, decode speed). If the setup cannot carry PyroWave, the stream falls
  back to HEVC and the app says why. "Check PyroWave readiness" in the app list
  shows every check.
- "Test network" in the app list asks the host for about 3 seconds of test
  traffic at the PyroWave bitrate and grades loss and jitter on your path.
- Its own bitrate default (about 290 Mbps at 3024x1890 @60, more for 4:4:4 and
  HDR) and a custom bitrate cap of 2000 Mbps.

PyroWave is local network only (never offered over Tailscale/VPN routes) and is
labeled Experimental behind a one-time warning. It has been tested on one Mac
(M4 Pro) over 6 GHz Wi-Fi against one host; Ethernet on the Mac is untested.
On Wi-Fi expect a few lost or partial frames per minute from ordinary air loss,
and expect "Test network" to fail on jitter even when streaming looks fine (the
limit comes from the host project's calibration and may not suit Wi-Fi yet).

## Current Status

Implemented, but still alpha:

- Pairing with Apollo hosts and launching host apps, with a per-app Stop button and a
  RUNNING badge for apps a previous session left running.
- Optional secondary address per saved host (for example LAN plus Tailscale), with
  automatic fallback, IPv6, and MTU-aware packet sizing for VPN paths.
- H.264, HEVC, and AV1 video decode through VideoToolbox. AV1 is hardware-only: it
  needs a Mac with a hardware AV1 decoder (M3 or later) and a host that advertises AV1,
  and falls back to HEVC otherwise.
- HDR10/PQ streaming for HEVC and AV1 when the host app and display support HDR (AV1
  HDR also needs host AV1 Main10 encoding), and for PyroWave on a Vibeshine host.
- PyroWave (experimental) on Vibeshine hosts: native Metal decode, see the PyroWave
  section above.
- Metal rendering with NV12/P010 texture paths and display-link frame pacing.
- RTP video assembly with FEC recovery.
- Opus audio decode (vendored libopus by default, or macOS's built-in AudioToolbox
  decoder as an opt-in, 100%-Apple path) through CoreAudio pull playback, with an
  adaptive jitter buffer, clock-drift correction, crossfaded (click-free) buffer
  corrections, waveform-repeat underrun concealment, and Opus FEC/PLC gap concealment.
- Automatic audio recovery when the output device or route changes (AirPods, headphones,
  HDMI). If recovery gives up, a non-blocking banner offers a retry, and ⌃⌥⌘R resets
  stream audio at any time.
- Per-connection stream overrides for resolution, frame rate, and bitrate, including a
  custom bitrate field (up to 500 Mbps, or 2000 Mbps with PyroWave, experimental).
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
- ~~Audio output-device and config-change handling (AVAudioEngine reconfiguration)
  and~~ LAN audio encryption is not implemented. (Output-device and route-change
  recovery shipped in 1.4-alpha.) Some delivery jitter remains on noisy Wi-Fi; it is
  now concealed click-free rather than eliminated.
- AV1 HDR (Main10) now streams HDR from a live host, but AV1 recovery from packet loss
  has not been tested under forced loss.
- PyroWave is experimental: tested on one Mac and one host over Wi-Fi only, see the
  PyroWave section for its known limits.
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
- For HDR: HEVC, AV1 or PyroWave selected, host HDR enabled, and an HDR-capable Mac
  display.
- For AV1: a Mac with a hardware AV1 decoder (M3 or later) and a host GPU that
  encodes AV1.
- For PyroWave: an M1 or later Mac (Apple7 GPU family), a Vibeshine host with
  PyroWave enabled, and a fast local network (host on Ethernet; the Mac on Ethernet
  or 5/6 GHz Wi-Fi).
- For ~~future AWDL suppression work~~ AWDL / locationd suppression: a correctly
  signed app and privileged helper. Public forks will need to update bundle
  identifiers, Team ID, and signing settings.

The checked-in Xcode project currently targets macOS 26.1. Adjust the
deployment target in Xcode if you want to experiment with older macOS versions.

## Build

Open `ChloroFrame.xcodeproj` in Xcode and run the `ChloroFrame` scheme.

For a command-line build that skips code signing:

```sh
xcodebuild -project ChloroFrame.xcodeproj -scheme ChloroFrame CODE_SIGNING_ALLOWED=NO build
```

That unsigned build is useful for source-level iteration. ~~Future work on the
AWDL helper requires~~ The AWDL helper requires a signed app/helper pair with
matching bundle identifiers and requirement strings in:

- `ChloroFrame.xcodeproj/project.pbxproj`
- `ChloroFrame/Info.plist`
- `ChloroFrameHelper/Info.plist`
- `ChloroFrame/Resources/fullstacksandbox.com.ChloroFrame.Helper.plist`

Unit tests (protocol parsing, FEC, SDP, AV1, PyroWave parsing, decode round trips on
the GPU, and more; a few need an Apple GPU) run with:

```sh
xcodebuild test -project ChloroFrame.xcodeproj -scheme ChloroFrame -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## Repository Layout

- `ChloroFrame/`: main SwiftUI macOS app.
- `ChloroFrame/Network/`: Apollo HTTP, RTSP, ENet, RTP, and FEC code.
- `ChloroFrame/Video/`: VideoToolbox decode (including AV1 sequence-header parsing) and
  Metal presentation.
- `ChloroFrame/Video/PyroWave/`: PyroWave decoder wrapper, record parser, frame pool,
  readiness audit and network test.
- `ChloroFrame/Vendor/pyrowave/`: the vendored PyroWave Metal port (upstream code, one
  local patch).
- `ChloroFrame/Audio/`: Opus decode and CoreAudio playback.
- `ChloroFrame/Input/`: keyboard, mouse, and game controller input (GameController,
  raw HID for extra buttons, per-controller configs).
- `ChloroFrame/UI/`: SwiftUI host list, connection flow, settings, and controller setup.
- `ChloroFrameHelper/`: privileged SMAppService daemon that brings `awdl0` down and
  suspends/resumes locationd during a stream (Wi-Fi airtime suppression).
- `ChloroFrameTests/`: unit tests.
- `controller-mapping.md`: controller remapping design and status.
- `PRIVACY.md`: privacy policy.
- `clear_pairing.sh`: local utility for clearing stored pairing credentials.

## License

Project code is released under the MIT License. See `LICENSE`.

Vendored Opus headers and the static `libopus.a` in `ChloroFrame/Vendor/opus`
remain under the upstream Opus license. If you distribute binaries, include the
Opus license notice with your distribution.

The vendored PyroWave decoder in `ChloroFrame/Vendor/pyrowave/` is by
Hans-Kristian Arntzen, used under the MIT License; see `LICENSE-pyrowave.txt` there.

The Reed-Solomon FEC code in `ChloroFrame/Network/FEC/` (both the C
implementation and its Swift translation) is derived from the scalar
(OBLAS_TINY) path of [nanors](https://github.com/sleepybishop/nanors) by
Joseph Calderon, used under the MIT License. The full license notice is
included in `nanors_impl.c`.
