#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VoskenAI Ltd <info@vosken.ai>
# SPDX-License-Identifier: Apache-2.0
#
# tamper_demo.sh - the falsifiability demo.
#
# A proof that cannot fail is not evidence. This script applies a one-line
# functional bug to the ring_buffer RTL (inverts the write-ready condition:
# the buffer then reports "ready" exactly when it is full), re-runs the
# formal prove task, shows the proof FAIL with a concrete counterexample,
# and reverts the RTL to its certified state.
#
# Default path: Docker (same pinned image as reproduce.sh).
# Bare-metal:   ./tamper_demo.sh --native
#
# Exit 0 = demo behaved as designed (tampered proof FAILED, RTL restored).

set -u

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

IMAGE_TAG="vosken-certified-samples"
TARGET_RTL="$REPO_ROOT/ring_buffer/rtl/ring_buffer.sv"
SBY_DIR="$REPO_ROOT/ring_buffer/formal"
SBY_FILE="fv_ring_buffer.sby"
GOOD_LINE='    assign wready = !full;'
BAD_LINE='    assign wready = full;   // TAMPERED: ready asserted exactly when full'

if [ -t 1 ]; then
    RED="$(printf '\033[31;1m')"; GREEN="$(printf '\033[32;1m')"
    YELLOW="$(printf '\033[33;1m')"; NC="$(printf '\033[0m')"
else
    RED=""; GREEN=""; YELLOW=""; NC=""
fi
banner() { echo; echo "==================================================================="; echo "$1"; echo "==================================================================="; }

MODE="auto"
for arg in "$@"; do
    case "$arg" in
        --native) MODE="native" ;;
        --docker) MODE="docker" ;;
        -h|--help) echo "usage: $0 [--docker|--native]"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

docker_daemon_up() { docker info >/dev/null 2>&1; }

if [ "$MODE" = "auto" ]; then
    if command -v docker >/dev/null 2>&1 && docker_daemon_up; then
        MODE="docker"
    elif command -v sby >/dev/null 2>&1 && command -v yosys >/dev/null 2>&1; then
        if command -v docker >/dev/null 2>&1; then
            echo "${YELLOW}Docker is installed but not running - using native sby/yosys from PATH.${NC}"
        fi
        MODE="native"
    else
        echo "${RED}Neither a running Docker daemon nor native sby/yosys found.${NC}" >&2
        echo "Start Docker Desktop and re-run, or install the tools in ENVIRONMENT.txt." >&2
        exit 2
    fi
fi

if [ "$MODE" = "docker" ]; then
    if ! command -v docker >/dev/null 2>&1; then
        echo "${RED}--docker requested but docker is not installed${NC}" >&2; exit 2
    fi
    if ! docker_daemon_up; then
        echo "${RED}--docker requested but the Docker daemon is not running.${NC}" >&2
        echo "Start Docker Desktop, then re-run." >&2; exit 2
    fi
    if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
        echo "Image '$IMAGE_TAG' not found - building it (one time only)."
        DOCKER_BUILDKIT=1 docker build -t "$IMAGE_TAG" "$REPO_ROOT" || exit 1
    fi
    exec docker run --rm \
        -v "$REPO_ROOT":/work -w /work -e HOME=/tmp \
        -u "$(id -u):$(id -g)" \
        "$IMAGE_TAG" ./tamper_demo.sh --native
fi

for tool in sby yosys; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "${RED}required tool not found on PATH: $tool${NC}" >&2; exit 2; }
done

md5_of() {
    if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | awk '{print $1}'
    else md5 -q "$1"; fi
}

# --------------------------------------------------------------------------
# Safety: back up the RTL and guarantee restoration on any exit path.
# --------------------------------------------------------------------------
BACKUP="$TARGET_RTL.tamper_backup"
cp "$TARGET_RTL" "$BACKUP"
restore() {
    if [ -f "$BACKUP" ]; then
        mv -f "$BACKUP" "$TARGET_RTL"
        echo "RTL restored to its certified state."
    fi
}
trap restore EXIT INT TERM

ORIG_MD5="$(md5_of "$TARGET_RTL")"

banner "step 1: apply a one-line functional bug"
if ! grep -qF "$GOOD_LINE" "$TARGET_RTL"; then
    echo "${RED}expected line not found in $TARGET_RTL - aborting${NC}" >&2
    exit 2
fi
echo "patching ring_buffer/rtl/ring_buffer.sv:"
echo "  - $GOOD_LINE"
echo "  + $BAD_LINE"
awk -v good="$GOOD_LINE" -v bad="$BAD_LINE" '
    !done && $0 == good { print bad; done = 1; next } { print }
' "$TARGET_RTL" > "$TARGET_RTL.tmp" && mv "$TARGET_RTL.tmp" "$TARGET_RTL"
echo
echo "hash binding now broken (this is the point):"
echo "  certified md5 : $ORIG_MD5"
echo "  tampered  md5 : $(md5_of "$TARGET_RTL")"

banner "step 2: re-run the proof against the tampered RTL"
( cd "$SBY_DIR" && sby -f "$SBY_FILE" prove ) > /dev/null 2>&1
RC=$?
XML="$SBY_DIR/fv_ring_buffer_prove/fv_ring_buffer_prove.xml"
if [ $RC -eq 0 ]; then
    echo "${RED}UNEXPECTED: the proof PASSED against tampered RTL.${NC}"
    echo "${RED}The tamper demo has failed - do not trust this bundle.${NC}"
    exit 1
fi
echo "${RED}proof FAILED (sby rc=$RC) - exactly as it must.${NC}"
if [ -f "$XML" ] && grep -q "<failure" "$XML"; then
    echo
    echo "failing assertions:"
    awk '
    /<testcase/ {
        id = "";
        if (match($0, /id="[^"]*"/)) id = substr($0, RSTART+4, RLENGTH-5);
    }
    /<failure/ { if (id != "") print "  FAIL  " id; }
    ' "$XML" | sort -u
fi
if [ -d "$SBY_DIR/fv_ring_buffer_prove/engine_0" ]; then
    CEX="$(find "$SBY_DIR/fv_ring_buffer_prove" -name 'trace*.vcd' 2>/dev/null | head -n1)"
    [ -n "$CEX" ] && echo && echo "counterexample waveform: ${CEX#"$REPO_ROOT"/}"
fi

banner "step 3: revert"
restore
trap - EXIT INT TERM
NEW_MD5="$(md5_of "$TARGET_RTL")"
if [ "$NEW_MD5" = "$ORIG_MD5" ]; then
    echo "md5 after revert: $NEW_MD5 (matches certified hash)"
    echo
    echo "${GREEN}Tamper demo complete: one functional bug -> proof goes red.${NC}"
    echo "${GREEN}Run ./reproduce.sh to confirm the certified verdicts again.${NC}"
    exit 0
else
    echo "${RED}restore failed: hash mismatch after revert${NC}"
    exit 1
fi
