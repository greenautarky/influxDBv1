#!/usr/bin/env bash
# Push a vetted local image under the given tags.
#   push-tags.sh LOCAL_IMAGE < tags (one full reference per line)
# A version tag (X.Y.Z[-N]) that already exists is NEVER overwritten: nothing at
# all is pushed then, so `latest` cannot move to bytes that no version names.
# "Could not look" is a failure, not "absent".
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
image="$1"
mapfile -t tags < <(grep -vE '^[[:space:]]*$')
if [ "${#tags[@]}" -eq 0 ]; then
    echo "::error::no tags given, nothing was pushed"
    exit 1
fi
for ref in "${tags[@]}"; do
    repo="${ref%:*}"
    tag="${ref##*:}"
    [[ "${tag}" =~ ^[0-9]+(\.[0-9]+)+(-[0-9]+)?$ ]] || continue
    rc=0
    have="$(python3 "${HERE}/registry_tag.py" digest "${repo}" "${tag}")" || rc=$?
    case "${rc}" in
        1) ;;
        0)
            echo "::notice::${ref} is already released as ${have}; not overwritten, no tag pushed"
            exit 0
            ;;
        *)
            echo "::error::cannot tell whether ${ref} exists, nothing was pushed"
            exit 1
            ;;
    esac
done
for ref in "${tags[@]}"; do
    docker tag "${image}" "${ref}"
    docker push "${ref}"
done
echo "Pushed ${#tags[@]} tag(s)"
