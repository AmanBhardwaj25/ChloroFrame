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
- Opus audio decode through vendored libopus and CoreAudio pull playback.
- Keyboard and mouse input over the Apollo control channel.

Known gaps:

- AWDL suppression is broken and should be treated as a TODO. Do not rely on it.
- Audio resilience work is still open: packet reorder, packet-loss concealment,
  adaptive jitter buffering, and host/client clock drift correction.
- Gamepad, touch, and pen input are not implemented yet.
- Bonjour/mDNS host discovery is still a placeholder.

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
- `ChloroFrameHelper/`: privileged helper for future AWDL suppression work.
- `clear_pairing.sh`: local utility for clearing stored pairing credentials.

## License

Project code is released under the MIT License. See `LICENSE`.

Vendored Opus headers and the static `libopus.a` in `ChloroFrame/Vendor/opus`
remain under the upstream Opus license. If you distribute binaries, include the
Opus license notice with your distribution.
