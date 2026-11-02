# Roamer

[![CI](https://github.com/bitsn1per/roamer/actions/workflows/ci.yml/badge.svg)](https://github.com/bitsn1per/roamer/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![OpenWrt 24.10 | 25.12](https://img.shields.io/badge/OpenWrt-24.10%20%7C%2025.12-00B5E2)

> This is a fork of [backfield79/roamer](https://github.com/backfield79/roamer).

**One Wi-Fi network across all your OpenWrt routers.** Roamer sets up 802.11r fast transition,
802.11k/v and [usteer](https://openwrt.org/docs/guide-user/network/wifi/usteer) client steering on
your main router (the **Gateway**) and turns any number of extra routers into **Dumb APs** that
join the Gateway's LAN with the same Wi-Fi: interactively, one screen per step, with backups,
a recovery card and automatic rollback.

```
        Internet
           │
   ┌───────┴───────┐   LAN cable    ┌───────────────┐
   │   Gateway     ├────────────────┤   Dumb AP     │   … more Dumb APs
   │ DHCP · NAT    │                │ bridge only   │
   │ Wi-Fi  ch A   │                │ Wi-Fi  ch B   │
   └───────────────┘                └───────────────┘
       same SSID · same password · same mobility domain → seamless roaming
```

One POSIX shell script, no dependencies on your computer beyond `ssh`. Port names, the failsafe
port and the router's internal switch layout are read from each router, so no device model is
assumed.

## Quick start

```sh
git clone https://github.com/bitsn1per/roamer.git && cd roamer
./roaming-setup.sh
```

1. With your computer on the Gateway, choose **Set up a router** and enter the Gateway's IP. Only its
   Wi-Fi is changed; a pairing code is saved in `roamer-data/`.
2. Cable a Dumb AP to the Gateway (its WAN or a LAN port) and run `./roaming-setup.sh` again for it.
   The pairing code fills in SSID, password, encryption and mobility domain; the computer waits for
   the Dumb AP on its new address and confirms it.

Every run ends with a **Report**: what is set up on the router, and which files were saved.

## The home menu

| Choice | What it does |
|---|---|
| **setup** | set up a router as the Gateway or a Dumb AP |
| **lantest** | computer cabled to a Dumb AP that doesn't answer: measures from inside, names the cause, fixes it (with backup and auto-revert) |
| **report** | what is set up on a router |
| **state** / **status** | where a Dumb AP switch-over stands / its log |
| **diag** | what a Dumb AP's LAN ports and bridge see |
| **pair** | show the Gateway's pairing code again |
| **confirm** | confirm a Dumb AP switch-over by hand |
| **undo** | restore a router to how it was before the last Roamer run |

Each also runs directly: `./roaming-setup.sh lantest`. The same menu (minus `lantest`) appears when
you run the script on a router itself.

## Safety

- **Backup first**: a full `sysupgrade` backup of the router into your folder, plus a snapshot and
  `restore.sh` on the router.
- **Nothing changes before you approve the plan**. Only Roamer's own UCI packages are committed;
  it refuses to run over other people's uncommitted changes.
- **Gateway**: if internet is lost after applying, the change rolls back by itself.
- **Dumb AP**: confirmed only when the Gateway answers through its LAN ports *and* you log in on the
  new address (your computer does it for you); otherwise it **rolls back** after 300 s. A Gateway
  cable that started in WAN keeps a temporary way in until then.
- A recovery card (`recovery/<time>_RECOVERY.txt`) explains every way back, down to failsafe.

## What a run leaves on your computer

Everything goes into `roamer-data/` in the folder you run from (git-ignored, mode 600), one folder
per router:

```
roamer-data/
├── Gateway_main-router/
│   ├── backups/20261021-090438_192.168.1.1_backup.tar.gz
│   ├── logs/20261021-090438.ok.log
│   └── pairing.txt                      ← pairing code (holds the Wi-Fi password)
├── DumbAP_hall/
│   ├── backups/…   logs/…
│   ├── recovery/20261021-091502_RECOVERY.txt
│   └── lantest/20261021-093010.txt
└── hosts.txt                            ← known Dumb APs (address, hostname, link-local)
```

A router's folder is named after its role and hostname *after* the run (a renamed Dumb AP moves
along). `ROAMER_DATA=/some/path` puts the tree elsewhere.

## Documentation

- [How it works](docs/how-it-works.md): roles, what is changed, channels, mobility domain, packages
- [Wiring](docs/wiring.md): which cabling works, and reaching a Dumb AP with a laptop
- [Troubleshooting](docs/troubleshooting.md): `lantest`, `diag`, the usteer page, recovery
- [Unattended use](docs/unattended.md): every prompt as a variable, sub-commands
- [Image build](image-build/README.md): bake the packages into a firmware image
- [Changelog](CHANGELOG.md)

## Requirements

- Routers: OpenWrt 24.10 or 25.12 (apk or opkg), a 2.4 and/or 5 GHz radio, SSH as root. Missing
  packages (full `wpad`, `usteer`, …) are installed when needed.
- Computer: any Unix-like system with `ssh` (Linux, macOS, WSL). Or copy the script to the router
  and run it there.

## Contributing

Bug reports with real hardware are the most valuable thing; see [CONTRIBUTING.md](CONTRIBUTING.md).
Security issues: [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
