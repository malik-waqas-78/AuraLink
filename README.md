<p align="center">
  <img src="AuraLinkLogo.png" alt="AuraLink Logo" width="180" />
</p>

<h1 align="center">AuraLink</h1>
<p align="center">
  <b>Premium macOS Bluetooth Audio Stabilizer</b><br>
  <em>Prevent audio dropout, silence gating, and connection drops on budget Bluetooth earbuds.</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13.0%2B-blue?style=flat-square&logo=apple" alt="macOS 13.0+" />
  <img src="https://img.shields.io/badge/Swift-5.9-orange?style=flat-square&logo=swift" alt="Swift" />
  <img src="https://img.shields.io/badge/Architecture-Apple%20Silicon-green?style=flat-square" alt="Apple Silicon" />
  <img src="https://img.shields.io/badge/License-MIT-purple?style=flat-square" alt="MIT License" />
</p>

---

AuraLink is a professional, native macOS Menu Bar application written in **Swift and SwiftUI**. It solves aggressive hardware-level digital silence gating and connection drops common in budget Bluetooth audio devices (such as Ronin earbuds) by utilizing a sub-audible dither keep-alive signal.

Built completely using modern macOS APIs (`NSPopover`, `SMAppService`, `IOBluetooth`, `CoreAudio`), AuraLink provides visual telemetry, automatic daemon recovery, progressive reconnection backoff, and persistent background link stabilization in a beautiful, glassmorphic HUD panel.

---

## 💎 Premium Design & User Experience

AuraLink runs entirely inside the macOS system status bar (Menu Bar), maintaining a lightweight footprint:
- **Neon Glassmorphism Interface**: Featuring custom HSL matching gradients, real-time animated radial pulse circles, and modern typography.
- **Visual Telemetry**: Real-time RSSI signal quality bars indicating `Excellent`, `Good`, or `Weak` connection status.
- **Live Diagnostic Feed**: Monospaced, color-coded diagnostic line that shows human-readable Bluetooth controller event messages in real time (e.g., "✓ Connected successfully!", "✗ Device not responding", "⏳ Retry backoff: reconnecting in 28s").
- **Scrollable Safety Layout**: Smooth and dynamic settings drawers that adapt perfectly inside Popover constraints without jumping or clipping.

---

## 🛠️ The Technical Core (Anti-Gating Protocol)

### 1. The Silence-Gating Problem
Budget and standard Bluetooth earbuds contain aggressive power-saving Digital Signal Processors (DSPs). If the digital audio channel transmits exactly `0` values (pure mathematical silence for a few seconds), the earbud's DSP gates the digital-to-analog converter (DAC) and amplifier to save power. 

When you resume video or audio playback, the DSP takes **1.5 to 2.5 seconds** to ungate the amplifier. This causes the beginning of your media to be completely muted, or leads to frequent audio dropouts, lags, and connection timeouts.

### 2. The Solution: Sub-Audible AC Dither
AuraLink bypasses this DSP sleep-gate by continuously streaming extremely faint, randomized **PCM white noise dither**:
- Programmatically generates a randomized 16-bit PCM signal between tiny limits (e.g. `-3` to `+3` sample bounds out of `32,768`).
- Binds this active dither stream to the output device at an extremely low linear player volume (`0.05`).
- The resulting acoustic amplitude is approximately **`-106 dB`**—well below the human auditory threshold, making it **100% physically inaudible**.
- To the earbud's DSP, this represents continuous alternating current (AC) stream activity. The DSP is forced to keep the hardware DAC and amplifier wide awake and responsive, yielding instant, lag-free audio transitions.

---

## ⚡ Key Features

* **Sub-Audible Keep-Alive**: Prevents audio sleep and clipping using customizable digital audio dither levels.
* **Intelligent Auto-Reconnect Daemon**: Automatically detects connection losses and rebuilds the link with **progressive backoff** (15s → 30s → 60s → 120s max) to prevent Bluetooth controller overload and earbud firmware crashes.
* **Manual Disconnect Override**: If you manually disconnect a device in the app, the auto-reconnect daemon is automatically paused to prevent unwanted reconnections.
* **Connection State UI**: Real-time visual spinner with "Connecting..." state prevents rapid-click spamming and provides clear feedback.
* **IOReturn Diagnostic Telemetry**: Maps raw low-level Bluetooth controller error codes to human-readable messages (`Device not responding`, `Connection timed out`, `Resource busy`, etc.).
* **Active Output Routing**: Constantly monitors macOS audio routes. If the active device changes, it automatically recycles the Keep-Alive player to bind cleanly to the new route.
* **Advanced Configuration Drawer**:
  * **Run at Login**: Automatically start AuraLink at system boot via native macOS `SMAppService` API.
  * **Telemetry Rate**: Configurable background polling frequencies (Fast: 1.0s, Balanced: 2.0s, Battery Saver: 5.0s).
  * **Stabilizer Strength**: Control dither amplitude bounds (Low: -100 dB, Balanced: -90 dB, Max: -80 dB, Off).
* **System Recovery Diagnostics**: Integrated administrator tools to instantly restart `coreaudiod` and `bluetoothd` system daemons if severe system-level lockups occur.

---

## 🚀 Simple Installation

AuraLink is fully compiled and ready to use!
1. Download **`AuraLink.zip`** from the [latest release](../../releases).
2. Unzip and drag `AuraLink.app` directly into your **Applications** folder.
3. Launch AuraLink. 
4. The system will prompt you for **Bluetooth Permissions** so the app can scan paired devices and check raw RSSI telemetry. Click **Allow**.
5. Select your target earbuds in the device list, enable **Active Keep-Alive**, and enjoy uninterrupted premium audio!

> **Note:** Since the app is ad-hoc signed (not notarized), macOS may show a Gatekeeper warning. Right-click → **Open** on first launch to bypass it.

---

## 🛠️ Compiling from Source

If you are a developer and wish to build or customize AuraLink, compilation takes seconds.

### Prerequisites
* A Mac running **macOS 13.0 (Ventura) or later**.
* **Apple Silicon** processor (M1, M2, M3, M4, etc.) — targeted for `arm64-apple-macos13.0`.
* Xcode Command Line Tools installed (run `xcode-select --install`).

### Build Steps
Simply run the included build script in terminal:
```bash
chmod +x build.sh
./build.sh
```

The script will automatically:
1. Discover the macOS SDK path.
2. Compile `main.swift` with optimization flags (`-O`) and links the required frameworks.
3. Assemble the native `AuraLink.app` bundle structure with `Info.plist` properties.
4. Apply an ad-hoc code signature for immediate local execution on Apple Silicon.
5. Compress the finalized binary into a portable `AuraLink.zip` archive.

---

## 📦 System Framework Integrations
| Framework | Purpose |
|---|---|
| `IOBluetooth` | Discovers and queries paired system wireless peripherals |
| `CoreAudio` & `AudioToolbox` | Inspects default system sound routes and formats device streams |
| `AVFoundation` | Drives the low-latency background audio loop engine |
| `ServiceManagement` | Natively registers the helper daemon for startup operations |

---

## 📂 Project Structure

```
Mac-Bluetooth/
├── main.swift          # Complete application source (~1500 lines)
├── build.sh            # One-command compile, package, and sign script
├── Info.plist          # macOS app bundle metadata and permissions
├── AuraLinkLogo.png    # Premium application icon
├── README.md           # This file
└── .gitignore          # Standard build artifact exclusions
```

---

## 📄 License
This project is open-source and released under the **MIT License**.
