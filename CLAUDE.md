# roamer

## Commands

- Test: `sh tests/run.sh`. It needs Podman or Docker, and runs mocked scenarios under busybox ash.
- Lint: `shellcheck -s sh roaming-setup.sh`

## Gotchas

- `roaming-setup.sh` runs on the router under busybox ash, with only default OpenWrt packages, so no bash-isms.
- Every prompt must be presettable by a variable, and wrong input must be asked again, never crash.
- Files in `roamer-data/` contain Wi-Fi passwords and pairing codes. Never commit or quote them.
- Mocks can't prove networking changes. Say so when a change hasn't run on real hardware.
