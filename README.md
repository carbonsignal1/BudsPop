# BudsPop

Control your OnePlus, OPPO and realme earbuds from your Mac. These buds are normally managed through the HeyMelody phone app; BudsPop brings the same controls to macOS: battery levels for each earbud and the case, noise cancellation modes and levels, and a heads-up when the buds connect or run low.

Built and tested with **OnePlus Buds 4**. Other models that use the HeyMelody protocol may work too.

## Features

- **Battery:** left, right and case levels with charging indicators; the case keeps its last known level while closed
- **Noise control:** Off, Transparency, Adaptive and Noise Cancellation
- **Noise cancellation level:** Auto, Low, Moderate or High, shown while Noise Cancellation is on
- **Connected pop-up:** a small pill drops down from the menu bar when the buds connect; click it for the full controls
- **Low battery warning:** the pill comes back when an earbud that isn't charging drops below 20%, and again at 10%
- **Menu bar:** an icon with the lowest earbud battery; click for the controls, right-click for the menu
- **Menu:** noise modes and levels, Connect / Disconnect, choosing which earbuds, Open at Login, pop-up and warning switches, and a debug log
- **Live updates:** changes made on the earbuds or in HeyMelody show up in BudsPop straight away

## Requirements

- macOS 14 or later on Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`); Xcode itself isn't needed
- Earbuds paired with the Mac in System Settings → Bluetooth

## Build and install

```sh
./build.sh
cp -R build/BudsPop.app ~/Applications/
open ~/Applications/BudsPop.app
```

On first launch macOS asks for Bluetooth access; allow it.

## Usage

| Action | What it does |
| --- | --- |
| Earbuds connect | The Connected pill drops down for a few seconds |
| Click the pill or the menu bar icon | Open the controls |
| Right-click the menu bar icon | Noise modes, Connect/Disconnect, choose earbuds, settings |
| Open the app while it's running | Open the controls |

By default the app picks any paired device whose name contains OnePlus, OPPO, Enco, realme or Dizo. Use **Earbuds** in the right-click menu to choose a specific one.

For testing, `open ~/Applications/BudsPop.app --args --banner` shows the Connected pill at launch and `--low-battery` shows the warning (quit BudsPop first, since arguments only apply to a fresh launch).

### Earbud images

BudsPop can show photos of your earbuds and case in the pop-ups and controls, and builds the menu bar icon from the earbud outlines. The images aren't included in this repo. To use them, put transparent PNGs in `Resources/` before running `./build.sh`:

- `bud-left.png` and `bud-right.png`: one earbud each, standing upright
- `case.png`: the charging case

Without them, BudsPop uses system symbols instead.

## How it works

The earbuds expose a vendor serial service over Bluetooth Classic (RFCOMM). On the Buds 4 it's advertised as **"enco link"** on channel 15; older models use channel 12 or 13. BudsPop probes the advertised channels first, keeps the first one that answers, and remembers it.

Every message is a frame:

```
AA <len> 00 00 <cmd lo> <cmd hi> <seq> <payload len lo> <payload len hi> <payload…>
```

| Command | Purpose |
| --- | --- |
| `0x0106` → `0x8106` | Battery: `[0, count, (id, level|charging<<7)…]`, ids 1 = left, 2 = right, 3 = case |
| `0x0109` → `0x8109` | Wear state per earbud |
| `0x010C` → `0x810C` | Read noise mode (`[01 01]`) |
| `0x0404` → `0x8404` | Set noise mode `[01 01 value]`; ack byte 0 = accepted |
| `0x0205` | Subscribe to pushed updates (`0x0204`) for battery, wear state and noise mode |

Noise mode values on the Buds 4, checked by reading the mode back after each change and against HeyMelody:

| Mode | Set with | Reported as |
| --- | --- | --- |
| Off | `0x0001` | `0x0008` |
| Transparency | `0x0004` | `0x0100` (sometimes `0x0200`) |
| Adaptive | `0x0800` | `0x0800` |
| Noise Cancellation (last used level) | `0x0002` | the level's code |
| Noise Cancellation – Auto | `0x0080` | `0x0080` |
| Noise Cancellation – Low | `0x0040` | `0x0040` |
| Noise Cancellation – Moderate | `0x0020` | `0x0020` |
| Noise Cancellation – High | `0x0010` | `0x0010` |

Values are 16-bit little-endian: values up to `0xFF` are sent as one byte, larger ones as two (Adaptive is `00 08`). In Auto the earbuds also report the strength they picked under config type 4.

An earbud that's in the case is left out of the battery reply, so BudsPop shows it as unknown rather than keeping its old level.

## Known limitations

- Some models only allow Noise Cancellation while both earbuds are worn; the controls say so when the earbuds refuse a change.
- Only tested on OnePlus Buds 4. If something doesn't work on your model, the debug log (right-click → Show Debug Log, or `~/Library/Logs/BudsPop.log`) records every frame sent and received.

## Credits

- [oppo-pods](https://github.com/noctalia-dev/community-plugins/tree/main/oppo-pods) Noctalia plugin by osp54, for the frame format and command set
- [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge), for the wear state and subscription commands

Not affiliated with OnePlus, OPPO or realme.
