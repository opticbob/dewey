#!/bin/sh
# Reclaim disk from superseded Dewey images in the apps container.
#
# Two kinds accumulate, and both need handling:
#   * tagged  - ghcr.io/opticbob/dewey, one per pull that took the tag
#   * dangling - the previous holder of that tag, untagged by the next pull.
#     These are invisible to `docker images ghcr.io/opticbob/dewey` and are
#     where the space actually goes: 21 of them had built up by 2026-09-02.
#
# Keeps the KEEP (default 2) most recent Dewey images overall so the last
# deploy always has a rollback target, and never touches an image backing a
# container, the local dewey:* builds, or any dewey:rollback-* tag. That is
# why this exists instead of `docker image prune -a`, which sweeps all of them.
#
# Run inside the apps container (CT 107):
#   sh prune-dewey-images.sh [KEEP] [--dry-run]

set -eu

REPO=ghcr.io/opticbob/dewey
KEEP=2
DRY_RUN=no

for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=yes ;;
        ''|*[!0-9]*) echo "unexpected argument: $arg" >&2; exit 2 ;;
        *) KEEP=$arg ;;
    esac
done

[ "$KEEP" -ge 1 ] || { echo "KEEP must be at least 1, so a rollback survives" >&2; exit 2; }

# Images backing a container, running or stopped: a stopped container is still
# someone's rollback plan.
in_use=$(docker ps -aq | xargs -r docker inspect --format '{{.Image}}' 2>/dev/null || true)

# Dewey images are identified by their source label rather than by tag, since
# the interesting ones have had their tag taken away by a later pull. -a is
# essential: without it docker hides exactly the untagged images we are after.
# Sorted
# newest first, so everything past the first KEEP is fair game.
candidates=$(
    for id in $(docker images -a --no-trunc -q | awk '!seen[$0]++'); do
        source_label=$(docker inspect "$id" \
            --format '{{index .Config.Labels "org.opencontainers.image.source"}}' 2>/dev/null || true)
        case $source_label in
            *opticbob/dewey*) ;;
            *) continue ;;
        esac
        # Sort key first, then the id; created is RFC3339 so it sorts lexically.
        created=$(docker inspect "$id" --format '{{.Created}}' 2>/dev/null || echo 0)
        echo "$created $id"
    done | sort -r | awk '{print $2}'
)

removed=0
n=0
for id in $candidates; do
    n=$((n + 1))
    if [ "$n" -le "$KEEP" ]; then
        echo "keep    ${id#sha256:}"
        continue
    fi

    if echo "$in_use" | grep -q "$id"; then
        echo "skip    ${id#sha256:} (backing a container)"
        continue
    fi

    if [ "$DRY_RUN" = yes ]; then
        echo "would remove ${id#sha256:}"
        removed=$((removed + 1))
        continue
    fi

    if docker rmi "$id" >/dev/null 2>&1; then
        echo "removed ${id#sha256:}"
        removed=$((removed + 1))
    else
        echo "skip    ${id#sha256:} (still referenced)"
    fi
done

if [ "$DRY_RUN" = yes ]; then
    echo "dry run: would remove $removed, keeping $KEEP most recent"
else
    echo "kept $KEEP most recent, removed $removed"
fi
