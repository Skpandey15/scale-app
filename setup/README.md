# Setup scripts

One installer and one cleanup script per platform. Both installers are **idempotent** (safe to re-run; finished steps are
skipped) and both cleanups support a **dry run** so you can preview before anything is deleted.

| | Windows 10/11 | macOS |
|---|---|---|
| Install + deploy | `setup\install-windows.ps1` | `setup/install-macos.sh` |
| Remove | `setup\cleanup-windows.ps1` | `setup/cleanup-macos.sh` |
| Container runtime | Docker Engine inside WSL2 (Ubuntu 24.04), no Docker Desktop | Colima (default) or Docker Desktop |

After either installer finishes: **http://localhost:8088** (app) and **http://localhost:8088/kafka-ui** (user `admin`).

## Windows

```powershell
# from the repo root, in a normal (non-admin) PowerShell:
powershell -ExecutionPolicy Bypass -File setup\install-windows.ps1 -DryRun     # preview
powershell -ExecutionPolicy Bypass -File setup\install-windows.ps1             # do it
```
* If WSL itself is missing, the script tells you to run `wsl --install --no-distribution` in an **Administrator** PowerShell and reboot, then run it again. Everything after that needs no admin rights.
* It creates Ubuntu 24.04 if absent (with a Linux user named after your Windows user), enables systemd, installs Docker Engine + k3d + kubectl **inside WSL**, creates the cluster and runs `ops/deploy.sh`.
* Options: `-Port 8088`, `-WslMemoryGB 10` (writes `.wslconfig`, backs up the old one, restarts WSL), `-SkipDeploy`, `-Yes`, `-DryRun`.
* Needs ~8 GB for WSL; 16 GB RAM total recommended. First deploy: 10-20 min.

Cleanup layers (each adds to the previous):
```powershell
powershell -ExecutionPolicy Bypass -File setup\cleanup-windows.ps1 -DryRun            # preview
powershell -ExecutionPolicy Bypass -File setup\cleanup-windows.ps1                    # cluster + app images only
powershell -ExecutionPolicy Bypass -File setup\cleanup-windows.ps1 -RemoveBackups     # + off-cluster backup copy
powershell -ExecutionPolicy Bypass -File setup\cleanup-windows.ps1 -RemoveTools       # + Docker Engine / k3d / kubectl the installer added
powershell -ExecutionPolicy Bypass -File setup\cleanup-windows.ps1 -RemoveWsl         # + unregister the Ubuntu distro (deletes everything in it)
```
Only things the installer itself added are removed (it records them); `-Force` overrides that. WSL and the Windows features are never uninstalled.

## macOS

```bash
bash setup/install-macos.sh --dry-run                 # preview
bash setup/install-macos.sh                           # Colima + k3d + kubectl, then deploy
bash setup/install-macos.sh --runtime docker-desktop  # use Docker Desktop instead
```
* Needs Homebrew (`--install-homebrew` installs it for you). Installs only missing packages: `k3d kubectl coreutils gnu-sed` plus `colima docker` (or the Docker Desktop cask).
* Sizes the Colima VM to your Mac (`--memory`, `--cpus`, `--disk` override). Refuses under 12 GB RAM unless `--force`.
* For the `ops/` drill scripts, run `source setup/macos-gnu-path.sh` first so GNU `date`/`sed` are used.
* Options: `--runtime colima|docker-desktop|existing`, `--port`, `--skip-deploy`, `--yes`, `--dry-run`.

```bash
bash setup/cleanup-macos.sh --dry-run                 # preview
bash setup/cleanup-macos.sh                           # cluster + app images only
bash setup/cleanup-macos.sh --include-backups --remove-tools   # + backup copy, + packages / Colima VM the installer added
```
Homebrew itself is never uninstalled.

## Notes
* The Windows scripts were dry-run on Windows 11 + WSL2. The macOS scripts have been syntax-checked and dry-run off a Mac,
  but **never executed on real macOS**: expect to fix small things.
* The cluster name is fixed to `scale` (the deploy script depends on it).
* Deleting the cluster deletes its data (Postgres, Kafka, object store). Keep a copy first with `ops/offsite-backup.sh`.
