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

## Running the lab on demand (recommended on a 16 GB PC)

The full cluster needs ~4.5 GB of process memory plus file cache, so it should not start every time WSL does. On the author's
16 GB desktop Docker is **disabled at boot** and the lab is started and stopped explicitly:

```powershell
powershell -ExecutionPolicy Bypass -File setup\lab-start.ps1             # ~1 minute: Docker, then nodes in a fixed order, then checks the app
powershell -ExecutionPolicy Bypass -File setup\lab-start.ps1 -Recover    # emergency path after a crash/overload (shrinks workloads first)
powershell -ExecutionPolicy Bypass -File setup\lab-stop.ps1              # graceful stop + shuts the WSL VM so Windows gets its RAM back
```
Measured on a 16 GB Dell desktop (i5-12400): cold start about 1 minute, stop about 30 seconds, and with `memory=6GB`
Windows keeps ~2.7 GB free while the full stack runs (with `memory=7GB` it was only 0.6-0.9 GB, because Linux filled the cap with file cache).

`setup\wslconfig.example` shows the matching `%UserProfile%\.wslconfig`. To make Docker on-demand once:
`wsl -u root -- systemctl disable docker.socket docker.service`. After a RAM upgrade raise `memory`/`processors`.

Things that bit us (and are handled by the scripts):
* **WSL stops itself about 15 s after the last terminal closes**, killing the whole cluster. Fixed by `instanceIdleTimeout=-1` in `.wslconfig`.
* **Starting both k3d workers at once** can make one shut itself down ("failed to find interface with specified node ip"), and the
  k3d load balancer then crash-loops, so the API is unreachable from the host. `ops/lab-up.sh` starts server, worker 0, worker 1,
  then the load balancer, one at a time, with retries.
* **A saved state that is too big for the RAM** (e.g. an autoscaler run-away) overloads the machine at start. `lab-stop.ps1` resets
  replica counts before stopping; if it still happens use `-Recover`, which shrinks the workloads through
  `docker exec k3d-scale-server-0 kubectl` (the host API is not reachable until the workers are up).
* The autoscaler maximum is 5 backends: more than that does not fit in 16 GB with the HA data tier.
## Notes
* The Windows scripts were dry-run on Windows 11 + WSL2. The macOS scripts have been syntax-checked and dry-run off a Mac,
  but **never executed on real macOS**: expect to fix small things.
* The cluster name is fixed to `scale` (the deploy script depends on it).
* Deleting the cluster deletes its data (Postgres, Kafka, object store). Keep a copy first with `ops/offsite-backup.sh`.
