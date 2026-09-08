#!/usr/bin/env bash
# save-configs.sh — snapshot every node's running-config into a tracked directory.
#
#   ./scripts/save-configs.sh <topology.clab.yml> <label>
#
# Example:
#   ./scripts/save-configs.sh labs/02-underlay/underlay.clab.yml numbered
#   -> labs/02-underlay/configs/numbered/<node>.cfg
#
# Why this exists: `containerlab save` writes each node's config into the lab's
# RUNTIME directory (clab-<labname>/), which is .gitignored and is deleted by
# `containerlab destroy --cleanup`. Saving alone does not preserve anything.
# This copies the configs out to a real, committed path first.

set -eu

usage() { printf 'usage: %s <topology.clab.yml> <label>\n' "$0" >&2; exit 2; }

[ $# -eq 2 ] || usage
TOPO="$1"
LABEL="$2"

[ -f "$TOPO" ] || { printf 'no such topology file: %s\n' "$TOPO" >&2; exit 1; }

TOPO_DIR=$(cd "$(dirname "$TOPO")" && pwd)
TOPO_FILE=$(basename "$TOPO")

# Lab name comes from the topology's `name:` key; the runtime dir is clab-<name>.
LAB_NAME=$(awk '/^name:/{print $2; exit}' "$TOPO_DIR/$TOPO_FILE")
[ -n "$LAB_NAME" ] || { printf 'could not read lab name from %s\n' "$TOPO_FILE" >&2; exit 1; }

RUNTIME_DIR="$TOPO_DIR/clab-$LAB_NAME"
DEST="$TOPO_DIR/configs/$LABEL"

printf '\n\033[1mSaving running-configs\033[0m\n'
( cd "$TOPO_DIR" && containerlab save -t "$TOPO_FILE" )

[ -d "$RUNTIME_DIR" ] || { printf 'runtime dir not found: %s\n' "$RUNTIME_DIR" >&2; exit 1; }

mkdir -p "$DEST"

# Find every startup-config under the runtime dir. The exact path inside each
# node directory varies by kind and containerlab version, so search rather than
# assume — the node name is the first path segment under the runtime dir.
COUNT=0
while IFS= read -r cfg; do
  [ -n "$cfg" ] || continue
  rel=${cfg#"$RUNTIME_DIR"/}
  node=${rel%%/*}
  cp "$cfg" "$DEST/${node}.cfg"
  printf '  saved  %s -> configs/%s/%s.cfg\n' "$node" "$LABEL" "$node"
  COUNT=$((COUNT + 1))
done <<EOF
$(find "$RUNTIME_DIR" -name 'startup-config' -type f 2>/dev/null)
EOF

if [ "$COUNT" -eq 0 ]; then
  printf '\n  No startup-config files found under %s\n' "$RUNTIME_DIR" >&2
  printf '  Inspect it directly and report the real path:\n' >&2
  printf '    find %s -maxdepth 3 -type f | head -30\n\n' "$RUNTIME_DIR" >&2
  exit 1
fi

REPO_ROOT=$(git -C "$TOPO_DIR" rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=$(cd "$TOPO_DIR/../.." && pwd)
REL_DEST=${DEST#"$REPO_ROOT"/}

printf '\n  %d config(s) written to %s\n' "$COUNT" "$REL_DEST"
printf '  These are tracked by git and survive `destroy --cleanup`.\n'
printf '  Commit them: git add %s && git commit -m "configs: %s snapshot"\n\n' "$REL_DEST" "$LABEL"
