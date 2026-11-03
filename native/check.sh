#!/bin/bash
#
# Automated acceptance checks for the dsh-quickbar native helper (v4).
# Safe to run from any directory; exits 0 only if every check passes.
#
# The stdin-trigger check briefly shows the floating popup on screen.
# JSON assertions use python3 (present on this machine).
#
#   bash native/check.sh
#
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BIN="$SCRIPT_DIR/quickbar-hotkey"
SRC="$SCRIPT_DIR/quickbar-hotkey.m"
TMP="${TMPDIR:-/tmp}"
OUT="$TMP/quickbar-check-out.$$"
ERR="$TMP/quickbar-check-err.$$"
FIFO="$TMP/quickbar-check-fifo.$$"
FAILURES=0
CHECKS=0
HELPER_PID=""

cleanup() {
    rm -f "$OUT" "$ERR" "$FIFO"
    exec 9>&- 2>/dev/null
    if [ -n "${HELPER_PID:-}" ] && kill -0 "$HELPER_PID" 2>/dev/null; then
        kill -KILL "$HELPER_PID" 2>/dev/null
    fi
}
trap cleanup EXIT

pass() {
    CHECKS=$((CHECKS + 1))
    printf 'PASS  %s\n' "$1"
}

fail() {
    CHECKS=$((CHECKS + 1))
    FAILURES=$((FAILURES + 1))
    printf 'FAIL  %s\n' "$1"
    if [ $# -gt 1 ]; then
        printf '      %s\n' "$2"
    fi
}

wait_for_line() { # <file> <regex> <deciseconds>
    local file="$1" regex="$2" tries="$3"
    for _ in $(seq 1 "$tries"); do
        grep -qE "$regex" "$file" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}

has_python3() {
    command -v python3 >/dev/null 2>&1
}

json_equal() { # <actual-json> <expected-json>
    if ! has_python3; then
        return 1
    fi
    python3 - "$1" "$2" <<'PY'
import json, sys
try:
    actual = json.loads(sys.argv[1])
    expected = json.loads(sys.argv[2])
except Exception as exc:  # noqa: BLE001
    sys.stderr.write("JSON parse error: %s\n" % exc)
    sys.exit(1)
if actual != expected:
    sys.stderr.write("actual: %s\n" % json.dumps(actual, ensure_ascii=False, sort_keys=True))
    sys.stderr.write("expect: %s\n" % json.dumps(expected, ensure_ascii=False, sort_keys=True))
    sys.exit(1)
PY
}

decode_submit() { # <SUBMIT-line> -> decoded JSON on stdout
    printf '%s' "${1#SUBMIT }" | base64 -D 2>/dev/null
}

# ---------------------------------------------------------------------------
# 0. fixtures: two workspaces, two providers / three models / efforts
# ---------------------------------------------------------------------------
CFG_FULL='{"workspaces":[{"id":"ws-default","label":"默认工作区","path":"/tmp/ws1"},{"id":"ws-2","label":"项目 B","path":"/tmp/ws2"}],"models":[{"provider":{"id":"deepseek","name":"DeepSeek"},"models":[{"id":"chat","name":"DeepSeek Chat","efforts":[],"defaultEffort":null},{"id":"reasoner","name":"DeepSeek Reasoner","efforts":[{"id":"low","name":"Low"},{"id":"high","name":"High"}],"defaultEffort":"low"}]},{"provider":{"id":"anthropic","name":"Anthropic"},"models":[{"id":"sonnet","name":"Sonnet 4.5","efforts":[{"id":"low","name":"Low"},{"id":"medium","name":"Medium"},{"id":"high","name":"High"}],"defaultEffort":"medium"}]}],"selection":{"workspaceId":"ws-2","provider":"anthropic","model":"sonnet","reasoningEffort":"high"}}'
CFG_NULL_SELECTION='{"workspaces":[{"id":"ws-default","label":"默认工作区","path":"/tmp/ws1"},{"id":"ws-2","label":"项目 B","path":"/tmp/ws2"}],"models":[{"provider":{"id":"deepseek","name":"DeepSeek"},"models":[{"id":"chat","name":"DeepSeek Chat","efforts":[],"defaultEffort":null},{"id":"reasoner","name":"DeepSeek Reasoner","efforts":[{"id":"low","name":"Low"},{"id":"high","name":"High"}],"defaultEffort":"low"}]},{"provider":{"id":"anthropic","name":"Anthropic"},"models":[{"id":"sonnet","name":"Sonnet 4.5","efforts":[{"id":"low","name":"Low"},{"id":"medium","name":"Medium"},{"id":"high","name":"High"}],"defaultEffort":"medium"}]}],"selection":{"workspaceId":null,"provider":null,"model":null,"reasoningEffort":null}}'
CFG_REASONER_DEFAULT='{"workspaces":[{"id":"ws-default","label":"默认工作区"}],"models":[{"provider":{"id":"deepseek","name":"DeepSeek"},"models":[{"id":"reasoner","name":"DeepSeek Reasoner","efforts":[{"id":"low","name":"Low"},{"id":"high","name":"High"}],"defaultEffort":"low"}]}],"selection":{"workspaceId":"ws-default","provider":"deepseek","model":"reasoner","reasoningEffort":null}}'

# ---------------------------------------------------------------------------
# 1. build
# ---------------------------------------------------------------------------
if bash "$SCRIPT_DIR/build.sh" >"$OUT" 2>"$ERR"; then
    build_path="$(cat "$OUT")"
    if [ "$build_path" = "$BIN" ] && [ -x "$BIN" ]; then
        pass "build.sh builds $build_path"
    else
        fail "build.sh output" "expected $BIN, got: $build_path"
    fi
else
    fail "build.sh" "$(cat "$ERR")"
fi

# ---------------------------------------------------------------------------
# 2. --selftest: unchanged semantics, no UI, exactly READY + TRIGGER
# ---------------------------------------------------------------------------
selftest_ok() {
    local spec="$1" first second code
    "$BIN" "$spec" --selftest >"$OUT" 2>"$ERR"; code=$?
    first="$(sed -n '1p' "$OUT")"
    second="$(sed -n '2p' "$OUT")"
    if [ "$code" -eq 0 ] \
        && printf '%s\n' "$first" | grep -q '^READY [0-9][0-9]*$' \
        && printf '%s\n' "$second" | grep -q '^TRIGGER [0-9][0-9]*$' \
        && [ "$(wc -l < "$OUT" | tr -d ' ')" -eq 2 ]; then
        pass "selftest $spec -> READY + TRIGGER, exit 0"
    else
        fail "selftest $spec" "exit=$code stdout=$(tr '\n' '|' < "$OUT") stderr=$(head -1 "$ERR")"
    fi
}
selftest_ok "cmd+shift+space"
selftest_ok "shift+f9"

# ---------------------------------------------------------------------------
# 3. --ui-test (structured SUBMIT)
# ---------------------------------------------------------------------------
ui_test_case() { # <label> <text> <expected-json> [cfg-json]
    local label="$1" text="$2" expected="$3" cfg="${4:-}"
    local code lines line json
    if [ -n "$cfg" ]; then
        "$BIN" cmd+shift+space --ui-test "$cfg" "$text" >"$OUT" 2>"$ERR"; code=$?
    else
        "$BIN" cmd+shift+space --ui-test "$text" >"$OUT" 2>"$ERR"; code=$?
    fi
    lines="$(wc -l < "$OUT" | tr -d ' ')"
    line="$(sed -n '1p' "$OUT")"
    if [ "$code" -eq 0 ] && [ "$lines" -eq 1 ] \
        && printf '%s\n' "$line" | grep -qE '^SUBMIT [A-Za-z0-9+/=]+$'; then
        json="$(decode_submit "$line")"
        if json_equal "$json" "$expected"; then
            pass "--ui-test: $label"
        else
            fail "--ui-test: $label (decoded JSON mismatch)" "$json"
        fi
    else
        fail "--ui-test: $label" "exit=$code lines=$lines stdout=$(tr '\n' '|' < "$OUT")"
    fi
}

ui_test_case "no CFG -> null selection + text" "你好" \
    '{"text":"你好","workspaceId":null,"provider":null,"model":null,"reasoningEffort":null}'
ui_test_case "CFG selection passthrough (ws-2/anthropic/sonnet/high)" "你好" \
    '{"text":"你好","workspaceId":"ws-2","provider":"anthropic","model":"sonnet","reasoningEffort":"high"}' "$CFG_FULL"
ui_test_case "CFG null selection -> first workspace/model, no effort" "hello" \
    '{"text":"hello","workspaceId":"ws-default","provider":"deepseek","model":"chat","reasoningEffort":null}' "$CFG_NULL_SELECTION"
ui_test_case "CFG selected model w/o effort -> that model's defaultEffort" "x" \
    '{"text":"x","workspaceId":"ws-default","provider":"deepseek","model":"reasoner","reasoningEffort":"low"}' "$CFG_REASONER_DEFAULT"
ui_test_case "JSON-special text is escaped correctly" 'a"b\c 你好' \
    '{"text":"a\"b\\c 你好","workspaceId":null,"provider":null,"model":null,"reasoningEffort":null}'

# --cfg flag + base64 CFG forms
"$BIN" cmd+shift+space --ui-test "flag" --cfg "$CFG_FULL" >"$OUT" 2>"$ERR"; code=$?
line="$(sed -n '1p' "$OUT")"
if [ "$code" -eq 0 ] && [ "$(wc -l < "$OUT" | tr -d ' ')" -eq 1 ] \
    && json_equal "$(decode_submit "$line")" \
        '{"text":"flag","workspaceId":"ws-2","provider":"anthropic","model":"sonnet","reasoningEffort":"high"}'; then
    pass "--ui-test --cfg JSON form"
else
    fail "--ui-test --cfg JSON form" "exit=$code stdout=$(tr '\n' '|' < "$OUT")"
fi

CFG_B64="$(printf '%s' "$CFG_FULL" | base64 | tr -d '\n')"
"$BIN" cmd+shift+space --ui-test "$CFG_B64" "b64" >"$OUT" 2>"$ERR"; code=$?
line="$(sed -n '1p' "$OUT")"
if [ "$code" -eq 0 ] \
    && json_equal "$(decode_submit "$line")" \
        '{"text":"b64","workspaceId":"ws-2","provider":"anthropic","model":"sonnet","reasoningEffort":"high"}'; then
    pass "--ui-test accepts base64-encoded CFG"
else
    fail "--ui-test base64 CFG" "exit=$code stdout=$(tr '\n' '|' < "$OUT")"
fi

# malformed CFG / CLI misuse
"$BIN" cmd+shift+space --ui-test 'not-json' 'x' >"$OUT" 2>"$ERR"; code=$?
if [ "$code" -eq 2 ] && grep -q '^ERROR invalid-spec' "$OUT"; then
    pass "malformed --ui-test CFG -> ERROR invalid-spec, exit 2"
else
    fail "malformed --ui-test CFG" "exit=$code stdout=$(tr '\n' '|' < "$OUT")"
fi

"$BIN" cmd+shift+space --ui-test >"$OUT" 2>"$ERR"; code=$?
if [ "$code" -eq 2 ] && grep -q '^ERROR invalid-spec' "$OUT"; then
    pass "--ui-test without a text argument -> ERROR invalid-spec, exit 2"
else
    fail "--ui-test missing argument" "exit=$code stdout=$(tr '\n' '|' < "$OUT")"
fi

"$BIN" cmd+shift+space --cfg "$CFG_FULL" >"$OUT" 2>"$ERR"; code=$?
if [ "$code" -eq 2 ] && grep -q '^ERROR invalid-spec' "$OUT"; then
    pass "--cfg without --ui-test -> ERROR invalid-spec, exit 2"
else
    fail "--cfg without --ui-test" "exit=$code stdout=$(tr '\n' '|' < "$OUT")"
fi

"$BIN" cmd+shift+space --selftest --ui-test "x" >"$OUT" 2>"$ERR"; code=$?
if [ "$code" -eq 2 ] && grep -q '^ERROR invalid-spec' "$OUT"; then
    pass "--selftest + --ui-test together -> ERROR invalid-spec, exit 2"
else
    fail "--selftest + --ui-test rejection" "exit=$code stdout=$(tr '\n' '|' < "$OUT")"
fi

# ---------------------------------------------------------------------------
# 4. invalid spec contract
# ---------------------------------------------------------------------------
"$BIN" 'bad+spec' >"$OUT" 2>"$ERR"; code=$?
if [ "$code" -eq 2 ] && grep -q '^ERROR invalid-spec' "$OUT" \
    && [ "$(wc -l < "$OUT" | tr -d ' ')" -eq 1 ]; then
    pass "bad+spec -> ERROR invalid-spec, exit 2"
else
    fail "bad+spec" "exit=$code stdout=$(tr '\n' '|' < "$OUT")"
fi

"$BIN" 'off' >"$OUT" 2>"$ERR"; code=$?
if [ "$code" -eq 2 ] && grep -q '^ERROR invalid-spec' "$OUT"; then
    pass "off -> ERROR invalid-spec, exit 2"
else
    fail "off" "exit=$code stdout=$(tr '\n' '|' < "$OUT")"
fi

# ---------------------------------------------------------------------------
# 5. interactive mode: READY, alive >= 3 s, exit 0 on SIGTERM
# ---------------------------------------------------------------------------
: >"$OUT"; : >"$ERR"
"$BIN" cmd+shift+space </dev/null >"$OUT" 2>"$ERR" &
HELPER_PID=$!
if wait_for_line "$OUT" '^READY [0-9]+$' 30 \
    && [ "$(sed -n '1p' "$OUT" | awk '{print $2}')" = "$HELPER_PID" ]; then
    pass "interactive helper printed READY <pid> matching its pid"
else
    fail "interactive READY" "stdout=$(tr '\n' '|' < "$OUT")"
fi

sleep 3
if kill -0 "$HELPER_PID" 2>/dev/null; then
    pass "helper still alive after 3 s"
else
    fail "helper alive after 3 s"
fi

kill -TERM "$HELPER_PID" 2>/dev/null
wait "$HELPER_PID"; code=$?
HELPER_PID=""
if [ "$code" -eq 0 ]; then
    pass "SIGTERM -> clean exit 0"
else
    fail "SIGTERM exit" "exit=$code"
fi

# ---------------------------------------------------------------------------
# 6. SIGINT -> clean exit 0
# ---------------------------------------------------------------------------
: >"$OUT"; : >"$ERR"
"$BIN" shift+f9 </dev/null >"$OUT" 2>"$ERR" &
HELPER_PID=$!
wait_for_line "$OUT" '^READY ' 30
kill -INT "$HELPER_PID" 2>/dev/null
wait "$HELPER_PID"; code=$?
HELPER_PID=""
if [ "$code" -eq 0 ]; then
    pass "SIGINT -> clean exit 0"
else
    fail "SIGINT exit" "exit=$code"
fi

# ---------------------------------------------------------------------------
# 7. stdin control: CFG + junk + `trigger`; no stdout from CFG, TRIGGER only
# ---------------------------------------------------------------------------
rm -f "$FIFO"
if mkfifo "$FIFO" 2>/dev/null; then
    : >"$OUT"; : >"$ERR"
    "$BIN" cmd+shift+space <"$FIFO" >"$OUT" 2>"$ERR" &
    HELPER_PID=$!
    exec 9>"$FIFO"
    if wait_for_line "$OUT" '^READY ' 30; then
        printf 'unknown command\n\n   \n' >&9
        printf 'CFG !!!not-base64!!!\n' >&9
        sleep 0.3
        if [ "$(wc -l < "$OUT" | tr -d ' ')" -eq 1 ] \
            && kill -0 "$HELPER_PID" 2>/dev/null; then
            pass "stdin: junk + malformed CFG ignored, no stdout, helper alive"
        else
            fail "stdin junk/malformed CFG" "stdout=$(tr '\n' '|' < "$OUT")"
        fi
        printf 'CFG %s\n' "$(printf '%s' "$CFG_FULL" | base64 | tr -d '\n')" >&9
        sleep 0.3
        if [ "$(wc -l < "$OUT" | tr -d ' ')" -eq 1 ]; then
            pass "stdin: valid CFG produces no stdout"
        else
            fail "stdin valid CFG leaked stdout" "stdout=$(tr '\n' '|' < "$OUT")"
        fi
        printf 'trigger\n' >&9
        if wait_for_line "$OUT" '^TRIGGER [0-9]+$' 30; then
            sleep 0.2
            if [ "$(grep -c '^TRIGGER ' "$OUT")" -eq 1 ] \
                && [ "$(grep -c '^READY ' "$OUT")" -eq 1 ] \
                && [ "$(wc -l < "$OUT" | tr -d ' ')" -eq 2 ]; then
                pass "stdin 'trigger' -> exactly READY + one TRIGGER (after CFG)"
            else
                fail "stdin trigger line discipline" "stdout=$(tr '\n' '|' < "$OUT")"
            fi
        else
            fail "stdin 'trigger' -> TRIGGER" "stdout=$(tr '\n' '|' < "$OUT")"
        fi
        kill -TERM "$HELPER_PID" 2>/dev/null
        wait "$HELPER_PID"; code=$?
        HELPER_PID=""
        if [ "$code" -eq 0 ]; then
            pass "helper exits 0 on SIGTERM after CFG + stdin trigger"
        else
            fail "SIGTERM after stdin trigger" "exit=$code"
        fi
    else
        fail "stdin reader startup" "stdout=$(tr '\n' '|' < "$OUT")"
        kill -KILL "$HELPER_PID" 2>/dev/null
        wait "$HELPER_PID" 2>/dev/null
        HELPER_PID=""
    fi
    exec 9>&-
    rm -f "$FIFO"
else
    fail "mkfifo for stdin test"
fi

# ---------------------------------------------------------------------------
# 8. grammar: every documented key parses and self-tests
# ---------------------------------------------------------------------------
grammar_fail=""
for key in a b c d e f g h i j k l m n o p q r s t u v w x y z \
           0 1 2 3 4 5 6 7 8 9 \
           space tab return enter escape esc \
           f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12 \
           comma period slash minus backtick left right up down; do
    "$BIN" "shift+$key" --selftest >"$OUT" 2>"$ERR"; code=$?
    if [ "$code" -ne 0 ] \
        || ! grep -q '^READY ' "$OUT" \
        || ! grep -q '^TRIGGER ' "$OUT"; then
        grammar_fail="$grammar_fail $key(exit=$code)"
    fi
done
if [ -z "$grammar_fail" ]; then
    pass "all documented keys (a-z, 0-9, space, tab, return/enter, escape/esc, f1-f12, punctuation, arrows) self-test"
else
    fail "key grammar" "failed:$grammar_fail"
fi

modifier_fail=""
for spec in "cmd+shift+space" "command+shift+space" "opt+space" "alt+space" \
            "option+space" "ctrl+space" "control+space" \
            "cmd+ctrl+option+shift+f12" "Cmd + Shift + Space"; do
    "$BIN" "$spec" --selftest >"$OUT" 2>"$ERR"; code=$?
    if [ "$code" -ne 0 ]; then
        modifier_fail="$modifier_fail '$spec'(exit=$code)"
    fi
done
if [ -z "$modifier_fail" ]; then
    pass "all modifier names/aliases parse (cmd/command, opt/alt/option, ctrl/control, shift)"
else
    fail "modifier aliases" "failed:$modifier_fail"
fi

reject_fail=""
for spec in "" "off" "none" "disabled" "space" "a" "cmd" "cmd+shift" \
            "cmd+shift+space+tab" "cmd++space" "cmd+cmd+space" "hyper+space" \
            "cmd+space+" "+space"; do
    "$BIN" "$spec" >"$OUT" 2>/dev/null; code=$?
    if [ "$code" -ne 2 ] || ! grep -q '^ERROR invalid-spec' "$OUT"; then
        reject_fail="$reject_fail '$spec'(exit=$code)"
    fi
done
if [ -z "$reject_fail" ]; then
    pass "unsupported/empty/duplicate/multi-key specs are rejected with exit 2"
else
    fail "invalid specs" "not rejected:$reject_fail"
fi

# ---------------------------------------------------------------------------
# 9. binary shape / implementation constraints
# ---------------------------------------------------------------------------
ARCHS="$(lipo -archs "$BIN" 2>/dev/null || true)"
case "$ARCHS" in
    *arm64*x86_64*|*x86_64*arm64*)
        pass "binary is a universal Mach-O (arm64 + x86_64): $ARCHS" ;;
    *)
        fail "binary architecture" "expected arm64 + x86_64, got '$ARCHS' ($(file "$BIN"))" ;;
esac

if grep -Fq '[NSApp run]' "$SRC" && ! grep -q 'RunApplicationEventLoop' "$SRC"; then
    pass "main loop is [NSApp run] (Cocoa), not RunApplicationEventLoop"
else
    fail "main loop implementation"
fi

popup_count="$(grep -c 'NSPopUpButton alloc' "$SRC" 2>/dev/null || true)"
if [ "$popup_count" -eq 3 ] \
    && grep -q 'NSFloatingWindowLevel' "$SRC" \
    && grep -q 'NSWindowCollectionBehaviorCanJoinAllSpaces' "$SRC" \
    && grep -q 'NSWindowCollectionBehaviorFullScreenAuxiliary' "$SRC"; then
    pass "source: three NSPopUpButtons in a floating borderless panel (all spaces/fullscreen auxiliary)"
else
    fail "source popup toolbar" "NSPopUpButton allocations: $popup_count"
fi

if grep -q 'hasMarkedText' "$SRC"; then
    pass "source: IME-aware Enter (hasMarkedText guard before submit)"
else
    fail "source must guard IME marked text on Enter"
fi

if grep -q 'workspaceId' "$SRC" && grep -q 'reasoningEffort' "$SRC" \
    && grep -q '"CFG"' "$SRC" && grep -q 'base64EncodedStringWithOptions' "$SRC"; then
    pass "source: CFG parsing + structured SUBMIT (workspaceId/provider/model/reasoningEffort, base64)"
else
    fail "source structured protocol implementation"
fi

if otool -L "$BIN" 2>/dev/null | grep -q 'AppKit.framework'; then
    pass "binary links AppKit (popup UI)"
else
    fail "binary should link AppKit"
fi

if ! grep -qE 'CGEventTapCreate|CGEventTapEnable|AXIsProcessTrusted' "$SRC" \
    && ! nm -u "$BIN" 2>/dev/null | grep -q 'CGEventTap'; then
    pass "no CGEventTap (no Accessibility/Input Monitoring permission needed)"
else
    fail "source/binary must not use CGEventTap"
fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
printf '\n%d checks, %d failure(s)\n' "$CHECKS" "$FAILURES"
[ "$FAILURES" -eq 0 ]
