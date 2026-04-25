#!/usr/bin/env bash
# =============================================================================
# ldpb.sh
# Linux Developer Platform Bootstrap
#
# Stage 1 (this script): verify OS, detect user, install Ansible, fetch the
#                         playbook from GitHub, hand off to Ansible.
# Stage 2 (the playbook): declare and enforce the full system state.
#
# Philosophy: bash is the ignition key. Ansible is the engine.
#
# Repository : https://github.com/Korplin/ldpb
# Target OS  : Debian 13 "trixie" amd64
#
# Usage:
#   wget -O bootstrap.sh \
#     https://raw.githubusercontent.com/Korplin/ldpb/main/ldpb.sh
#   bash bootstrap.sh
# =============================================================================

set -euo pipefail

# =============================================================================
# URL CONFIGURATION
# Assemble the playbook URL from components. Change these variables to point
# to a fork, a different repo, or a feature branch — nothing else needs to
# be edited.
# =============================================================================
GITHUB_RAW_BASE="https://raw.githubusercontent.com"
GITHUB_USER="Korplin"
GITHUB_REPO="ldpb"
GITHUB_BRANCH="main"
PLAYBOOK_FILENAME="ldpb.yml"

PLAYBOOK_URL="${GITHUB_RAW_BASE}/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}/${PLAYBOOK_FILENAME}"
PLAYBOOK_DEST="/tmp/${PLAYBOOK_FILENAME}"

# =============================================================================
# OUTPUT HELPERS
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}  →${RESET}  $*"; }
success() { echo -e "${GREEN}  ✓${RESET}  $*"; }
warn()    { echo -e "${YELLOW}  ⚠${RESET}  $*"; }
die()     {
    echo -e "${RED}  ✗  ERROR:${RESET} $*" >&2
    exit 1
}
section() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━━  $*  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

# =============================================================================
# BANNER
# =============================================================================
print_banner() {
    clear 2>/dev/null || true
    echo -e "${BOLD}${CYAN}"
    cat <<'BANNER'
  ██████╗ ███████╗██╗   ██╗██████╗ ██╗      █████╗ ████████╗███████╗ ██████╗ ██████╗ ███╗   ███╗
  ██╔══██╗██╔════╝██║   ██║██╔══██╗██║     ██╔══██╗╚══██╔══╝██╔════╝██╔═══██╗██╔══██╗████╗ ████║
  ██║  ██║█████╗  ██║   ██║██████╔╝██║     ███████║   ██║   █████╗  ██║   ██║██████╔╝██╔████╔██║
  ██║  ██║██╔══╝  ╚██╗ ██╔╝██╔═══╝ ██║     ██╔══██║   ██║   ██╔══╝  ██║   ██║██╔══██╗██║╚██╔╝██║
  ██████╔╝███████╗ ╚████╔╝ ██║     ███████╗██║  ██║   ██║   ██║     ╚██████╔╝██║  ██║██║ ╚═╝ ██║
  ╚═════╝ ╚══════╝  ╚═══╝  ╚═╝     ╚══════╝╚═╝  ╚═╝   ╚═╝   ╚═╝      ╚═════╝ ╚═╝  ╚═╝╚═╝     ╚═╝
BANNER
    echo -e "${RESET}"
    echo -e "  ${BOLD}Linux Developer Platform — Bootstrap${RESET}"
    echo -e "  Playbook : ${CYAN}${PLAYBOOK_URL}${RESET}"
    echo ""
}

# =============================================================================
# SELF-ESCALATION
# If not running as root, re-exec the script under sudo. sudo sets SUDO_USER
# automatically to the original caller, which the Ansible playbook uses to
# identify the real (non-root) user for per-user configuration (shell, nvm,
# fonts, pipx tools, group memberships, etc.).
#
# This allows the user to run:  bash bootstrap.sh
# instead of:                   sudo bash bootstrap.sh
# =============================================================================
if [[ "${EUID}" -ne 0 ]]; then
    warn "Not running as root — re-launching with sudo."
    warn "You may be prompted for your sudo password."
    # realpath resolves the absolute path so the re-exec finds the script
    # regardless of the working directory.
    exec sudo bash "$(realpath "$0")" "$@"
    # exec replaces the current process. The lines below are unreachable
    # unless exec itself fails (e.g. sudo is not installed).
    die "exec sudo failed. Try running: sudo bash $0"
fi

# Check whether the root account is locked. A locked root account makes
# rescue.target inaccessible — sulogin requires the root password to grant
# a shell. This is a common Debian 13 default when no root password is set
# during install.
if passwd -S root 2>/dev/null | grep -q "^root L"; then
    warn "The root account is locked (no password set during install)."
    warn "rescue.target will be inaccessible after reboot."
    warn "Set a root password now to enable emergency recovery:"
    warn ""
    warn "  sudo passwd root"
    warn ""
    read -rp "  Set root password now? [Y/n]: " _set_root_pw
    if [[ "${_set_root_pw:-Y}" =~ ^[Yy]$ ]]; then
        passwd root || warn "passwd root failed. Set it manually before rebooting."
    fi
fi

print_banner

# =============================================================================
# OS VERIFICATION
# Hard-fail immediately on the wrong OS rather than silently applying
# trixie-specific APT sources to an incompatible system.
# =============================================================================
section "OS Verification"

if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release not found. Cannot identify the operating system."
fi

# shellcheck source=/dev/null
source /etc/os-release

if [[ "${ID:-}" != "debian" ]]; then
    die "This script requires Debian.\n  Detected: ${PRETTY_NAME:-unknown OS}"
fi

if [[ "${VERSION_CODENAME:-}" != "trixie" ]]; then
    die "This script requires Debian 13 (trixie).\n" \
        "  Detected: ${PRETTY_NAME:-unknown}\n" \
        "  Please run on a fresh Debian 13 installation."
fi

success "OS confirmed: ${PRETTY_NAME}"

# =============================================================================
# REAL USER DETECTION
# We need the non-root user who owns the desktop session being configured.
# The playbook reads SUDO_USER from its environment:
#   real_user: "{{ ansible_env.SUDO_USER | default(ansible_user_id) }}"
# We detect it here and export it so ansible-playbook inherits it.
#
# Detection priority:
#   1. SUDO_USER   — set by sudo, most reliable for the sudo/self-escalation path
#   2. logname     — reads the login name from utmp; works for direct console
#                    login and most SSH sessions
#   3. PKEXEC_UID  — set by PolicyKit (uncommon but handled)
#   4. Prompt      — fallback when running as root without any of the above
#                    (e.g. logged in directly as root via console or SSH)
# =============================================================================
section "User Detection"

detect_real_user() {
    # Priority 1: SUDO_USER (set by sudo when the script is invoked via sudo
    # or when it self-escalated above).
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        echo "${SUDO_USER}"
        return
    fi

    # Priority 2: logname reads the name of the user logged in on the
    # controlling terminal from utmp. Works for direct console and SSH logins.
    local _logname
    _logname="$(logname 2>/dev/null || true)"
    if [[ -n "${_logname}" && "${_logname}" != "root" ]]; then
        echo "${_logname}"
        return
    fi

    # Priority 3: PKEXEC_UID is set by PolicyKit. Map the UID back to a name.
    if [[ -n "${PKEXEC_UID:-}" ]]; then
        local _pkuser
        _pkuser="$(getent passwd "${PKEXEC_UID}" 2>/dev/null | cut -d: -f1 || true)"
        if [[ -n "${_pkuser}" && "${_pkuser}" != "root" ]]; then
            echo "${_pkuser}"
            return
        fi
    fi

    # No non-root user detected — return empty so the caller can prompt.
    echo ""
}

REAL_USER="$(detect_real_user)"

if [[ -z "${REAL_USER}" ]]; then
    echo ""
    warn "Could not auto-detect the primary desktop user."
    warn "This usually means the script was run directly as root (not via sudo)."
    echo ""
    read -rp "  Enter the username to configure the desktop for: " REAL_USER

    if [[ -z "${REAL_USER}" ]]; then
        die "No username entered. Aborting."
    fi
fi

# Validate the user exists before doing any real work.
if ! id "${REAL_USER}" &>/dev/null; then
    die "User '${REAL_USER}' does not exist on this system.\n" \
        "  Create the user first, then re-run this script."
fi

# Resolve the home directory from /etc/passwd — authoritative and handles
# non-standard home paths (/data/users/x, /srv/home/x, etc.).
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"

if [[ -z "${REAL_HOME}" || ! -d "${REAL_HOME}" ]]; then
    die "Could not resolve a valid home directory for '${REAL_USER}'.\n" \
        "  getent returned: '${REAL_HOME:-<empty>}'"
fi

# Export SUDO_USER so that ansible-playbook inherits it. The playbook's var:
#   real_user: "{{ ansible_env.SUDO_USER | default(ansible_user_id) }}"
# reads this to determine which user receives per-user configuration.
export SUDO_USER="${REAL_USER}"

success "Desktop will be configured for user : ${BOLD}${REAL_USER}${RESET}"
info    "Home directory                        : ${REAL_HOME}"

# =============================================================================
# PACKAGE INDEX UPDATE
# =============================================================================
section "Updating Package Index"

apt-get update -qq
success "Package index updated."

# =============================================================================
# PREREQUISITES
# Install the minimum packages needed to run ansible-playbook and for Ansible's
# built-in modules to function on a clean Debian 13 installation.
#
# python3-apt  : required by ansible.builtin.apt. Without it, every apt task
#                in the playbook fails with a Python import error.
# curl / wget  : curl is used by playbook shell tasks (key downloads, binary
#                installs). wget is the belt-and-suspenders fallback here.
# ca-certificates : required for HTTPS connections before the playbook updates
#                   the certificate store itself.
# gnupg        : required for GPG dearmoring operations in the playbook.
# jq           : used by playbook shell tasks to parse JSON API responses
#                (lazygit, k9s, Nerd Fonts version detection).
# =============================================================================
section "Installing Prerequisites"

PREREQS=(
    ansible
    python3
    python3-apt
    curl
    wget
    ca-certificates
    gnupg
    jq
)

info "Installing: ${PREREQS[*]}"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${PREREQS[@]}"

if ! command -v ansible-playbook &>/dev/null; then
    die "ansible-playbook not found after installation. Check apt output above."
fi

success "Prerequisites installed."
info    "Ansible: $(ansible --version | head -1)"

# =============================================================================
# PLAYBOOK DOWNLOAD
# Fetch the Ansible playbook from GitHub and run a basic sanity check before
# handing off. We try curl first (follows all redirect types reliably), then
# fall back to wget.
# =============================================================================
section "Fetching Ansible Playbook"

info "Source : ${PLAYBOOK_URL}"
info "Destination : ${PLAYBOOK_DEST}"

download_playbook() {
    if command -v curl &>/dev/null; then
        curl -fsSL \
            --retry 3 \
            --retry-delay 2 \
            --retry-connrefused \
            -o "${PLAYBOOK_DEST}" \
            "${PLAYBOOK_URL}"
    else
        wget -q --tries=3 -O "${PLAYBOOK_DEST}" "${PLAYBOOK_URL}"
    fi
}

if ! download_playbook; then
    die "Failed to download playbook.\n  URL: ${PLAYBOOK_URL}\n  Check network connectivity."
fi

# Guard: downloaded file must not be empty.
if [[ ! -s "${PLAYBOOK_DEST}" ]]; then
    die "Downloaded file is empty.\n  URL may be wrong: ${PLAYBOOK_URL}"
fi

# Guard: downloaded file must look like an Ansible playbook.
# A valid playbook begins with a '- name:' play definition.
if ! grep -q "^- name:" "${PLAYBOOK_DEST}" 2>/dev/null; then
    die "Downloaded file does not look like an Ansible playbook.\n" \
        "  URL: ${PLAYBOOK_URL}\n" \
        "  First line: $(head -1 "${PLAYBOOK_DEST}")"
fi

success "Playbook saved and validated: ${PLAYBOOK_DEST}"

# =============================================================================
# ANSIBLE HANDOFF (Stage 2)
# All real system configuration happens here. Ansible applies each task as a
# declared state — running this script again is safe and will only fix drift.
#
# Flags used:
#   -i "localhost,"   single-host inline inventory (trailing comma is required
#                     syntax for an inline list — not a typo)
#   -c local          local connection, no SSH
#   --diff            show file content changes inline — useful on re-runs
#                     to confirm what actually changed
#
# NOTE: -K (--ask-become-pass) is intentionally NOT used. We are already
# running as root after self-escalation above. When ansible runs as root,
# become: true escalates root → root which requires no password.
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  Stage 2: Handing control to Ansible${RESET}"
echo -e "  Every task below enforces a declared system state."
echo -e "  Re-running this script later will only change what has drifted."
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

ANSIBLE_EXIT=0
ansible-playbook "${PLAYBOOK_DEST}" \
    -i "localhost," \
    -c local \
    --diff || ANSIBLE_EXIT=$?

echo ""
if [[ ${ANSIBLE_EXIT} -eq 0 ]]; then
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${GREEN}  Bootstrap complete.${RESET}"
    echo ""
    echo -e "  ${BOLD}Next step — reboot to start KDE Plasma:${RESET}"
    echo ""
    echo -e "    ${BOLD}sudo reboot${RESET}"
    echo ""
    echo -e "  Running this script again is safe — Ansible is idempotent."
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
else
    echo -e "${BOLD}${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${RED}  Ansible exited with code ${ANSIBLE_EXIT}.${RESET}"
    echo -e "  Review the FAILED tasks in the output above."
    echo -e "  Fix the issue and re-run — the playbook is idempotent."
    echo -e "${BOLD}${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    exit "${ANSIBLE_EXIT}"
fi
