#!/usr/bin/env bash
# Removes Scale App from macOS, in layers. By default only the app (the k3d cluster and the images built for it).
#
#   bash setup/cleanup-macos.sh [options]
#
#   (default)         delete the k3d cluster "scale" (ALL its data: Postgres, Kafka, in-cluster backups) and the
#                     scale-backend / scale-web Docker images
#   --include-backups also delete the off-cluster backup copy (~/scale-app-offsite-backups)
#   --remove-tools    also uninstall the Homebrew packages / Colima VM that install-macos.sh added (recorded in
#                     ~/.scale-app-setup-state). Anything you had installed before is left alone.
#   --force           with --remove-tools: also remove k3d/kubectl/colima/docker that the installer did NOT add
#   --yes             do not ask for confirmation
#   --dry-run         show what would be removed, change nothing
#   -h, --help        this text
# Homebrew itself is never uninstalled.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-macos.sh
. "$SCRIPT_DIR/lib-macos.sh"

INCLUDE_BACKUPS=0; REMOVE_TOOLS=0; FORCE=0; ASSUME_YES=0; DRY_RUN=0
usage() { sed -n '2,/^set -eu/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --include-backups) INCLUDE_BACKUPS=1; shift ;;
    --remove-tools) REMOVE_TOOLS=1; shift ;;
    --force) FORCE=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done
[ "$DRY_RUN" = 1 ] && printf '%sDRY RUN: nothing will be changed.%s\n' "$C_PLAN" "$C_OFF"
BACKUP_DIR="${SCALE_OFFSITE_DIR:-$HOME/scale-app-offsite-backups}"

step "What this will do"
echo "    - delete the k3d cluster 'scale' and ALL data in it (Postgres, Kafka, in-cluster backups)"
echo "    - delete the scale-backend and scale-web Docker images"
[ "$INCLUDE_BACKUPS" = 1 ] && echo "    - delete the off-cluster backup copy at $BACKUP_DIR"
[ "$REMOVE_TOOLS" = 1 ] && echo "    - uninstall the tools the installer added$([ "$FORCE" = 1 ] && echo ' (and, with --force, ones it did not)')"
confirm "Continue?" || { echo "Aborted."; exit 0; }

load_brew || true

# ---------------------------------------------------------------- app
step "Removing the cluster and images"
if docker_ready; then
  if cluster_exists scale; then run k3d cluster delete scale; done_ok "cluster deleted"; state_remove CLUSTER_CREATED scale
  else skip "no cluster named scale"; fi
  for img in scale-backend:1.0 scale-web:1.0; do
    if docker image inspect "$img" >/dev/null 2>&1; then run_quiet docker rmi -f "$img"; done_ok "removed image $img"
    else skip "image $img not present"; fi
  done
else
  warn "Docker is not running, so the cluster and images cannot be removed now. Start Docker (e.g. 'colima start') and re-run."
fi

if [ "$INCLUDE_BACKUPS" = 1 ]; then
  step "Removing the off-cluster backup copy"
  if [ -d "$BACKUP_DIR" ]; then run rm -rf -- "$BACKUP_DIR"; done_ok "removed $BACKUP_DIR"; else skip "no backup copy at $BACKUP_DIR"; fi
fi

# ---------------------------------------------------------------- tools
if [ "$REMOVE_TOOLS" = 1 ]; then
  step "Removing tools the installer added"
  if ! command -v brew >/dev/null 2>&1; then
    warn "Homebrew not found; nothing to uninstall."
  else
    # Colima's VM holds the images/volumes: stop and delete it first (only if we started it, or --force).
    if command -v colima >/dev/null 2>&1; then
      if state_has COLIMA_STARTED 1 || [ "$FORCE" = 1 ]; then
        run_quiet colima stop || true
        run_quiet colima delete --force || true
        done_ok "Colima VM stopped and deleted"; state_remove COLIMA_STARTED 1
      else skip "Colima VM was not started by the installer"; fi
    fi
    for p in k3d kubectl colima docker coreutils gnu-sed; do
      if state_has BREW_FORMULA "$p" || { [ "$FORCE" = 1 ] && brew list --formula "$p" >/dev/null 2>&1; }; then
        run brew uninstall --formula "$p"; done_ok "uninstalled $p"; state_remove BREW_FORMULA "$p"
      else skip "$p (not added by the installer, or absent)"; fi
    done
    if state_has BREW_CASK docker; then run brew uninstall --cask docker; done_ok "uninstalled Docker Desktop"; state_remove BREW_CASK docker; fi
  fi
fi

[ "$DRY_RUN" = 1 ] || { [ -f "$STATE_FILE" ] && [ ! -s "$STATE_FILE" ] && rm -f "$STATE_FILE"; true; }
step "Done"
echo "    Not touched: Homebrew, and this repository folder."
