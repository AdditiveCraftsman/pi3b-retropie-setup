# pi3b-retropie-setup

Setup script for a fresh **RetroPie 4.8** card (Raspberry Pi OS Buster) on a **Raspberry Pi 3B**.
It reproduces the tuning of one specific RetroPie build: fan, overclock, Bluetooth audio, RetroArch
settings, the Virtual Boy core, and Tailscale.

> **Status: v0.1.** Run stage by stage on a fresh RetroPie 4.8 card (Raspberry Pi 3 Model B Rev 1.2) on 2026-11-25: fan, config, Bluetooth, RetroArch, Virtual Boy and Tailscale all completed, a reboot kept them working, and a second run is a no-op. Always start with `--dry-run`.

It is for RetroPie Pi 3B cards only and refuses to run on anything else (wrong board, not Buster,
RetroPie missing, or running as root). It contains no ROMs and no BIOS files.

## Requirements

- Raspberry Pi 3 Model B (not the B+), RetroPie 4.8 image, user `pi`
- Network access (apt, GitHub, Tailscale)
- A PWM fan on GPIO 18 with the [pi-pwm-fan](https://github.com/AdditiveCraftsman/pi-pwm-fan) circuit.
  The overclock step refuses to run without a running `pwm-fan` service.

## Use

Copy `retropie-setup.sh` and `retroarch-overrides.cfg` into the same folder on the Pi, then:

```
chmod +x retropie-setup.sh
./retropie-setup.sh --dry-run
./retropie-setup.sh --bt-mac AA:BB:CC:DD:EE:FF
sudo reboot
```

| Option | What it does |
| --- | --- |
| `--dry-run` | Print what would happen, change nothing |
| `--only a,b` / `--skip a,b` | Run or skip steps: `fan config bluetooth retroarch vb tailscale` |
| `--bt-mac MAC` | Bluetooth speaker address for RetroArch audio (not stored in the repo) |
| `--static-ip IP` | Opt-in: write a dhcpcd static address for `wlan0` (applies at next reboot) |
| `--fix-apt-mirror` | Opt-in: repoint `/etc/apt/sources.list` from the dead `raspbian.raspberrypi.org` Buster mirror to `legacy.raspbian.org` (backup kept). A fresh RetroPie 4.8 image needs this, or `apt-get update` fails. |

Settings can be overridden with environment variables: `FAN_REF`, `FAN_CURVE`, `TS_HOSTNAME`, `IFACE`,
`GATEWAY`, `DNS_SERVER`, `ALLOW_OC_WITHOUT_FAN=1` (accept the risk of overclocking without a fan).

## Steps

1. **fan**: installs pi-pwm-fan at a pinned commit with the gaming curve.
2. **config**: managed block in `/boot/config.txt` (`arm_freq=1350`, `core_freq=500`, `sdram_freq=500`,
   `over_voltage=2`, `temp_limit=80`, `force_turbo=0`, `gpu_mem=256`); backup first.
3. **bluetooth**: installs bluealsa; you pair the speaker yourself with `bluetoothctl`.
4. **retroarch**: re-applies the settings in `retroarch-overrides.cfg` and sets the audio device.
5. **vb**: installs `lr-beetle-vb` through RetroPie-Setup.
6. **tailscale**: installs Tailscale; you log in yourself. Run it with `--accept-dns=false` if the
   network already has its own DNS (for example a Pi-hole).

Backups are written next to the originals with a `.bak-retropie-setup` suffix, and re-running the script
is safe: the managed blocks are replaced, not duplicated.

## Notes

- The overclock values are what worked on one specific board with a fan and a stable 5.25 V supply.
  Check `vcgencmd get_throttled` (want `0x0`) and `sudo dmesg | grep -i voltage` after the first reboot.
  Undervoltage is the first suspect for any instability.
- Do not run a Desktop-OS setup script on a RetroPie card, or this one on any other kind of card.

## License

MIT
