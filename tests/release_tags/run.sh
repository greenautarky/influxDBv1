#!/usr/bin/env bash
# Drives the LIVE scripts/push-tags.sh and scripts/registry_tag.py against a throw-away registry,
# and checks that publish.yaml uses them.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
W="$(mktemp -d)"
ran=0
fails=0
check() { # <message> <0 = ok>
    ran=$((ran + 1))
    if [ "$2" -eq 0 ]; then echo "  ok    $1"; else
        echo "  FAIL  $1"
        fails=$((fails + 1))
    fi
}
REG="$(docker run -d -p 127.0.0.1::5000 registry:2)"
# shellcheck disable=SC2317,SC2329 # called by the trap
cleanup() {
    docker rm -f "${REG}" > /dev/null
    rm -rf "${W}"
}
trap cleanup EXIT
HOST="127.0.0.1:$(docker port "${REG}" 5000/tcp | head -1 | sed 's/.*://')"
for _ in {1..30}; do
    if curl -fs "http://${HOST}/v2/" > /dev/null; then break; fi
    sleep 1
done
R="${HOST}/x/addon"
# expect <message> <command...>: the command must succeed
expect() {
    local msg="$1" rc=0
    shift
    "$@" || rc=$?
    check "${msg}" "${rc}"
}
for n in tested rebuilt; do
    printf 'FROM scratch\nLABEL n=%s\nCOPY f /f\n' "${n}" > "${W}/Dockerfile"
    echo "${n}" > "${W}/f"
    docker build -q -t "relt:${n}" "${W}" > /dev/null
done
tag() { python3 "${ROOT}/scripts/registry_tag.py" "$@"; }
push() { "${ROOT}/scripts/push-tags.sh" "$@"; }

printf '%s:sha-abc\n' "${R}" | push relt:tested > /dev/null
check "a candidate (branch/sha tag) is pushed" $?
D="$(tag digest "${R}" sha-abc)"
tag digest "${R}" 0.0.26 > /dev/null
rc=$?
expect "an absent version is exit 1 (absent), not 2" test "${rc}" -eq 1
tag promote "${R}" 0.0.26 "${D}" > /dev/null
expect "promote puts the version on exactly the tested digest" test "$(tag digest "${R}" 0.0.26)" = "${D}"
tag promote "${R}" 0.0.26 "${D}" > /dev/null
check "promote again is a no-op" $?
printf '%s:latest\n' "${R}" | push relt:tested > /dev/null

printf '%s:latest\n%s:0.0.26\n' "${R}" "${R}" | push relt:rebuilt > "${W}/out"
check "a later publish of the released version succeeds" $?
expect "MUST-FLAG: it does not overwrite the released version" test "$(tag digest "${R}" 0.0.26)" = "${D}"
expect "MUST-FLAG: it does not move latest either" test "$(tag digest "${R}" latest)" = "${D}"
grep -q 'already released' "${W}/out"
check "and it says so" $?
printf '%s:latest\n%s:0.0.27\n' "${R}" "${R}" | push relt:rebuilt > /dev/null
N="$(tag digest "${R}" 0.0.27)"
expect "MUST-PASS: a NEW version is published" test "${N}" != "${D}"
expect "MUST-PASS: and latest follows it" test "$(tag digest "${R}" latest)" = "${N}"
tag promote "${R}" 0.0.26 "${N}" > /dev/null
rc=$?
expect "MUST-FLAG: promote refuses to move a released version" test "${rc}:$(tag digest "${R}" 0.0.26)" = "1:${D}"
tag promote "${R}" 0.0.28 "sha256:$(printf '0%.0s' {1..64})" > /dev/null
rc=$?
expect "MUST-FLAG: promote refuses an unknown digest" test "${rc}" -eq 1
tag promote "${R}" 0.0.28 "${D:0:20}" > /dev/null
rc=$?
expect "MUST-FLAG: promote refuses a shortened digest" test "${rc}" -eq 1
tag digest "127.0.0.1:1/x/addon" 0.0.26 > /dev/null 2>&1
rc=$?
expect "MUST-FLAG: an unreachable registry is 'cannot look', not 'absent'" test "${rc}" -eq 2
! printf '127.0.0.1:1/x/addon:0.0.26\n' | push relt:rebuilt > /dev/null 2>&1
check "MUST-FLAG: and the push then fails" $?
! printf '\n' | push relt:rebuilt > /dev/null 2>&1
check "MUST-FLAG: no tags at all is a failure" $?
P="${ROOT}/.github/workflows/publish.yaml"
grep -q 'scripts/push-tags.sh local/ga_influxdbv1:scan' "${P}" && ! grep -qE '^ *docker push' "${P}"
check "WIRING: publish.yaml pushes only through push-tags.sh" $?
grep -q 'scripts/registry_tag.py promote' "${P}"
check "WIRING: publish.yaml promotes through registry_tag.py" $?
echo "release_tags: ${ran} checks, ${fails} failed"
[ "${ran}" -ge 18 ] || exit 2
[ "${fails}" -eq 0 ]
