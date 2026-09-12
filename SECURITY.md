# FacePass Security Design

FacePass unlocks a Mac with the owner's face. This document explains what it protects against, what it cannot protect against, and how it works.

> **Honest limit.** MacBook cameras are plain 2D RGB cameras with no depth or infrared sensor. No app can make them as strong as iPhone Face ID. FacePass is a *convenience* unlock with multiple layers, not a replacement for your password or Touch ID.

## Goals

1. **Nothing leaves the Mac.** No network code, no server, no analytics, no auto-update. Face data and the password never touch disk unencrypted.
2. **One user's data can't be read by another user or another app.**
3. **Resist common attacks:** photos, phone or laptop screens replaying video, virtual cameras, tampering with settings, guessing by repeated attempts.
4. **Fail closed.** If any check is unsure, FacePass does nothing and the normal password screen stays.

## Threat model

| Attacker | Protected? | How |
|---|---|---|
| Holds up a printed photo | Yes | MiniFASNet liveness on every frame, 3D pose-consistency check |
| Plays a video on a phone or laptop | Mostly | Liveness models, screen/bezel/moiré cues, random spoken challenge, proximity factor |
| Feeds video through a virtual camera (OBS, CMIO extension) | Yes | Only Apple built-in cameras are accepted |
| Another app on the same account changes the match threshold or turns off liveness | Yes | Security settings live inside the encrypted vault; changing them needs Touch ID; hard minimums compiled in |
| Another app tries to read the stored password | Yes | Password sealed to a Secure Enclave key that needs Touch ID; key can't leave the chip |
| Another macOS user account | Yes | Per-user keychain, files `0600` in the user's own Library |
| Keeps trying until it works | Yes | 3 failed scans disable face unlock until a password login |
| Steals the Mac while it's locked, owner's phone not nearby | Yes (with proximity on) | Unlock also needs the owner's iPhone/Apple Watch in Bluetooth range |
| Realistic 3D mask, identical twin | **No** | 2D camera can't tell. Proximity factor is the backstop |
| Malware already running as the user with Accessibility or root | **No** | Such malware can already capture the password when you type it |
| Mac is rebooted or FileVault pre-boot | Not applicable | Password is always required after restart |

## Architecture

```
Lock detected (CGSession) ──► Session armed? ──► Built-in camera only ──► Face detect + 5-point align
        │                         │ no → stop                                       │
        │                                                                           ▼
        │                                              SFace embedding ≥ threshold, N consecutive frames,
        │                                              same tracked face throughout
        │                                                                           │
        │                                              Liveness: MiniFASNet ×2 + pose/depth + screen cues
        │                                              (+ random spoken challenge in Strict mode)
        │                                                                           │
        │                                              Proximity: owner's iPhone/Watch RSSI (if enabled)
        │                                                                           │
        └── still locked & on console? ◄──────────────────────────────────────────────┘
                     │ yes
                     ▼
         Secure Enclave op (session LAContext) → decrypt password into locked buffer
         → type keystrokes, re-checking lock state before each key → zero buffer
```

### Secrets

| Item | Protection |
|---|---|
| **Vault key** | Secure Enclave P-256 key, access control `privateKeyUsage + biometryCurrentSet`. Only its SE-wrapped handle is stored, in the data-protection keychain (`ThisDeviceOnly`). Adding a new fingerprint invalidates it, so setup must be redone. |
| **Password** | HPKE-sealed to the vault key's public key. Opening needs the Secure Enclave and an authenticated context. |
| **Face templates** | Only 128-number embeddings, never images. AES-GCM encrypted with a key derived from the vault, with purpose-bound AAD. |
| **Security settings** | Stored inside the vault. Floors enforced in code: threshold never below the calibrated minimum, liveness can't be turned off. |
| **Cosmetic prefs** | `UserDefaults` (sound on/off, menu bar icon). Nothing that affects security. |

Before saving, the password is checked against the account with OpenDirectory, so a wrong password can never be typed repeatedly and trigger an account lockout.

### Session ("armed" state)

Face unlock only works while a session is **armed**:

- **Arming:** the user signs in normally, then approves a Touch ID prompt. FacePass keeps the authenticated `LAContext` in memory. It does **not** keep the decrypted password or a raw key.
- **Session ends (disarmed) on any of:**
  - restart or logout
  - 24 hours after arming (fixed, not renewed by use)
  - locked continuously for more than 4 hours (configurable lower, not higher)
  - 3 failed face scans
  - the user choosing "Disarm" or pressing the panic shortcut
  - enrolled faces or security settings changing
  - fingerprint set changing
- **Disarming** calls `LAContext.invalidate()`. Re-arming needs a password login and Touch ID again.

### Camera

- Only `AVCaptureDevice` of type `.builtInWideAngleCamera` made by Apple with a built-in transport is used. External, Continuity and virtual cameras are refused.
- Frames are processed in memory and dropped. Nothing is written to disk.
- The camera light always turns on while scanning (hardware-enforced on Apple Silicon).

### Matching

- Vision face rectangles and landmarks, then a 5-point similarity transform to the 112×112 template. **No lower-quality fallback alignment.**
- Frames below the Vision capture-quality floor are ignored.
- Needs cosine similarity ≥ threshold on **several consecutive frames of the same tracked face**, and a clear margin over the average.
- One owner per Mac user account.
- A head turned more than 25° doesn't count: identity scores drop and the gap to other people narrows.
- All thresholds live in `UnlockPolicy` and come from recorded calibration runs (`tools/calibration/`). The first run showed SFace alone leaves a thin margin (another person's photo scored 0.74 vs the owner's 0.87–0.96), so identity is never trusted without liveness.

### Liveness

Every matching frame must also pass:

1. **MiniFASNet V2 (2.7× crop) + V1SE (4.0× crop)**, averaged "real" probability ≥ threshold.
2. **Pose-consistency:** nose displacement must correlate with head yaw as a 3D face does.
3. **Screen cues:** device-bezel rectangle around the face, specular glare, moiré/FFT energy. Any deny cue on a single frame aborts the scan.
4. **Strict mode (optional):** a random spoken prompt ("look left", "blink twice") via speech synthesis, checked within a short window. A pre-recorded video can't know the order in advance.

Liveness and identity are checked on **the same frames of the same tracked face**, so a live bystander can't supply liveness for a photo of the owner.

### Proximity factor (recommended)

At setup, the user picks their iPhone or Apple Watch. Devices on the same Apple Account resolve to a stable identity, so FacePass can read signal strength (RSSI). Unlock needs the device above an RSSI floor. It can be relay-attacked by a determined attacker, so it's one layer, not the whole defence.

### Typing the password

- Before starting, and **before every keystroke**, FacePass checks: `CGSSessionScreenIsLocked == true` and the session is on the console. If either changes, typing stops at once, so the password can't land in a desktop app.
- The field is cleared first, so leftover characters don't cause a failed login.
- The password lives in an `mlock`ed byte buffer, never a Swift `String`, and is zeroed immediately after.

### Rate limiting

- At most one scan per lock/wake event, with a growing cool-down (5 s, 15 s, 60 s…).
- 3 failed scans with a face present → session disarmed.
- An attempt log (time, result, reason; **no images**) is kept locally so the owner can see if someone tried.

## Platform and distribution

- Menu-bar agent (`LSUIElement`), hardened runtime, Developer ID signed and notarized. It can't be sandboxed because posting keystrokes to the lock screen isn't allowed in the App Sandbox.
- No private APIs.
- No update framework and no outgoing connections. Updates come from signed GitHub releases.
- Source is public, so anyone can audit it.
- **Uninstall** removes the keychain items, the Secure Enclave key and all files.

## Items to verify during the prototype

These depend on macOS behaviour that must be confirmed on real hardware before release:

- [ ] An authenticated `LAContext` still authorises Secure Enclave key operations while the screen is locked, and for how long.
- [ ] HID-tap `CGEvent` typing still reaches the lock-screen password field on macOS 26.
- [ ] Owner iPhone/Watch RSSI is readable through CoreBluetooth while the screen is locked.
- [ ] Speech output is audible while locked (Strict mode).
- [ ] SFace threshold and MiniFASNet threshold calibrated on MacBook FaceTime camera footage.

## Reporting a vulnerability

Please open a private security advisory on the GitHub repository instead of a public issue.
