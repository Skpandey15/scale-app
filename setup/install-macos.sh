#!/usr/bin/env bash
# Installs everything needed to run Scale App on macOS and deploys it to a local k3d cluster.
#
#   bash setup/install-macos.sh [options]
#
# Installs (via Homebrew, only what is missing): k3d, kubectl, GNU coreutils + sed (for the drill scripts) and a container
# runtime: Colima (default, fully scriptable) or Docker Desktop. Creates the k3d cluster "scale" (1 server + 2 agents) and runs
# ops/deploy.sh. Safe to re-run. Records what it added in ~/.scale-app-setup-state so cleanup-macos.sh removes only that.
#
# Options:
#   --runtime colima|docker-desktop|existing   container runtime (default: colima; "existing" = use whatever Docker is running)
#   --memory GB     RAM for the Colima VM            (default: 10 on >=16 GB Macs, otherwise total-4, minimum 6)
#   --cpus N        CPUs for the Colima VM           (default: 6 on >=8 core Macs, else 4)
#   --disk GB       disk for the Colima VM           (default: 60)
#   --port N        host port for the app            (default: 8088)
#   --skip-deploy   install tooling and create the cluster, but do not deploy the app
#   --install-homebrew   install Homebrew if missing (otherwise the script stops and tells you how)
#   --force         continue even if the Mac has less than 12 GB RAM
#   --yes           do not ask for confirmation
#   --dry-run       show what would happen, change nothing
#   -h, --help      this text
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib-macos.sh
. "$SCRIPT_DIR/lib-macos.sh"

RUNTIME=colima; MEMORY_GB=""; CPUS=""; DISK_GB=60; PORT=8088
SKIP_DEPLOY=0; INSTALL_BREW=0; FORCE=0; ASSUME_YES=0; DRY_RUN=0

usage() { sed -n '2,/^set -eu/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# A function (not an inline $(curl ...)) so that --dry-run does not download anything.
install_homebrew() { /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --runtime) RUNTIME="${2:-}"; shift 2 ;;
    --memory) MEMORY_GB="${2:-}"; shift 2 ;;
    --cpus) CPUS="${2:-}"; shift 2 ;;
    --disk) DISK_GB="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --skip-deploy) SKIP_DEPLOY=1; shift ;;
    --install-homebrew) INSTALL_BREW=1; shift ;;
    --force) FORCE=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done
case "$RUNTIME" in colima|docker-desktop|existing) ;; *) die "--runtime must be colima, docker-desktop or existing" ;; esac
[ "$DRY_RUN" = 1 ] && printf '%sDRY RUN: nothing will be changed.%s\n' "$C_PLAN" "$C_OFF"

# ------------------------------------------------------------------ 1. this Mac
step "Checking this Mac"
if [ "$(uname -s)" != "Darwin" ] && [ "${SCALE_SETUP_TEST:-0}" != "1" ]; then
  die "This installer is for macOS. On Windows use setup\\install-windows.ps1."
fi
ARCH="$(uname -m)"; MEM="$(mem_gb)"; NCPU="$(cpu_count)"; OSMAJOR="$(macos_major)"
ok "macOS $OSMAJOR, $ARCH, ${MEM} GB RAM, ${NCPU} CPUs"
if [ "$MEM" -lt 12 ] && [ "$FORCE" != 1 ]; then
  die "Only ${MEM} GB RAM. The stack needs ~8 GB for the container VM alone, so 16 GB is recommended. Use --force to try anyway."
fi
[ "$MEM" -lt 16 ] && warn "Under 16 GB RAM: expect it to be tight. Close other heavy apps."
if [ -z "$MEMORY_GB" ]; then
  if [ "$MEM" -ge 16 ]; then MEMORY_GB=10; else MEMORY_GB=$(( MEM - 4 )); [ "$MEMORY_GB" -lt 6 ] && MEMORY_GB=6; fi
fi
if [ -z "$CPUS" ]; then if [ "$NCPU" -ge 8 ]; then CPUS=6; else CPUS=4; fi; fi

# ------------------------------------------------------------------ 2. Homebrew
step "Checking Homebrew"
if load_brew; then
  skip "Homebrew present ($(brew --version | head -n 1))"
elif [ "$INSTALL_BREW" = 1 ]; then
  if confirm "Install Homebrew now (runs the official installer from brew.sh)?"; then
    run install_homebrew
    [ "$DRY_RUN" = 1 ] || load_brew || die "Homebrew installed but not found on PATH; open a new terminal and re-run."
    state_add HOMEBREW_INSTALLED 1
  else
    die "Homebrew is required."
  fi
else
  die "Homebrew is not installed. Install it from https://brew.sh (or re-run with --install-homebrew), then run this again."
fi

# ------------------------------------------------------------------ 3. packages
step "Installing tools (only what is missing)"
FORMULAE="k3d kubectl coreutils gnu-sed"
[ "$RUNTIME" = colima ] && FORMULAE="$FORMULAE colima docker"
if command -v brew >/dev/null 2>&1; then
  for p in $FORMULAE; do
    if brew list --formula "$p" >/dev/null 2>&1; then skip "$p already installed"
    else run brew install "$p"; state_add BREW_FORMULA "$p"; done_ok "$p installed"; fi
  done
  if [ "$RUNTIME" = docker-desktop ]; then
    if brew list --cask docker >/dev/null 2>&1 || [ -d /Applications/Docker.app ]; then skip "Docker Desktop already installed"
    else run brew install --cask docker; state_add BREW_CASK docker; done_ok "Docker Desktop installed"; fi
  fi
else
  plan "brew install $FORMULAE (Homebrew would be installed first)"
fi

# ------------------------------------------------------------------ 4. container runtime
step "Container runtime ($RUNTIME)"
if docker_ready; then
  skip "a Docker daemon is already reachable (context: $(docker context show 2>/dev/null || echo default))"
else
  case "$RUNTIME" in
    colima)
      ARGS="--cpu $CPUS --memory $MEMORY_GB --disk $DISK_GB"
      if [ "$ARCH" = "arm64" ] && [ "$OSMAJOR" -ge 13 ]; then ARGS="$ARGS --vm-type vz --vz-rosetta"; fi   # Rosetta runs the amd64-only JMeter image
      # shellcheck disable=SC2086
      run colima start $ARGS
      state_add COLIMA_STARTED 1
      ;;
    docker-desktop)
      run open -a Docker
      if [ "$DRY_RUN" != 1 ]; then
        printf '    waiting for Docker Desktop (accept any first-run prompts in its window)'
        n=0; while ! docker_ready; do n=$((n + 1)); [ "$n" -gt 90 ] && { echo; die "Docker Desktop did not become ready in 3 minutes. Open it, finish its setup, then re-run."; }; printf '.'; sleep 2; done
        echo
      fi
      ;;
    existing) die "--runtime existing, but no Docker daemon is reachable. Start Docker first." ;;
  esac
fi
if docker_ready; then
  have=$(( $(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0) / 1073741824 ))
  ok "Docker has ${have} GB of memory"
  if [ "$have" -lt 7 ]; then
    warn "Docker has under 8 GB: the stack will likely not fit. Colima: 'colima stop && colima start --memory 10'. Docker Desktop: Settings > Resources > Memory."
  fi
fi

# ------------------------------------------------------------------ 5. cluster
step "k3d cluster 'scale'"
if cluster_exists scale; then
  skip "cluster 'scale' exists"; run_quiet k3d cluster start scale || true
else
  if command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    die "Port $PORT is already in use. Re-run with --port <other>."
  fi
  run k3d cluster create scale --servers 1 --agents 2 -p "$PORT:80@loadbalancer" --wait
  state_add CLUSTER_CREATED scale
  done_ok "cluster created"
fi

# ------------------------------------------------------------------ 6. deploy
if [ "$SKIP_DEPLOY" = 1 ]; then
  step "Skipping the deploy (--skip-deploy)"
else
  step "Deploying the app (first run builds images and pulls ~4 GB: 10-20 minutes)"
  if [ "$DRY_RUN" = 1 ]; then plan "cd $REPO_ROOT && bash ops/deploy.sh"
  else ( cd "$REPO_ROOT" && bash ops/deploy.sh ) || die "Deploy failed. It is safe to re-run this script: finished steps are skipped."; fi
fi

if [ "$DRY_RUN" = 1 ]; then step "Dry run complete (nothing was changed)"; else step "Done"; fi
echo "    App:       http://localhost:$PORT"
echo "    Kafka UI:  http://localhost:$PORT/kafka-ui   (user: admin)"
echo "    Password:  kubectl -n scale get secret kafka-ui-auth -o jsonpath='{.data.password}' | base64 --decode; echo"
echo "    Drills:    source setup/macos-gnu-path.sh   (GNU date/sed first on PATH), then e.g. bash ops/ha-drill.sh all"
echo "    Remove it: bash setup/cleanup-macos.sh --dry-run   (preview), then without --dry-run"
