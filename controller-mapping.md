# ChloroFrame: Controller Remapping Spec

*Living design doc. Captures the controller-support feature requests and the
decisions/feasibility as we go. Started 2026-06-18.*

*Companion to keyboard-remapping.md. Where the two overlap (emitting host keyboard input),
this doc reuses the keyboard packet path described there.*

## Implementation status (2026-06-19)

Built and verified end-to-end against a live Apollo host:

- Opt-in controller setup window (Settings -> Input -> Controller), resizable.
- Discovery + live readout + raw-HID diagnostic (GameController + IOHIDManager).
- Learn flow: identify an unknown extra button (single rising bit, no GameController event),
  label it; persisted per controller.
- Rebinds: source chord of macOS-known and/or learned buttons -> a host gamepad combo or a host
  keyboard chord (chosen on a virtual on-screen Windows keyboard).
- Per-controller JSON config files (`<VID>_<PID>.json`) with import / remove (unlink, file stays).
- Runtime: a standard controller drives the host (default passthrough); rebinds apply, including
  learned/paddle sources read via raw HID at runtime. Confirmed: a paddle -> A, and a paddle ->
  Alt+Tab that alt-tabs only the host (no macOS interception).

Not yet done: controller motion/touchpad/rumble/battery, multiple simultaneous controllers,
controller-arrival capabilities detail, and the chord-tap delay nuance (combos use plain
all-held + consumption today).

## Goal

Make the extra and odd buttons on real controllers useful. Games are built for a standard
Xbox/DS4 pad, so the touchpad, paddles, and bonus buttons on a third-party pad usually do
nothing. ChloroFrame should let the user bind any controller input we can identify to something
the host understands: a standard gamepad button, a combo of gamepad buttons, or a keyboard chord
(including things like Alt+Tab or mute).

The remapping happens entirely on the client. The host (Apollo/Sunshine via ViGEmBus) only
speaks a fixed virtual-pad layout plus the normal keyboard stream, so the client reads the
physical controller, decides what to put on the wire, and sends standard inputs the host already
accepts. This works regardless of host configuration and needs no host changes.

---

## 1. Design principles

1. **Opt-in, never automatic.** With no user configuration, the controller behaves exactly as a
   plain pad: standard inputs pass through, nothing is remapped, extra/unknown buttons are inert.
   Remapping only exists if the user goes to the controller setup page and creates it. There is
   no implicit or default remapping.

2. **Rebinding only works on *known* buttons.** A button is bindable only once we have a stable
   identity for it. There are two ways a button becomes known:
   - **macOS tells us** (GameController recognizes it: face buttons, dpad, shoulders, triggers,
     sticks, sometimes a touchpad button). These are known automatically.
   - **The user tells us** (an extra button macOS does not surface, which the user captures and
     labels through the "Map extra buttons" flow in section 3). These become known once labeled.

   An *unknown* button (a raw input we have neither a macOS name nor a user label for) cannot be
   bound. It must first be labeled to become known. This keeps the binding UI honest: every
   bindable thing has a name the user recognizes.

---

## 2. Buttons we can bind: known vs unknown

Three states for any physical input:

- **macOS-known.** A GameController element with a `localizedName` and an SF Symbol. Available to
  bind immediately. (e.g. `Button A`, `Left Trigger`, `Direction Pad`.)
- **User-known (learned).** An extra button that GameController does not expose, but the user has
  captured at the raw-HID level and given a distinct label (e.g. "Back Paddle 2"). Available to
  bind once labeled. Identified internally by `(vendorID, productID, reportID, byteIndex,
  bitmask)`; shown to the user only by its label.
- **Unknown.** A raw input we cannot name yet. Not bindable. The path to make it bindable is the
  learn flow in section 3.

Learned buttons are **device-scoped** by `vendorID + productID`. The raw byte/bit offsets are
specific to one controller's report format (on the test Flydigi the four paddles are bits on
report byte 19, see section 9), so a learned button only applies to that controller model.

---

## 3. Mapping extra buttons (the learn flow)

This is how an unknown extra button becomes a known, labeled, bindable button. It lives behind an
explicit **"Map extra buttons"** control on the setup page (consistent with principle 1).

**Flow:**

1. User taps **Map extra buttons**. This opens a **listen window** that watches the selected
   controller's raw HID input reports (the `IOHIDManager` input-report path already prototyped in
   `HIDProbe`).
2. The listener **actively filters out everything already accounted for**, so only a genuine new
   extra button can be captured:
   - **Analog / motion bytes** are ignored (gyro, accel, sticks, triggers, counters, timestamps)
     via the existing noise classification (high change-rate or many distinct values), reinforced
     by the single-bit rule below.
   - **macOS-known buttons are ignored.** A face button, dpad, shoulder, or trigger always fires
     a GameController event when pressed; a true extra button fires none (proven in testing). So
     if a GameController input changes in the same short window as a raw bit flip, that flip is a
     known button and is skipped.
   - **Already-learned buttons are ignored.** If the user already mapped Back Paddle 1, pressing
     it during the listen does nothing; the listener only reacts to bits it has no identity for.
3. **Capture rule.** A candidate extra button is recognized when, in one report, **exactly one
   bit in a non-analog byte transitions 0 -> 1**, with no concurrent GameController event, and
   that `(byteIndex, bitmask)` is not already learned. (Single rising bit is the clean-button
   signature; a physical jolt flips many IMU bits at once and is rejected. Release is confirmed
   by the same bit going 1 -> 0.) The captured identity is `(reportID, byteIndex, bitmask)`.
4. **Label prompt.** After capture, the user is asked for a **distinct label** ("Back Paddle 2").
   Empty or duplicate labels are rejected.
5. The button is now **known but unmapped**: it appears in the known-buttons list as a bindable
   source, but does nothing on the host until the user creates a binding for it (an unmapped
   extra button has no host meaning, so it is inert by design).

The user can repeat this to label as many extra buttons as the controller exposes, one capture
and label at a time.

---

## 4. What a binding is

A **binding** maps one **source** (one or more known buttons) to one **action**.

- **Source:** one or more *known* buttons, each either a macOS-known GameController element (by
  `localizedName`) or a user-known learned button (by its learned id / label). A source with more
  than one element is a **source combo** (a chord): the binding triggers only when all of its
  elements are held at once. Because learned buttons are bindable sources, a combo can mix kinds,
  e.g. **"Back Paddle 1" + "Button A" -> Alt+Tab on the host**.

  **Source-combo (chord) resolution** (runtime rule, applied when the translator is built):
  - A binding is *active* while all of its source elements are held.
  - Evaluate larger source combos before smaller ones, so "Paddle 1 + A" wins over a plain A
    binding while both are held.
  - An element that participates in an active combo is *consumed* for the combo and does not also
    fire its own single-element output.
  - The transient case (press A, then Paddle 1 a moment later, or vice versa): a participant's
    own output is held back for a short window (a chord-tap delay) to see whether a combo it leads
    completes. If the combo completes, fire the combo and suppress the standalone output. If the
    window elapses or the participant is released first, fire the standalone output then. This is
    the mod-tap / chord pattern used by Karabiner and QMK. The delay only applies to elements that
    actually lead a combo binding, so ordinary buttons stay latency-free.

- **Action:** what to do when that source is held. One of:
  1. **Gamepad button(s):** set one or more standard host gamepad buttons. One button is the
     simple case (Paddle 1 -> Y). Multiple buttons is a **combo** (Paddle 1 -> Y+B).
  2. **Keyboard chord:** send a host keyboard chord, one or more keys held together
     (Paddle 1 -> Alt+Tab, or Paddle 1 -> Mute).

A bound source is **consumed**: its native contribution (if any) is suppressed and replaced by
the action. A macOS-known source bound to a keyboard chord no longer sends its native gamepad
button; a learned extra button had no native host output to begin with.

> There is no "passthrough" action: leaving a button alone simply means not binding it
> (principle 1). Out of scope for now: ordered **sequences/macros** (press X, wait, press Y); the
> model is designed so sequences can be added later as a third action type without reworking it.
> "Combo" always means simultaneous, not sequential.

---

## 5. The two output models (why this is the careful part)

The host has two different input surfaces, and they behave differently.

### Gamepad output is level-based

The host gamepad packet (the `MULTI_CONTROLLER` state packet) carries the **full current state**
every time it is sent. So a gamepad-targeted binding needs no edge tracking: each tick we compute
the target button bitfield from the live source state plus the bindings, and send it. A combo is
just multiple bits set together.

### Keyboard output is edge-based

The host keyboard stream uses discrete **key down** and **key up** events (the existing
`NV_KEYBOARD_PACKET` path, see InputHandler.sendRawKey and keyboard-remapping.md). A
keyboard-targeted binding must detect the source's rising/falling edges:

- **Source down:** key-down for each key in the chord, modifiers first (Alt down, then Tab down).
- **Source up:** key-up in reverse order (Tab up, then Alt up).

A single tap produces one full down-then-up of the chord (one Alt+Tab). Holding the source holds
the chord; host-side auto-repeat then applies to the final key. Documented behavior.

This is the feasibility argument for keyboard-from-controller: the keyboard send primitive already
exists and is transport-reachable (`StreamTransport.sendInput(packet:channel:)`). A controller
binding that emits keyboard just builds the same `NV_KEYBOARD_PACKET` and calls it.

---

## 6. Combos and the shared-key problem

Combos are simultaneous holds.

- **Gamepad combos** (Y+B): set both bits in the level-based state. Overlap is a harmless OR.
- **Keyboard combos** (Alt+Tab): ordered down/up as in section 5. The risk is two sources whose
  chords share a key (both include Alt). Sending Alt-down twice then Alt-up once leaves Alt stuck,
  so keyboard output keeps a **reference count per host key**: down on the 0->1 transition, up on
  the 1->0 transition. InputHandler already tracks a `heldKeys` set; the controller path needs the
  count variant because multiple bindings can request the same key.

---

## 7. Allowed keyboard targets (and a bonus the keyboard editor could not offer)

keyboard-remapping.md restricts which **Mac keys** can be a remap *source* (modifier cluster
only) to protect typing. That does not apply here: the source is a controller, which never types,
so the **target** key set can be broad:

- Letters, digits, F1-F12.
- Modifiers (Ctrl/Alt/Shift/Win) and combinations with a key.
- Enter, Esc, Tab, Space, arrows, Home/End/PageUp/PageDown.
- **Media keys, notably Mute/Volume.**

The media-key bonus: keyboard-remapping.md excludes volume/media keys because macOS consumes them
before the app sees them when they come from the Mac keyboard. A controller button has no such
problem (macOS never interprets "gamepad button -> mute"), so the client can synthesize the host's
mute virtual-key (`VK_VOLUME_MUTE`, 0xAD) freely. Caveat: depends on the host honoring media
virtual-keys through its keyboard injection; verify against Apollo once wired.

### Keys are chosen on a virtual host keyboard, sent direct to the host (decision: option b)

The user picks the target keys on a **2D on-screen keyboard that represents the host keyboard**
(like the Windows on-screen keyboard), clicking one key or several to build a combo. They are NOT
captured from the Mac keyboard.

Two models were considered:
- **(a) Route through the Mac:** capture a Mac keystroke, let it flow to the host via the normal
  keyboard path. Rejected: macOS intercepts many keys before the app sees them (the Command/
  Windows key and its system shortcuts, Spotlight, media keys, etc.), causing conflicts and
  double-handling. Pressing "Win" would do something on the Mac instead of cleanly on the host.
- **(b) Pick host keys on a virtual keyboard, send the host key codes directly.** Chosen. The
  binding stores host key tokens and builds the `NV_KEYBOARD_PACKET` itself, so the keystroke only
  ever exists on the host. Every key is selectable, including ones macOS would otherwise eat (Win,
  F-keys, media), with no Mac-side conflict.

Behavior: clicking modifiers (Ctrl/Alt/Shift/Win) and a key assembles a held-together chord
(Alt+Tab); a single key click is the one-key case. Each on-screen key maps to a host Win32
virtual-key. (Layout note: key *labels* can follow a standard layout for display; the codes we
send are the host's position-based virtual-keys. Per-layout localization of the visual is a minor
later detail, see open questions.)

---

## 8. Host face-button mapping reference

The host emulates an Xbox-style pad, so PlayStation faces map as:

| DS4 (PlayStation) | Host (Xbox layout) | Host flag       |
|-------------------|--------------------|-----------------|
| Cross (bottom)    | A                  | `A` 0x1000      |
| Circle (right)    | B                  | `B` 0x2000      |
| Square (left)     | X                  | `X` 0x4000      |
| Triangle (top)    | Y                  | `Y` 0x8000      |

Full host button set (confirmed from Apollo `src/platform/common.h`): dpad, Start, Back, L3/R3,
LB/RB, Home/Guide, A/B/X/Y, four paddles, `TOUCHPAD_BUTTON` (0x100000), `MISC_BUTTON` (0x200000).

---

## 9. Raw HID findings (from live testing)

What each test controller actually exposes, established with the `HIDProbe` raw-report capture:

- **Flydigi (Apex 4, reports as "Flydigi VADER3", presents as Xbox): paddles ARE recoverable.**
  All four back buttons are clean distinct bits on **report 0, byte 19**:
  `P1=0x04, P2=0x08, P3=0x10, P4=0x20`. Each is a single-bit, consistent-value, clean on/off
  press with **no GameController event** (GameController hides them; raw HID reads them perfectly).
  This is the proof case for the learn flow and the model controller for extra-button support.
- **DualShock 4: no extra buttons.** The DS4 has no paddles; face buttons are byte 5 and also fire
  GameController events. The bytes that appear to react to a "paddle" press are gyro/accel
  reacting to the physical jolt, not a button (several bytes change, inconsistent values).
- **GameSir (Switch/DS4 modes): paddles emit nothing.** Folded into firmware or inert; nothing on
  the wire at any level. Not recoverable on macOS.

Conclusion: extra-button support is real but **device-dependent**. The learn flow handles this by
detecting each controller's actual bits rather than hardcoding offsets, and scoping them by
VID/PID.

Forcing macOS to treat a controller as an Xbox Elite (to get the official paddle API) is **not
possible**: GameController deliberately ignores virtual HID devices and there is no virtual-
controller API on macOS (Apple Developer Forums thread 812774). Every working macOS paddle mapper
(paddlr, ControllerKeys) reads paddles via raw IOKit HID, which is exactly the approach here.

---

## 10. Components (as built)

- **ControllerInput** — GameController read/observe layer: discovery, live values, listen, combo
  capture, multi-controller selection, and the selected pad's macOS-known buttons. Its
  `lastEvent.at` is the GC-activity signal the learn flow uses to filter known inputs.
- **HIDProbe** — `IOHIDManager` diagnostic in the setup page (element scan + raw-report dump with
  analog-noise filtering) and the **learn flow** (single rising bit, no GC event, skip
  already-learned). Exposes device VID/PID.
- **RawHIDBitReader** — slim runtime `IOHIDManager` reader (separate from HIDProbe) that keeps the
  latest report bytes per reportID so the translator can poll learned-button bits while streaming.
- **ControllerConfig + ControllerConfigStore** — per-controller JSON file `<VID>_<PID>.json`
  holding hardware id, names, display name, macOS buttons, learned buttons, and bindings. A
  registry (UserDefaults) links a device's hardware id to its file path; default dir is
  `~/Library/Application Support/ChloroFrame/Controllers`. Supports import (link any file) and
  remove (unlink; file stays). Replaces the old UserDefaults stores.
- **ControllerBinding / BindingSource / BindingTarget / GamepadButton / KeyToken** — the binding
  model. A `BindingSource` is `.gamepad(name:)` (GC element) or `.learned(...)` (raw-HID button).
- **ControllerWire** — exact host wire encoders (MULTI_CONTROLLER + arrival), GamepadButton ->
  host flag map, key token -> Win32 VK map, channels. Transcribed from moonlight-common-c.
- **ControllerTranslator** — the rebind engine. Polls GameController + RawHIDBitReader at 120 Hz,
  applies bindings (largest-combo-first, consumed sources), builds the level-based gamepad state
  (sent on change) and edge-based keyboard events (ref-counted). Created next to InputHandler in
  HostConnectionView, stored on StreamState, started on activate and released/stopped on teardown.
- **HostKeyboardView** — the 2D on-screen Windows keyboard picker (section 7, option b). Replaced
  the Mac-keyboard chord capture (`HostChordCapture`, removed).

---

## 11. UI (the controller setup page)

- **Known buttons list:** macOS-known elements (auto, with SF Symbol glyphs) plus user-labeled
  learned buttons. This is the pool of bindable sources.
- **Map extra buttons:** the section 3 learn flow. Listen -> capture an unknown bit -> label ->
  it joins the known-buttons list (unmapped).
- **Add binding / rebind:** pick one or more known buttons as the source (combo), then a target:
  - **Gamepad button(s):** multi-select of the standard host buttons (multi-select = combo).
  - **Keyboard chord:** a **virtual on-screen host keyboard** (section 7, option b). Click one key
    or several to build the chord; modifiers toggle, other keys complete it. Includes media keys.
    No Mac-keyboard capture.
- Live detection and per-element glyphs stay visible so the user can see what the controller
  exposes before binding.
- Raw HID view stays as an advanced diagnostic.

---

## 12. Safety: no stuck inputs

Keyboard output is edge-based and can be held, so the translator must release everything on stream
stop, disconnect, controller disconnect, and app focus loss:

- Key-up every host key its ref-count holds, then zero the counts.
- Clear all gamepad button bits (send a zeroed state on teardown).

Mirrors InputHandler.releaseAll, ideally sharing the same release bookkeeping once the send
primitive is factored out.

---

## 13. Feasibility, honest version

- **Extra (learned) buttons: yes, when the controller emits them.** Proven on the Flydigi
  (byte 19 bits). Detected and labeled via the learn flow, bound like any known button.
- **Keyboard from a controller, including combos: yes.** Same transport call as the keyboard
  path. Mute is more feasible from a controller than from a Mac key (macOS does not intercept it).
- **Gamepad-button combos: yes, and easy** (level-based bitfield).
- **Honest limits:**
  - We can only bind what the controller actually emits. If an extra button is folded into a
    standard input in firmware (GameSir) or emits nothing, there is nothing to learn. The learn
    flow tells the user this honestly: pressing it captures nothing.
  - Learned buttons are device-scoped (VID/PID + byte/bit); they do not transfer to a different
    controller model.
  - Holding a keyboard-bound source lets host auto-repeat run (cycling Alt+Tab). Chosen behavior.
  - Media virtual-keys through the host keyboard injection are assumed to work; verify on Apollo.

Nothing requires host changes. This is now wired into the stream and verified on a live host.

---

## 14. Phased plan (all done)

1. **[done] Setup page + known-buttons model.** Opt-in window listing macOS-known buttons.
2. **[done] Learn flow.** "Map extra buttons": raw-HID single-bit capture with section-3 filters,
   label prompt, per-controller persistence. Verified on the Flydigi paddles.
3. **[done] Binding authoring.** Sources reference macOS-known and/or learned buttons; targets are
   gamepad combos or host keyboard chords, including mixed combos (Paddle 1 + A).
4. **[done, via ControllerWire] Keyboard send.** The translator builds `NV_KEYBOARD_PACKET` via
   ControllerWire with ref-counted held keys (rather than refactoring InputHandler.sendRawKey).
5. **[done] ControllerTranslator.** GC state + learned bits + bindings -> gamepad state (level) +
   keyboard edges (edge), consumed-source suppression, stuck-input safety.
6. **[done] Gamepad wire path.** Arrival + `MULTI_CONTROLLER` encoder via `transport.sendInput`.
7. **[done] Verified on host.** Standard pad, gamepad/keyboard rebinds, and paddle bindings
   (paddle -> A, paddle -> Alt+Tab without macOS interception) confirmed on a live Apollo host.

Remaining/next: persistence robustness polish, motion/touchpad/rumble/battery, multiple
controllers, controller-arrival capabilities, and the chord-tap delay nuance.

---

## 15. Decisions and open questions

**Decided:**
- **Learned buttons always start unmapped** (no pass-through at label time). Assume the user may
  not know what they are doing; an unmapped extra button is likely already unmapped on the host
  too, so unmapped is the safe, predictable default. (Principle 1.)
- **Keyboard targets use a virtual on-screen host keyboard, not Mac capture** (section 7, option
  b). Direct-to-host avoids macOS interception conflicts.

**TODO / deferred:**
- *(needs definition)* Learned-button capture across report formats: is single-bit `0->1` with no
  GC event sufficient on all controllers, or do some pack an extra button as a value in a shared
  byte (needing a per-bit mask within a changed byte)? Not well understood yet; revisit only if a
  real controller defeats the single-bit rule.

**Open:**
- Virtual keyboard layout/localization: which visual layout to show, and whether to localize it.
  Host key codes are position-based, so this is cosmetic; defer.
- Device identity: VID/PID is enough to scope learned buttons, but two same-model pads are
  indistinguishable. Acceptable for now.
