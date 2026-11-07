#!/bin/bash
#
# install.sh — installs every skill in this folder into your local skill library.
#
# Skills are copied (overwriting whatever is already there) into:
#   ~/.agents/skills   (agent-standard location, used by OpenCode)
#
# Usage:
#   ./install.sh              # install to ~/.agents/skills
#   ./install.sh /some/dir    # install to an extra custom location

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGETS=(
  "$HOME/.agents/skills"
)
# Any extra locations passed as arguments
for arg in "$@"; do
  TARGETS+=("$(cd "$arg" && pwd)")
done

# Make targets absolute-safe
for i in "${!TARGETS[@]}"; do
  TARGETS[$i]="${TARGETS[$i]/#\~/$HOME}"
done

installed=0
skipped=0

for skill_dir in "$SCRIPT_DIR"/*/; do
  name="$(basename "$skill_dir")"

  # A skill must have a SKILL.md
  if [ ! -f "$skill_dir/SKILL.md" ]; then
    echo "skip:     $name (no SKILL.md)"
    skipped=$((skipped + 1))
    continue
  fi

  for target in "${TARGETS[@]}"; do
    mkdir -p "$target"
    dest="$target/$name"

    # Overwrite: remove whatever is there (real dir or symlink) first
    rm -rf "$dest"
    cp -R "$skill_dir" "$dest"
    echo "installed: $name -> $dest"
  done

  installed=$((installed + 1))
done

echo
echo "Done. Installed $installed skill(s) into ${#TARGETS[@]} location(s), skipped $skipped non-skill folder(s)."
