<div align="center">

# 🔥 Phoenix — Windows Migration Kit

**Back up everything that matters, wipe Windows without fear, and rise again on a fresh install.**

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-0078D6?logo=windows&logoColor=white)
![Dependencies](https://img.shields.io/badge/Dependencies-none-22C55E)
![License](https://img.shields.io/badge/License-MIT-F97316)

A single self-contained PowerShell + WPF app that captures your apps, developer environment,
Windows settings, app configs, and files — then puts them all back on a clean install.
No install, no runtime, no telemetry. Everything stays on your PC.

</div>

---

## Why

Reinstalling Windows means losing your apps, tweaks, keys, and hours of setup. Existing tools
either only restore the app list (winget/UniGetUI) *or* only sync a few settings (Microsoft
account). **Phoenix does both, plus the developer and power-user things nobody else captures** —
SSH keys, editor extensions, npm/cargo/dotnet globals, Wi-Fi passwords, power plans, PuTTY
sessions, scheduled tasks, and more — behind a clean, modern UI.

## Highlights

- 🎛️ **Pick exactly what to save** — ~35 modules across 5 categories with a checkbox tree and Minimal / Developer / Everything presets, plus a per-app AppData picker and custom folders.
- 🔐 **AES-256 encrypted vault** (PBKDF2-SHA256, 200k iterations, HMAC-SHA256 integrity) for sensitive items like SSH keys, Wi-Fi passwords, browser profiles and PuTTY sessions — everything else stays browsable.
- 🧠 **Smart mode** copies app configs but skips caches, chat history and other regenerated junk (keeps a VS Code backup at ~1 MB instead of gigabytes).
- 🧾 **`manifest.json` + `checksums.sha256` + `phoenix.log`** — every item, its size, status and hash. **Verify** re-hashes the backup any time.
- 🔍 **Dry run** — shows exactly what restore would install, overwrite or skip on *this* PC before touching anything.
- 🛟 **Creates a System Restore Point** before writing any Windows settings on restore, and ends with a per-item **report** (done / skipped / needs manual action).
- ♻️ **Auto-reinstalls** apps, editor extensions, language globals (npm / pip / cargo / dotnet / PowerShell modules) and even **WSL distros** on the new PC.
- ⏰ **Scheduled backups** — one click creates a Windows task that runs Phoenix headless and mirror-updates the existing backup.
- 🖥️ **Responsive UI** — work runs on a background runspace, so the window never freezes; live log + progress.
- 📦 **Zero dependencies** — runs on the Windows PowerShell 5.1 that ships with every Windows 10/11.

## Screenshots

> *Add screenshots of the Backup and Restore screens here (e.g. `docs/backup.png`, `docs/restore.png`).*

---

## Requirements

| | |
| --- | --- |
| **OS** | Windows 10 or 11 |
| **Runtime** | Windows PowerShell 5.1 (built in — nothing to install) |
| **Apps module** | [winget](https://learn.microsoft.com/windows/package-manager/) (App Installer) for exporting/importing apps |
| **Admin** | Optional, but needed for some Windows items (see [below](#administrator)) |

## Quick start

1. Download this repo (or copy the `Phoenix` folder) onto a **USB stick, external drive, or cloud folder** — somewhere that survives the wipe.
2. Double-click **`Phoenix.cmd`**. (It launches PowerShell in the STA mode WPF needs; you never touch a console.)

### Back up (before wiping)

1. **Backup** tab → choose a **destination** (your USB / D: / OneDrive).
2. Pick a **preset** or tick individual items. Optionally tick **Encrypt sensitive** and set a password.
3. *(Optional)* **Estimate size** to preview how big it'll be.
4. **Start backup.** You get a folder like `Phoenix-Backup-PCNAME-20260929-0127` containing `manifest.json`, `checksums.sha256`, `phoenix.log` and your data.
5. *(Optional)* **Schedule** to create a Windows task that re-runs the same selection automatically and mirror-updates that folder.

### Restore (on the fresh install)

1. Copy the `Phoenix` folder back and run **`Phoenix.cmd`** (right-click → **Run as administrator** for a complete restore).
2. **Restore** tab → **Open backup** → select your `Phoenix-Backup-…` folder.
3. Phoenix reads the manifest and shows what's inside. Untick anything you don't want. Enter the vault password if you encrypted.
4. **Verify** to make sure the backup is intact, then **Dry run** to see what would change on this PC.
5. **Start restore.** It creates a restore point, reinstalls apps, puts your settings and files back, and shows a report of anything that needs a manual step.

> Sign out / restart afterwards so Explorer, environment variables and Windows Terminal pick up the changes.

---

## What it captures

| Category | Modules |
| --- | --- |
| **Applications** | Installed apps (winget export/import) · UniGetUI `.ubundle` · full **installed-programs inventory** (Add/Remove Programs, incl. non-winget) as a reinstall checklist |
| **Developer environment** | VS Code / Insiders / Cursor extensions · global npm packages (+ nvm/fnm) · pip freeze per Python · Rust toolchains & cargo crates · dotnet global tools · Git config (credentials 🔒) · **SSH keys** 🔒 · PowerShell profile & modules · WSL distro list · **WSL full export/import** (`wsl --export`) · user environment variables (incl. PATH) |
| **Windows settings** | **Wi‑Fi profiles + passwords** 🔒 · power plans · **network adapter driver settings** (Speed & Duplex, Jumbo Packet, Wake‑on‑LAN, RSS…) · mapped drives · hosts file · scheduled tasks (with folders) · Explorer/taskbar tweaks · Windows Terminal (Store *and* unpackaged) · printers · default app associations · user-installed fonts (copied *and* registered) |
| **App settings & data** | App configs (Smart, caches skipped — pick which apps) · **browser bookmarks** (Chrome, Edge, Brave, Vivaldi, Firefox) · **full browser profiles** 🔒 · **PuTTY sessions** 🔒 |
| **User folders** | Documents · Desktop · Pictures · Downloads · Videos · Music · **any custom folders** you add (game saves, notes vault, projects…) |

🔒 = routed into the encrypted vault when **Encrypt sensitive** is on.

---

## Security

- Sensitive modules are collected, zipped and encrypted into `secure/vault.enc` using **AES-256-CBC** with keys derived from your password via **PBKDF2-SHA256 (200,000 iterations)**. An **HMAC-SHA256** tag over the ciphertext (encrypt-then-MAC) means a wrong password or a corrupted file is detected *before* anything is decrypted. A random salt and IV are generated per backup and stored in the file header (`PHX2` format; v1.0 vaults still open).
- With encryption **off**, sensitive data is still saved but **in plaintext** — the app warns you in the log. On removable media, always encrypt.
- Every file's SHA-256 is recorded in `checksums.sha256`; **Verify** re-hashes the backup and checks the vault tag.
- Nothing is uploaded anywhere. Phoenix has no network calls of its own; the only outbound activity is `winget` / `pip` / `npm` / `cargo` downloading your packages during restore.
- The vault password is never written to disk. For scheduled encrypted backups it's read from the `PHOENIX_VAULT_PASSWORD` environment variable. If you lose it, the vault cannot be recovered.

## Administrator

Most items work as a normal user. Run **as administrator** for:

- Wi‑Fi profile import (`user=all`)
- Network adapter driver settings (`Set-NetAdapterAdvancedProperty`)
- Scheduled task registration
- Default app associations export/import
- Writing the `hosts` file
- Creating the pre-restore **System Restore Point**

The title bar shows an **Administrator** badge, or a **Run as admin** button to relaunch elevated.

---

## How it works

- **One file, one window.** `Phoenix.ps1` builds a WPF UI from embedded XAML and drives everything; `Phoenix.cmd` just launches it with `-STA`.
- **Non-blocking.** Backups/restores run in a background PowerShell runspace that pushes log + progress events onto a synchronized queue; a `DispatcherTimer` drains them into the UI, so the window stays responsive.
- **Data model.** Modules are declarative metadata (id, category, sensitivity, presets). The worker maps each id to a backup/restore/estimate action, so adding a module is a small, isolated change.
- **Copies.** Folders are mirrored with `robocopy`; Smart mode adds `/XD` excludes for caches, `workspaceStorage`, `globalStorage`, `History`, and similar regenerated data.
- **Manifest.** Every backup writes `manifest.json` (tool version, machine, per-module status/size/notes, vault flag) that the Restore tab reads back.

```text
Phoenix-Backup-<PC>-<timestamp>/
├─ manifest.json
├─ checksums.sha256   SHA-256 of every file (used by Verify)
├─ phoenix.log        full log of the run
├─ apps/              winget-packages.json, apps.ubundle, installed-programs.csv
├─ dev/               extensions, npm/pip/cargo/dotnet lists, git, env, ssh, wsl/*.tar…
├─ windows/           wifi, power, netadapters.json, hosts, tasks, terminal, explorer.reg…
├─ appdata/           per-app Smart configs, browsers/bookmarks, browsers/profiles
├─ userfolders/       Documents, Desktop, …, custom/
└─ secure/vault.enc   (encrypted sensitive bundle)
```

---

## Roadmap

- [x] Full **WSL distro export** (`wsl --export`)
- [x] Browser profile/bookmark capture
- [x] Scheduled/automated backups
- [x] Per-app AppData picker with live sizes + custom folders
- [x] Restore "dry run" diff against the current PC
- [x] Backup verification (checksums + vault integrity)
- [x] Network adapter driver settings
- [ ] Static IP / DNS configuration per adapter
- [ ] Compare two backups (what changed since last run)
- [ ] Portable single `.exe` wrapper

## Contributing

Issues and PRs are welcome. Because it's a single script, keep changes small and test with the
built-in validation hooks (parse check + headless window build) before opening a PR.

## License

[MIT](LICENSE) © 2026 Abdelaziz Ali
