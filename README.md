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

- 🎛️ **Pick exactly what to save** — ~28 modules across 5 categories with a checkbox tree and Minimal / Developer / Everything presets.
- 🔐 **AES-256 encrypted vault** (PBKDF2, 200k iterations) for sensitive items like SSH keys, Wi-Fi passwords and PuTTY sessions — everything else stays browsable.
- 🧠 **Smart mode** copies app configs but skips caches, chat history and other regenerated junk (keeps a VS Code backup at ~1 MB instead of gigabytes).
- 🧾 **`manifest.json`** records every item, its size, status and notes — restore reads it back and shows exactly what's inside.
- 🛟 **Creates a System Restore Point** before writing any Windows settings on restore.
- ♻️ **Auto-reinstalls** apps, editor extensions and language globals (npm / cargo / dotnet) on the new PC.
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
4. **Start backup.** You get a folder like `Phoenix-Backup-PCNAME-20260929-0127` containing `manifest.json` and your data.

### Restore (on the fresh install)

1. Copy the `Phoenix` folder back and run **`Phoenix.cmd`** (right-click → **Run as administrator** for a complete restore).
2. **Restore** tab → **Open backup** → select your `Phoenix-Backup-…` folder.
3. Phoenix reads the manifest and shows what's inside. Untick anything you don't want. Enter the vault password if you encrypted.
4. **Start restore.** It creates a restore point, reinstalls apps, and puts your settings and files back.

> Sign out / restart afterwards so Explorer, environment variables and Windows Terminal pick up the changes.

---

## What it captures

| Category | Modules |
| --- | --- |
| **Applications** | Installed apps (winget export/import), UniGetUI `.ubundle` |
| **Developer environment** | VS Code / Insiders / Cursor extensions · global npm packages (+ nvm/fnm) · pip freeze per Python · Rust toolchains & cargo crates · dotnet global tools · Git config · **SSH keys** 🔒 · PowerShell profile & modules · WSL distro list · user environment variables (incl. PATH) |
| **Windows settings** | **Wi‑Fi profiles + passwords** 🔒 · power plans · mapped drives · hosts file · scheduled tasks · Explorer/taskbar tweaks · Windows Terminal · printers · default app associations · user-installed fonts |
| **App settings & data** | App configs (Smart, caches skipped) · **PuTTY sessions** 🔒 |
| **User folders** | Documents · Desktop · Pictures · Downloads · Videos · Music |

🔒 = routed into the encrypted vault when **Encrypt sensitive** is on.

---

## Security

- Sensitive modules are collected, zipped and encrypted into `secure/vault.enc` using **AES-256-CBC** with a key derived from your password via **PBKDF2 (SHA-1, 200,000 iterations)**. A random salt and IV are generated per backup and stored in the file header.
- With encryption **off**, sensitive data is still saved but **in plaintext** — the app warns you in the log. On removable media, always encrypt.
- Nothing is uploaded anywhere. Phoenix has no network calls of its own; the only outbound activity is `winget` downloading your apps during restore.
- The vault password is never written to disk. If you lose it, the vault cannot be recovered.

## Administrator

Most items work as a normal user. Run **as administrator** for:

- Wi‑Fi profile import (`user=all`)
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
├─ apps/           winget-packages.json, apps.ubundle
├─ dev/            extensions, npm/pip/cargo/dotnet lists, git, env, ssh…
├─ windows/        wifi, power, hosts, tasks, terminal, explorer.reg…
├─ appdata/        per-app Smart configs
├─ userfolders/    Documents, Desktop, …
└─ secure/vault.enc  (encrypted sensitive bundle)
```

---

## Roadmap

- [ ] Optional full **WSL distro export** (`wsl --export`)
- [ ] Browser profile/bookmark capture
- [ ] Scheduled/automated backups
- [ ] Per-app AppData picker with live sizes
- [ ] Restore "dry run" diff against the current PC

## Contributing

Issues and PRs are welcome. Because it's a single script, keep changes small and test with the
built-in validation hooks (parse check + headless window build) before opening a PR.

## License

[MIT](LICENSE) © 2026 Abdelaziz Ali
