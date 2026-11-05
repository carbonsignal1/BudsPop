# BudsPop

An AirPods-style pop-up for OnePlus, OPPO and realme earbuds on macOS. When your earbuds connect, a card slides in with battery levels and noise control. It also lives in the menu bar so you can bring it back any time.

Built and tested with **OnePlus Buds 4**. Other models that use the HeyMelody app's protocol may work too.

## Features

- Pop-up card when the earbuds connect, which stays open while your pointer is over it
- Battery rings for left, right and case, with charging indicators (the case shows its last known level when closed)
- Noise control: Off, Transparency, Noise Cancellation
- Menu bar icon showing the lowest earbud battery; click for the card, right-click for the menu
- Connect / Disconnect, device picker, Open at Login, and a debug log

## Requirements

- macOS 14 or later on Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`), Xcode itself isn't needed
- Earbuds paired with the Mac in System Settings → Bluetooth

## Build and install

```sh
./build.sh
cp -R build/BudsPop.app ~/Applications/
open ~/Applications/BudsPop.app
```

On first launch macOS asks for Bluetooth access; allow it. Opening the app again (Finder, Spotlight or `open`) brings the card back.

## Usage

| Action | What it does |
| --- | --- |
| Click the menu bar icon | Show or hide the card |
| Right-click the menu bar icon | Noise modes, Connect/Disconnect, choose earbuds, settings |
| Open the app while it's running | Show the card |

By default the app picks any paired device whose name contains OnePlus, OPPO, Enco, realme or Dizo. Use **Earbuds** in the right-click menu to choose a specific one.

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

Noise mode values: `01` Off, `02` Transparency, `08` Noise Cancellation (`04`/`10`/`20` are ANC strength levels).

## Known limitations

- Some models only allow Noise Cancellation while both earbuds are worn; the card says so when the earbuds refuse a change.
- Only tested on OnePlus Buds 4. If something doesn't work on your model, the debug log (right-click → Show Debug Log, or `~/Library/Logs/BudsPop.log`) records every frame sent and received.

## Credits

- [oppo-pods](https://github.com/noctalia-dev/community-plugins/tree/main/oppo-pods) Noctalia plugin by osp54, for the frame format and command set
- [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge), for the noise-mode values, wear state and subscription commands

Not affiliated with OnePlus, OPPO or realme.
