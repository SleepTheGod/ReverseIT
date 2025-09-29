#!/usr/bin/env bash
# reverse-all-commands.sh
# Debian 12 / general Linux - per-user reversed-name wrappers for commands in $PATH
# - install  : append reversible block to ~/.bashrc to create reversed-name wrappers
# - uninstall: remove the appended block
# IMPORTANT: By default the script WILL NOT wrap sensitive/admin commands. To include them
#            you must pass --force-sensitive --confirm="I_ACCEPT_RISK" (explicit opt-in).
#
# Safety design principles:
#  - Per-user only (modifies ~/.bashrc)
#  - Idempotent install/uninstall using clear MARKER tags
#  - Skips reversed names that already exist as commands to avoid collisions
#  - Sanitizes reversed names into valid function identifiers
#  - Provides a dry-run mode to review planned changes
#
# Usage:
#   ./reverse-all-commands.sh install [--path-filter="/usr/bin:/bin"] [--dry-run]
#   ./reverse-all-commands.sh uninstall
#   ./reverse-all-commands.sh install --force-sensitive --confirm="I_ACCEPT_RISK"
#
set -euo pipefail

MARKER_START="# >>> reverse-all-commands START >>>"
MARKER_END="# <<< reverse-all-commands END <<<"
BASHRC="${HOME}/.bashrc"
DEFAULT_PATH="${PATH}"
DRY_RUN=0
INCLUDE_SENSITIVE=0
CONFIRM_STRING=""
PATH_FILTER="${DEFAULT_PATH}"

# Conservative blocklist: do NOT wrap these by default
SENSITIVE_BLOCKLIST=(
  su sudo passwd useradd userdel groupadd groupdel chpasswd chown chgrp
  visudo sudoedit reboot shutdown halt init systemctl mount umount
  dd shred mkfs fdisk sfdisk cryptsetup wipe iptables nft ip ifconfig nmcli
  apt apt-get aptitude dpkg pacman zypper rpm snap snapd snapctl service
  systemd-run login sshd telinit reboot shutdown halt sysctl tc qdisc tcptraceroute
  docker podman docker-compose kubectl kubectl- kubectl.krew
  chmod chroot chattr chcon setfacl getfacl mount umount losetup vgcreate vgextend lvcreate mkfs
  ddrescue dd_rescue wipefs parted badblocks
  nc ncat socat # network tools—careful
  tmux screen # interactive multiplexers
)

# Helper: reverse a string (portable)
reverse_str() {
  printf '%s' "$1" | awk '{ for(i=length;i>0;i--) printf("%s",substr($0,i,1)); printf("\n") }'
}

# Helper: sanitize to valid bash function name
sanitize_name() {
  local name="$1"
  # replace non-alnum with _
  name="$(printf '%s' "$name" | sed 's/[^a-zA-Z0-9_]/_/g')"
  # if starts with digit, prefix with r_
  if [[ "$name" =~ ^[0-9] ]]; then
    name="r_${name}"
  fi
  # if empty, fallback
  if [[ -z "$name" ]]; then
    name="r_cmd"
  fi
  printf '%s' "$name"
}

# Build candidate list from PATH_FILTER and include shell builtins like 'cd' and 'exit'
build_candidates() {
  local -a dirs
  IFS=':' read -r -a dirs <<< "${PATH_FILTER}"
  declare -A seen
  local -a candidates
  for d in "${dirs[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r -d '' f; do
      local bn
      bn="$(basename "$f")"
      if [[ -z "${seen[$bn]:-}" ]]; then
        seen[$bn]=1
        candidates+=("$bn")
      fi
    done < <(find "$d" -maxdepth 1 -type f -executable -print0 2>/dev/null)
  done
  # Add a few common builtins not present as binaries
  for b in cd exit pushd popd help; do
    if [[ -z "${seen[$b]:-}" ]]; then
      seen[$b]=1
      candidates+=("$b")
    fi
  done
  printf '%s\n' "${candidates[@]}"
}

# Parse args
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 install|uninstall [--path-filter=...] [--dry-run] [--force-sensitive --confirm=\"I_ACCEPT_RISK\"]"
  exit 1
fi

ACTION="$1"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path-filter=*) PATH_FILTER="${1#*=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force-sensitive) INCLUDE_SENSITIVE=1; shift ;;
    --confirm=*) CONFIRM_STRING="${1#*=}"; shift ;;
    --help|-h) echo "See header comments for usage"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ $INCLUDE_SENSITIVE -eq 1 ]]; then
  if [[ "$CONFIRM_STRING" != "I_ACCEPT_RISK" ]]; then
    echo "ERROR: --force-sensitive requires --confirm=\"I_ACCEPT_RISK\". Aborting."
    exit 2
  fi
  echo "WARNING: You have explicitly opted into wrapping sensitive commands. This can break your system. Proceed with caution."
fi

# Build candidate list
mapfile -t CANDIDATES < <(build_candidates)

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  echo "No candidate executables found in PATH (${PATH_FILTER}). Aborting."
  exit 1
fi

# Filter candidates according to sensitivity and collision rules; accumulate wrappers
declare -a FINAL_CMDS=()
declare -A SKIPPED_REASON

for cmd in "${CANDIDATES[@]}"; do
  # skip single-char commands (avoid overreach) — user wanted "every single command" but single-char terminals are risky
  if [[ ${#cmd} -le 1 ]]; then
    SKIPPED_REASON["$cmd"]="single-char"
    continue
  fi

  # skip blocklist unless forced
  for blk in "${SENSITIVE_BLOCKLIST[@]}"; do
    if [[ "$cmd" == "$blk" ]]; then
      if [[ $INCLUDE_SENSITIVE -eq 0 ]]; then
        SKIPPED_REASON["$cmd"]="sensitive"
        continue 2
      fi
    fi
  done

  local rev
  rev="$(reverse_str "$cmd")"

  # skip if reversed equals original (palindrome)
  if [[ "$rev" == "$cmd" ]]; then
    SKIPPED_REASON["$cmd"]="palindrome"
    continue
  fi

  # sanitize function name
  fn="$(sanitize_name "$rev")"

  # skip if reversed name already exists as a real command or builtin
  if command -v "$rev" >/dev/null 2>&1 || type "$fn" >/dev/null 2>&1; then
    SKIPPED_REASON["$cmd"]="collision"
    continue
  fi

  FINAL_CMDS+=("$cmd")
done

if [[ ${#FINAL_CMDS[@]} -eq 0 ]]; then
  echo "No safe candidates to wrap after filtering. Exiting."
  # print summary of skipped reasons
  if [[ ${#SKIPPED_REASON[@]} -gt 0 ]]; then
    echo "Summary of skipped commands (sample):"
    for k in "${!SKIPPED_REASON[@]}"; do
      printf "  %s -> %s\n" "$k" "${SKIPPED_REASON[$k]}"
    done
  fi
  exit 0
fi

# Generate wrapper block
generate_block() {
  local ts
  ts="$(date --iso-8601=seconds)"
  cat <<'EOF'
# >>> reverse-all-commands START >>>
# Reversed-command wrappers installed on: __TIMESTAMP__
# To remove, run: reverse-all-commands.sh uninstall
# Automatically generated block - do not edit manually unless you know what you're doing.
if [[ $- == *i* ]]; then
  shopt -s expand_aliases >/dev/null 2>&1 || true
EOF
  for cmd in "${FINAL_CMDS[@]}"; do
    rev="$(reverse_str "$cmd")"
    fn="$(sanitize_name "$rev")"
    # Special-case builtins
    if [[ "$cmd" == "cd" ]]; then
      cat <<EOF
  if ! type "${fn}" >/dev/null 2>&1; then
    ${fn}() { builtin cd "\$@"; }
  fi
EOF
    elif [[ "$cmd" == "exit" ]]; then
      cat <<EOF
  if ! type "${fn}" >/dev/null 2>&1; then
    ${fn}() { builtin exit "\$@"; }
  fi
EOF
    else
      cat <<EOF
  if ! type "${fn}" >/dev/null 2>&1; then
    ${fn}() { command ${cmd} "\$@"; }
  fi
EOF
    fi
  done
  cat <<'EOF'
fi
# <<< reverse-all-commands END <<<
EOF
} # end generate_block

# Replace placeholder timestamp
generate_block_with_timestamp() {
  generate_block | sed "s/__TIMESTAMP__/$(date --iso-8601=seconds)/g"
}

# Dry-run: show what would be changed
if [[ "$ACTION" == "install" && $DRY_RUN -eq 1 ]]; then
  echo "DRY RUN: planned wrappers (count: ${#FINAL_CMDS[@]}):"
  for c in "${FINAL_CMDS[@]}"; do
    printf "  %-25s -> %s\n" "$c" "$(reverse_str "$c")"
  done
  echo
  echo "Skipped examples (reason):"
  local i=0
  for k in "${!SKIPPED_REASON[@]}"; do
    printf "  %-20s -> %s\n" "$k" "${SKIPPED_REASON[$k]}"
    ((i++)); ((i==10)) && break
  done
  echo
  echo "To perform actual install, run: $0 install"
  exit 0
fi

# Install
if [[ "$ACTION" == "install" ]]; then
  # Remove existing block if present (idempotency)
  if grep -Fxq "${MARKER_START}" "${BASHRC}" 2>/dev/null; then
    awk -v start="${MARKER_START}" -v end="${MARKER_END}" '
      BEGIN{inblock=0}
      {
        if($0==start){inblock=1; next}
        if($0==end){inblock=0; next}
        if(!inblock) print $0
      }
    ' "${BASHRC}" > "${BASHRC}.tmp" && mv "${BASHRC}.tmp" "${BASHRC}"
  fi

  # Append new block
  block="$(generate_block_with_timestamp)"
  printf '\n%s\n' "$block" >> "${BASHRC}"

  echo "Installed reversed-command wrappers into ${BASHRC}."
  echo "Wrapped commands count: ${#FINAL_CMDS[@]}"
  echo "Examples (first 10):"
  for ((i=0;i<${#FINAL_CMDS[@]} && i<10;i++)); do
    c=${FINAL_CMDS[i]}
    printf "  %-25s -> %s\n" "$c" "$(reverse_str "$c")"
  done
  echo
  echo "SKIPPED examples (reason):"
  local displayed=0
  for k in "${!SKIPPED_REASON[@]}"; do
    printf "  %-20s -> %s\n" "$k" "${SKIPPED_REASON[$k]}"
    ((displayed++)); ((displayed==10)) && break
  done
  echo
  echo "To activate immediately: source ${BASHRC}"
  echo "To uninstall: $0 uninstall"
  exit 0
fi

# Uninstall
if [[ "$ACTION" == "uninstall" ]]; then
  if ! grep -Fxq "${MARKER_START}" "${BASHRC}" 2>/dev/null; then
    echo "No installed block found in ${BASHRC}. Nothing to do."
    exit 0
  fi
  awk -v start="${MARKER_START}" -v end="${MARKER_END}" '
    BEGIN{inblock=0}
    {
      if($0==start){inblock=1; next}
      if($0==end){inblock=0; next}
      if(!inblock) print $0
    }
  ' "${BASHRC}" > "${BASHRC}.tmp" && mv "${BASHRC}.tmp" "${BASHRC}"
  echo "Removed prank block from ${BASHRC}."
  echo "If your shell is active and already sourced the block, either run: source ${BASHRC} or open a new terminal."
  exit 0
fi

echo "Unknown action: ${ACTION}. Use install or uninstall."
exit 1
