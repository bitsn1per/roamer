# Changelog

All notable changes. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow `VERSION` in `roaming-setup.sh`.

## [Unreleased]

### Added

- `stack.yaml`, listing the ids from the [tech-stack](https://github.com/bitsn1per/tech-stack)
  catalog that this repo uses to build, test and run.

## [8.5] — 2026-10-21

### Fixed
- **Working Wi-Fi was rolled back as "did not start"** (empty reason, after the full 90 s). The check
  after applying trusted only `iwinfo <if> info` saying `Mode: Master`; when that CLI is missing or
  words it differently (OpenWrt 25.12), a running Wi-Fi looked dead. It now asks hostapd itself
  (`ubus call hostapd.<if> get_status` → `ENABLED`), then `iw`, then `iwinfo`; if netifd's status
  doesn't name the interface, hostapd's enabled networks with the roaming SSID count.
- A failed Wi-Fi check always says what it saw per network (interface, hostapd / iw / iwinfo state)
  instead of an empty `hostapd:`.

### Added
- The version is shown in every screen's header (`ROAMER v8.5 · …`), including the home menu.

## [8.4] — 2026-10-21

### Fixed
- **The running hostapd wasn't found** (`pidof hostapd` returns nothing for the jailed hostapd on
  OpenWrt 25.12), so an old running hostapd — without 802.11v, while the installed one has it — went
  unnoticed. Running hostapd/wpad processes are now found through `/proc/*/exe`.
- When hostapd refuses 802.11v and the installed hostapd can do it, Roamer restarts `wpad` and retries
  **with** 802.11v. Only if it is still refused does 802.11v go — then from **every** network on the
  radio (they share one hostapd config, so a leftover on another network kept the radio down), and
  the run lists which networks changed.

## [8.3] — 2026-10-21

### Fixed
- **The 802.11v fallback didn't work**: OpenWrt 25.12's wifi scripts pass `bss_transition` to hostapd
  whenever the option is *set*, also as `0`, and a hostapd without 802.11v rejects the key itself.
  The fallback now removes the option, so Wi-Fi comes up (802.11r/k still on).
- The failure reason contained old log lines (an earlier run's message): only hostapd's own lines
  since this run are used now.
- A hostapd refusal is seen within seconds instead of after the full 90 s wait.

### Added
- Roamer asks the binaries instead of package names: the config parser of a hostapd with 802.11v
  contains the literal `bss_transition`. If the installed hostapd has it but the *running* one
  (`/proc/<pid>/exe`) doesn't, `wpad` is restarted before applying. When 802.11v ends up off, the
  run says which packages and binaries it found; `diag` shows the same.

## [8.2] — 2026-10-21

### Fixed
- **Wi-Fi still refused after installing the full wpad**: replacing a wpad package doesn't restart
  the running hostapd, which keeps executing the old (basic) binary and still rejects
  `bss_transition`. Roamer now spots a hostapd running a replaced binary and restarts `wpad` before
  applying, double-checks `/usr/sbin/hostapd` is a full build, and if hostapd still refuses 802.11v
  it retries with 802.11v off and tells you, instead of rolling back.
- The computer's report shows why a Gateway run failed.

### Added
- **`roamer-data/`**: every file a run keeps, in one folder per router, `<Role>_<hostname>/` with
  `backups/`, `logs/`, `recovery/`, `lantest/` and the Gateway's `pairing.txt`; `hosts.txt` at the
  top. Git-ignored. `ROAMER_DATA` moves it. Files from ≤ 8.1 are still read.

## [8.1] — 2026-10-21

### Fixed
- **Wi-Fi gone after a run on a router with `wpad-basic-*`.** With apk, `wpad-basic-*` *provides*
  the virtual names `hostapd` and `wpa-supplicant`, so `apk info -e hostapd` succeeded and Roamer
  thought a full hostapd was installed. It skipped the swap and enabled 802.11v (`bss_transition`),
  which basic hostapd is compiled without — hostapd then rejects the whole AP config. Package checks
  now match exact installed package names, and after the swap `wpad` is restarted.
- `bss_transition` is set only when a full hostapd is really installed.
- Channel lists are written as `channels` (read by both the shell and the ucode wifi-scripts;
  `chanlist` was ignored by the shell variant).

### Added
- **Wi-Fi check after applying**: every roaming network must actually broadcast within 90 s
  (160 s with DFS channels). If not, the Gateway rolls its Wi-Fi back and a Dumb AP rolls back
  completely; the reason from the hostapd log is shown. `WIFI_WAIT=<s>` overrides the wait.
- `diag` shows the installed wpad, hostapd features, radio/interface state and recent hostapd
  log lines; the report shows `802.11r/k/v` only when 802.11v is really on.

## [8.0] — 2026-10-17

First public release.

### Added
- **Home menu** on the computer and on the router: setup, lantest, report, state, status, diag,
  pair, confirm, undo, help. Every entry also works as a command (`./roaming-setup.sh lantest`).
- `undo`: restore the snapshot taken before the last run (on the router or from the computer).
- Test suite with OpenWrt stand-ins, run in an Alpine container under busybox ash; CI with
  ShellCheck.

### Changed
- Presets, including the Wi-Fi password, travel to the router in a temporary 0600 file instead of
  on the SSH command line (where `ps` could show them).
- The check for other uncommitted UCI changes runs before any package is installed.
- Unattended runs stop when the router can't be reached, instead of retrying forever.
- Pairing codes (they hold the Wi-Fi password) are hidden in log files.
- Confirmation deadlines on both sides are measured by the clock, not by counting sleeps (on a
  slow router the rollback used to come later than announced).

### Fixed
- Background probes no longer read keyboard input; `roaming-hosts.txt` lookups match exactly.

## [7.5] — 2026-10-17
### Fixed
- **Root cause of "a laptop on a Dumb AP's LAN port has internet but can't reach the Dumb AP"**:
  WAN was a member of the LAN bridge (bridged by v4 and never removed). On routers whose WAN and LAN
  ports use different CPU links, the router's own replies to LAN ports got lost. The switch-over now
  always takes WAN out of the bridge; the wiring check reports a bridged WAN.
- `lantest`: the Gateway login comes first and has no time limit (an 8 s timeout used to kill the
  password prompt); backup before any change; the reboot step verifies the reboot; a fix counts only
  after two ping rounds plus SSH.
### Added
- `lantest` detects a bridged WAN and fixes it with auto-revert and confirmation over the cable.

## [7.4]
### Added
- `lantest`; "go through the Gateway" when a router isn't reachable directly.
### Changed
- No more LAN-port leave/re-join ("bounce") during the switch-over.

## [7.3]
### Added
- IPv6 link-local access to a Dumb AP (found automatically); recovery address in static mode;
  `diag`; Tailscale accept-routes check; `roaming-hosts.txt`.
### Fixed
- Hostname is applied immediately; the board's LAN MAC is kept.

## [7.2]
### Fixed
- False confirmation through a shared SSH session to the old address; self-check failing while a
  cable was being moved; the router's own address reported as "in use".
### Added
- Temporary WAN path until confirmation; Report screen; mobility-domain do's and don'ts.

## [7.1]
### Added
- Progress bar with chapters; wiring diagnostics with retry; the computer confirms the Dumb AP.

## [7.0]
### Added
- Device info, package bundles, welcome screen, styled screens, measured wiring check; no
  device-specific code.

## [6.x] and earlier
- Interactive Gateway/Dumb AP setup, pairing code, backups, logs, recovery card, auto-rollback.
