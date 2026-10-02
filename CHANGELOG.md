# Changelog

All notable changes to Phoenix are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [SemVer](https://semver.org/).

## [1.2] - 2026-10-02

### Added

- **Static IP & DNS** module (`win_netip`): manual IPv4/IPv6 addresses and prefixes, default gateways, DNS servers and connection-specific suffix per physical adapter. DHCP-configured families are recorded but never changed on restore; DNS is only restored when it was set by hand (registry `NameServer`). Adapters matched by MAC, then driver description. Full dry-run support.
- **Compare backups**: new **Compare** button on the Restore tab diffs the open backup against any other one on three levels — module status/size/note from the manifests, files via `checksums.sha256` grouped per module (encrypted vault excluded), and the package/extension/env lists themselves (winget, installed programs, VS Code/Insiders/Cursor extensions, npm, pip, cargo, dotnet, PowerShell modules, env vars, PATH entries). Writes `compare.txt` into the newer backup.
- **Changes since last backup**: every backup now ends by comparing itself with the previous backup in the same destination and adds a summary row to the report. Mirror updates snapshot the old manifest, checksums and list files first so the diff still works after the folder is overwritten.
- **Portable `Phoenix.exe`** built by `Build-Exe.ps1` with the C# compiler that ships in the .NET Framework (nothing to install). Native, no console window, DPI-aware, embeds `Phoenix.ps1` and extracts it to `%LOCALAPPDATA%\Phoenix\app\<hash>\`; all arguments are forwarded, and `-Headless` reuses the caller's console. The binary is published on Releases, not committed.

### Changed

- Relaunch-as-admin and the **Schedule** task now target whatever launched Phoenix (`Phoenix.exe` or `Phoenix.cmd`) via `PHOENIX_EXE`.
- `compare.txt` is excluded from checksums alongside the other metadata files.
- Report overlay gained a *changed* state (used by Compare) with its own summary line.
- Module count 36 → 37.

## [1.1] - 2026-10-02

### Added

- `checksums.sha256` written per backup; **Verify** re-hashes every file and checks the vault tag.
- `phoenix.log` saved inside the backup folder.
- Restore **Dry run** — diff of what would be installed, overwritten or skipped on this PC.
- Per-item end-of-restore **report** (done / skipped / needs manual action).
- **Scheduled backups** — creates a Windows task that runs Phoenix headless and mirror-updates the existing backup. Encrypted runs read the password from `PHOENIX_VAULT_PASSWORD`.
- Modules: browser bookmarks (Chrome, Edge, Brave, Vivaldi, Firefox), full browser profiles 🔒, WSL full export/import (`wsl --export`), network adapter driver settings, installed-programs inventory, PuTTY sessions 🔒, custom user folders.
- Per-app AppData picker with live sizes.
- Restore of pip packages and PowerShell modules alongside npm / cargo / dotnet.
- Windows Terminal unpackaged install support; user fonts are now registered, not just copied.
- `Phoenix.cmd` forwards arguments to the script (`Phoenix.cmd -Headless -Dest D:\Backups -Preset Developer -Update`), propagates the exit code, and skips the pause in headless runs.

### Changed

- Vault format `PHX2`: key derivation moved from PBKDF2-SHA1 to **PBKDF2-SHA256** (200k iterations) and an **HMAC-SHA256** tag (encrypt-then-MAC) now detects a wrong password or corrupted file before decryption. v1.0 vaults still open.
- Module count 28 → 36.
- README rewritten for the above.

## [1.0] - 2026-09-28

### Added

- Initial release: single-file PowerShell 5.1 + WPF backup/restore GUI.
- ~28 modules across Applications, Developer environment, Windows settings, App settings, User folders.
- Minimal / Developer / Everything presets.
- AES-256-CBC encrypted vault for sensitive items (SSH keys, Wi-Fi passwords, PuTTY, Git credentials).
- Smart mode AppData copy (caches excluded) via `robocopy`.
- `manifest.json` per backup; System Restore Point before restore.
- Background runspace worker with live log + progress.

[1.2]: https://github.com/abdellaziz-ali/Phoenix/compare/v1.1...v1.2
[1.1]: https://github.com/abdellaziz-ali/Phoenix/compare/v1.0...v1.1
[1.0]: https://github.com/abdellaziz-ali/Phoenix/releases/tag/v1.0
