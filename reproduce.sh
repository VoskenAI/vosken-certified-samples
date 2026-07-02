#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 VoskenAI Ltd <info@vosken.ai>
# SPDX-License-Identifier: Apache-2.0
#
# reproduce.sh - re-run every formal proof in this repo and diff the
# per-assertion results against the shipped VERDICT.txt certificates.
#
# Default path: Docker. Builds the pinned image from ./Dockerfile (oss-cad-suite,
# dated release recorded in ENVIRONMENT.txt) and re-runs this script inside it.
# That is the certified path: same tools, same versions, same verdicts.
#
# Bare-metal path: ./reproduce.sh --native uses sby/yosys from your PATH. If
# your tool versions exactly match ENVIRONMENT.txt the run counts as a
# certified reproduction; otherwise it proceeds under an "uncertified
# environment" banner (the proofs still either hold or they do not).
#
# Exit code 0 only if, for every primitive:
#   - the RTL hashes match the certificate (the proof is bound to these bits),
#   - the prove task passes with every assertion PASS,
#   - the cover task reaches every cover point,
#   - the per-assertion verdict list is identical to VERDICT.txt.

set -u

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

CELLS="ring_buffer wrr_arbiter"
IMAGE_TAG="vosken-certified-samples"

# ---------------------------------------------------------------------------
# Pretty printing
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    RED="$(printf '\033[31;1m')"; GREEN="$(printf '\033[32;1m')"
    YELLOW="$(printf '\033[33;1m')"; NC="$(printf '\033[0m')"
else
    RED=""; GREEN=""; YELLOW=""; NC=""
fi
banner() { echo; echo "==================================================================="; echo "$1"; echo "==================================================================="; }

# ---------------------------------------------------------------------------
# Mode selection: default is Docker when available, unless --native is given.
# ---------------------------------------------------------------------------
MODE="auto"
for arg in "$@"; do
    case "$arg" in
        --native) MODE="native" ;;
        --docker) MODE="docker" ;;
        -h|--help)
            echo "usage: $0 [--docker|--native]"
            echo "  (no flag)  use Docker if available, else fall back to native tools"
            echo "  --docker   require the Docker path"
            echo "  --native   use sby/yosys from PATH (bare metal)"
            exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [ "$MODE" = "auto" ]; then
    if command -v docker >/dev/null 2>&1; then MODE="docker"; else
        echo "${YELLOW}docker not found - falling back to native tools${NC}"
        MODE="native"
    fi
fi

if [ "$MODE" = "docker" ]; then
    if ! command -v docker >/dev/null 2>&1; then
        echo "${RED}--docker requested but docker is not installed${NC}" >&2
        exit 2
    fi
    banner "Docker path: pinned environment (see ENVIRONMENT.txt)"
    if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
        echo "Image '$IMAGE_TAG' not found - building it (downloads the pinned"
        echo "oss-cad-suite release, several hundred MB, one time only)."
        docker build -t "$IMAGE_TAG" "$REPO_ROOT" || exit 1
    fi
    exec docker run --rm \
        -v "$REPO_ROOT":/work -w /work -e HOME=/tmp \
        -u "$(id -u):$(id -g)" \
        "$IMAGE_TAG" ./reproduce.sh --native
fi

# ---------------------------------------------------------------------------
# Native path from here on.
# ---------------------------------------------------------------------------
banner "vosken-certified-samples: reproducing formal verdicts"

for tool in sby yosys; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "${RED}required tool not found on PATH: $tool${NC}" >&2
        echo "Install the oss-cad-suite release pinned in ENVIRONMENT.txt," >&2
        echo "or run without --native to use the Docker path." >&2
        exit 2
    fi
done

# ---------------------------------------------------------------------------
# Environment check against ENVIRONMENT.txt (exact version match = certified).
# ---------------------------------------------------------------------------
env_expect() { sed -n "s/^$1: *//p" "$REPO_ROOT/ENVIRONMENT.txt" | head -n1; }

have_ver_yosys="$(yosys --version 2>/dev/null | awk '{print $2}')"
have_ver_sby="$(sby --version 2>/dev/null | sed 's/^SBY v//')"
have_ver_z3="$(z3 --version 2>/dev/null | awk '{print $3}')"
have_ver_bitwuzla="$(bitwuzla --version 2>/dev/null | head -n1)"

want_ver_yosys="$(env_expect yosys)"
want_ver_sby="$(env_expect sby)"
want_ver_z3="$(env_expect z3)"
want_ver_bitwuzla="$(env_expect bitwuzla)"

echo "tool versions (have / certified):"
echo "  yosys    : ${have_ver_yosys:-MISSING} / $want_ver_yosys"
echo "  sby      : ${have_ver_sby:-MISSING} / $want_ver_sby"
echo "  z3       : ${have_ver_z3:-MISSING} / $want_ver_z3"
echo "  bitwuzla : ${have_ver_bitwuzla:-MISSING} / $want_ver_bitwuzla"

CERTIFIED_ENV=1
[ "$have_ver_yosys" = "$want_ver_yosys" ] || CERTIFIED_ENV=0
[ "$have_ver_sby" = "$want_ver_sby" ] || CERTIFIED_ENV=0
[ "$have_ver_z3" = "$want_ver_z3" ] || CERTIFIED_ENV=0
[ "$have_ver_bitwuzla" = "$want_ver_bitwuzla" ] || CERTIFIED_ENV=0

if [ "$CERTIFIED_ENV" = 1 ]; then
    echo "${GREEN}environment matches ENVIRONMENT.txt: certified reproduction${NC}"
else
    echo
    echo "${YELLOW}*******************************************************************${NC}"
    echo "${YELLOW}*  UNCERTIFIED ENVIRONMENT                                        *${NC}"
    echo "${YELLOW}*  Tool versions differ from the pinned set in ENVIRONMENT.txt.  *${NC}"
    echo "${YELLOW}*  Proceeding anyway: the proofs still either hold or fail, but  *${NC}"
    echo "${YELLOW}*  a PASS here is not a certified reproduction. Use the Docker   *${NC}"
    echo "${YELLOW}*  path (./reproduce.sh) for the pinned environment.             *${NC}"
    echo "${YELLOW}*******************************************************************${NC}"
    echo
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
md5_of() {
    if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | awk '{print $1}'
    elif command -v md5 >/dev/null 2>&1; then md5 -q "$1"
    else echo "no-md5-tool"; fi
}

# Parse an sby JUnit XML into lines: "STATUS TYPE id".
# STATUS: PASS (no child tag), FAIL (<failure>/<error>), SKIPPED (<skipped/>).
parse_junit() {
    awk '
    function flush() { if (id != "") print status, type, id; id=""; type=""; status="PASS"; }
    /<testcase/ {
        flush();
        if (match($0, /type="[^"]*"/)) type = substr($0, RSTART+6, RLENGTH-7);
        if (match($0, /id="[^"]*"/))   id   = substr($0, RSTART+4, RLENGTH-5);
    }
    /<skipped/          { if (id != "") status = "SKIPPED"; }
    /<failure|<error/   { if (id != "") status = "FAIL"; }
    END { flush(); }
    ' "$1"
}

# Extract the lines of one [section] from a VERDICT.txt.
verdict_section() {
    awk -v sec="$1" '
    /^\[/ { insec = ($0 == "[" sec "]") ? 1 : 0; next }
    insec && NF && $0 !~ /^#/ { print }
    ' "$2"
}

OVERALL_FAIL=0
SUMMARY=""

for cell in $CELLS; do
    banner "$cell"
    cdir="$REPO_ROOT/$cell"
    verdict="$cdir/VERDICT.txt"
    fdir="$cdir/formal"
    sbyfile="$fdir/fv_${cell}.sby"
    cell_fail=0

    if [ ! -f "$verdict" ] || [ ! -f "$sbyfile" ]; then
        echo "${RED}missing VERDICT.txt or .sby for $cell${NC}"
        OVERALL_FAIL=1; SUMMARY="$SUMMARY
  $cell : MISSING FILES"; continue
    fi

    # -- 1. Hash binding: the certificate applies to these exact RTL bits. ---
    echo "-- checking RTL hash binding"
    while read -r want_md5 relpath; do
        [ -n "$want_md5" ] || continue
        have_md5="$(md5_of "$cdir/$relpath")"
        if [ "$have_md5" = "$want_md5" ]; then
            echo "   ok       $relpath  $have_md5"
        else
            echo "${RED}   MISMATCH $relpath  have=$have_md5  certified=$want_md5${NC}"
            cell_fail=1
        fi
    done <<EOF
$(verdict_section dut_md5 "$verdict")
EOF

    # -- 2. Run the proofs (prove + cover). ----------------------------------
    for task in prove cover; do
        echo "-- running sby: $cell / $task"
        ( cd "$fdir" && sby -f "$(basename "$sbyfile")" "$task" ) >/dev/null 2>&1
        rc=$?
        wdir="$fdir/fv_${cell}_${task}"
        if [ $rc -ne 0 ]; then
            echo "${RED}   sby $task FAILED (rc=$rc) - see $wdir/logfile.txt${NC}"
            cell_fail=1
        else
            echo "   sby $task PASS"
        fi
    done

    # -- 3. Per-assertion diff against the certificate. ----------------------
    echo "-- diffing per-assertion verdicts against VERDICT.txt"
    actual_prove=""
    actual_cover=""
    xml_prove="$fdir/fv_${cell}_prove/fv_${cell}_prove.xml"
    xml_cover="$fdir/fv_${cell}_cover/fv_${cell}_cover.xml"
    tmpdir="${TMPDIR:-/tmp}"
    exp_p="$tmpdir/vcs_exp_p.$$"; act_p="$tmpdir/vcs_act_p.$$"
    exp_c="$tmpdir/vcs_exp_c.$$"; act_c="$tmpdir/vcs_act_c.$$"

    verdict_section prove "$verdict" | sort > "$exp_p"
    verdict_section cover "$verdict" | sort > "$exp_c"
    if [ -f "$xml_prove" ]; then
        parse_junit "$xml_prove" | awk '$2 == "ASSERT"' | sort > "$act_p"
    else : > "$act_p"; cell_fail=1; echo "${RED}   no prove XML produced${NC}"; fi
    if [ -f "$xml_cover" ]; then
        parse_junit "$xml_cover" | awk '$2 == "COVER" { st = ($1 == "PASS") ? "REACHED" : "UNREACHED"; print st, $2, $3 }' | sort > "$act_c"
    else : > "$act_c"; cell_fail=1; echo "${RED}   no cover XML produced${NC}"; fi

    if diff "$exp_p" "$act_p" >/dev/null 2>&1; then
        echo "   prove : $(wc -l < "$exp_p" | tr -d ' ') assertions, all match the certificate"
    else
        echo "${RED}   prove : per-assertion verdicts DIFFER from the certificate:${NC}"
        diff "$exp_p" "$act_p" | sed 's/^/     /'
        cell_fail=1
    fi
    if diff "$exp_c" "$act_c" >/dev/null 2>&1; then
        echo "   cover : $(wc -l < "$exp_c" | tr -d ' ') cover points, all match the certificate"
    else
        echo "${RED}   cover : per-cover verdicts DIFFER from the certificate:${NC}"
        diff "$exp_c" "$act_c" | sed 's/^/     /'
        cell_fail=1
    fi
    # A set difference with zero failing properties on an unpinned toolchain
    # is usually constant-folding drift, not a broken proof - say so.
    if [ $cell_fail -ne 0 ] && [ "$CERTIFIED_ENV" != 1 ]; then
        nfail="$(cat "$act_p" "$act_c" 2>/dev/null | awk '$1=="FAIL" || $1=="UNREACHED"' | wc -l | tr -d ' ')"
        if [ "$nfail" = "0" ]; then
            echo "${YELLOW}   note  : no failing properties; the differing property set most${NC}"
            echo "${YELLOW}           likely reflects your unpinned toolchain (different yosys${NC}"
            echo "${YELLOW}           constant folding). Use the Docker path for the certified run.${NC}"
        fi
    fi
    rm -f "$exp_p" "$act_p" "$exp_c" "$act_c"

    if [ $cell_fail -eq 0 ]; then
        SUMMARY="$SUMMARY
  $cell : REPRODUCED"
    else
        SUMMARY="$SUMMARY
  $cell : MISMATCH"
        OVERALL_FAIL=1
    fi
done

banner "summary"
echo "$SUMMARY"
echo
if [ $OVERALL_FAIL -eq 0 ]; then
    if [ "$CERTIFIED_ENV" = 1 ]; then
        echo "${GREEN}ALL VERDICTS REPRODUCED - certified environment, certified reproduction.${NC}"
    else
        echo "${GREEN}ALL VERDICTS REPRODUCED${NC} ${YELLOW}(uncertified environment - see banner above)${NC}"
    fi
    exit 0
else
    echo "${RED}REPRODUCTION FAILED - at least one verdict differs from the certificate.${NC}"
    exit 1
fi
