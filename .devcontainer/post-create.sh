#!/usr/bin/env bash
# .devcontainer/post-create.sh
# Runs once after the container is created (postCreateCommand).
# Installs tools that have no devcontainer feature.
set -euo pipefail

# ─── Colour helpers ──────────────────────────────────────────────────────────
info()  { printf '\033[0;34m[devcontainer] %s\033[0m\n' "$*"; }
ok()    { printf '\033[0;32m[devcontainer] %s\033[0m\n' "$*"; }
error() { printf '\033[0;31m[devcontainer] %s\033[0m\n' "$*" >&2; }

# Use sudo only when not already root (so the script works in a Dockerfile RUN
# executed as root as well as inside a devcontainer running as a non-root user).
_sudo() { if [[ "$(id -u)" == "0" ]]; then "$@"; else sudo "$@"; fi; }

# ─── talosctl ────────────────────────────────────────────────────────────────
info "Installing talosctl…"

TALOS_VERSION="$(curl -sSfL https://api.github.com/repos/siderolabs/talos/releases/latest \
  | grep '"tag_name"' | sed 's/.*"\(v[^"]*\)".*/\1/')"

if [[ -z "${TALOS_VERSION}" ]]; then
  error "Could not resolve latest Talos version from GitHub API"
  exit 1
fi

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64)  GA=amd64 ;;
  aarch64) GA=arm64 ;;
  *)
    error "Unsupported architecture: ${ARCH}"
    exit 1
    ;;
esac

curl -sSfL \
  "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talosctl-linux-${GA}" \
  -o /tmp/talosctl
_sudo install -m 0755 /tmp/talosctl /usr/local/bin/talosctl
rm /tmp/talosctl

talosctl version --client
ok "talosctl ${TALOS_VERSION} installed"

# ─── yamllint ────────────────────────────────────────────────────────────────
info "Installing yamllint…"
if ! command -v yamllint >/dev/null 2>&1; then
  # apt-get lists may have been cleared; refresh before installing.
  _sudo apt-get update -qq && _sudo apt-get install -y --no-install-recommends yamllint 2>/dev/null \
    || { command -v pip3 >/dev/null 2>&1 && pip3 install --user yamllint; } \
    || { error "yamllint not installed; run: pip3 install yamllint"; }
fi
yamllint --version
ok "yamllint installed"

# ─── Verify all required tools are present ───────────────────────────────────
info "Verifying tool availability…"

MISSING=()
for tool in helm kubectl gh talosctl jq curl yamllint docker; do
  if command -v "${tool}" >/dev/null 2>&1; then
    printf '  %-12s %s\n' "${tool}" "$(${tool} version --short 2>/dev/null \
      || ${tool} --version 2>/dev/null \
      || echo "(found)")"
  else
    MISSING+=("${tool}")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  error "The following tools were not found: ${MISSING[*]}"
  exit 1
fi

ok "All tools verified. Dev environment is ready."
echo ""
echo "  Quick reference:"
echo "    helm lint .                   # lint the Helm chart"
echo "    helm template . | yamllint -  # render + lint templates"
echo "    docker build -t luks-trim .   # build the worker image"
echo "    make gha-watch                # watch the latest GHA run"
echo "    gh auth login                 # authenticate gh CLI (first time)"
