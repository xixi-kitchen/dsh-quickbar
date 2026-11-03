#!/bin/bash
#
# Automated acceptance checks for the dsh-quickbar native helper (v5).
# Safe to run from any directory; exits 0 only if every check passes.
#
# The stdin-trigger / interaction checks briefly show the floating popup on
# screen (the panel has to exist for toggle / layout assertions). JSON
# assertions use python3 (present on this machine).
#
#   bash native/check.sh
#
# v5 additions: UI-toggle / draft / Esc / paste-image / auto-grow interaction
# self-check, the host-ack lifecycle (`SUBMIT_OK`, `SUBMIT_FAIL`, timeout) and
# the DESIGN.md visual-constant assertions.
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

stdout_submit_count() {
    grep -c '^SUBMIT ' "$1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 0. fixtures: two workspaces, two providers / three models / efforts
# ---------------------------------------------------------------------------
CFG_FULL='{"workspaces":[{"id":"ws-default","label":"默认工作区","path":"/tmp/ws1"},{"id":"ws-2","label":"项目 B","path":"/tmp/ws2"}],"models":[{"provider":{"id":"deepseek","name":"DeepSeek"},"models":[{"id":"chat","name":"DeepSeek Chat","efforts":[],"defaultEffort":null},{"id":"reasoner","name":"DeepSeek Reasoner","efforts":[{"id":"low","name":"Low"},{"id":"high","name":"High"}],"defaultEffort":"low"}]},{"provider":{"id":"anthropic","name":"Anthropic"},"models":[{"id":"sonnet","name":"Sonnet 4.5","efforts":[{"id":"low","name":"Low"},{"id":"medium","name":"Medium"},{"id":"high","name":"High"}],"defaultEffort":"medium"}]}],"selection":{"workspaceId":"ws-2","provider":"anthropic","model":"sonnet","reasoningEffort":"high"}}'
CFG_NULL_SELECTION='{"workspaces":[{"id":"ws-default","label":"默认工作区","path":"/tmp/ws1"},{"id":"ws-2","label":"项目 B","path":"/tmp/ws2"}],"models":[{"provider":{"id":"deepseek","name":"DeepSeek"},"models":[{"id":"chat","name":"DeepSeek Chat","efforts":[],"defaultEffort":null},{"id":"reasoner","name":"DeepSeek Reasoner","efforts":[{"id":"low","name":"Low"},{"id":"high","name":"High"}],"defaultEffort":"low"}]},{"provider":{"id":"anthropic","name":"Anthropic"},"models":[{"id":"sonnet","name":"Sonnet 4.5","efforts":[{"id":"low","name":"Low"},{"id":"medium","name":"Medium"},{"id":"high","name":"High"}],"defaultEffort":"medium"}]}],"selection":{"workspaceId":null,"provider":null,"model":null,"reasoningEffort":null}}'
CFG_REASONER_DEFAULT='{"workspaces":[{"id":"ws-default","label":"默认工作区"}],"models":[{"provider":{"id":"deepseek","name":"DeepSeek"},"models":[{"id":"reasoner","name":"DeepSeek Reasoner","efforts":[{"id":"low","name":"Low"},{"id":"high","name":"High"}],"defaultEffort":"low"}]}],"selection":{"workspaceId":"ws-default","provider":"deepseek","model":"reasoner","reasoningEffort":null}}'

# ---------------------------------------------------------------------------
# 1. build (twice: idempotent) + universal slices + warnings-clean source
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

if bash "$SCRIPT_DIR/build.sh" >"$OUT" 2>"$ERR"; then
    second_path="$(cat "$OUT")"
    if [ "$second_path" = "$BIN" ] && [ -x "$BIN" ]; then
        pass "build.sh is idempotent (second run: $second_path)"
    else
        fail "build.sh idempotent" "second run printed '$second_path'"
    fi
else
    fail "build.sh second run" "$(cat "$ERR")"
fi

ARCHS="$(lipo -archs "$BIN" 2>/dev/null || true)"
case "$ARCHS" in
    *arm64*x86_64*|*x86_64*arm64*)
        pass "binary is a universal Mach-O (arm64 + x86_64): $ARCHS" ;;
    *)
        fail "binary architecture" "expected arm64 + x86_64, got '$ARCHS' ($(file "$BIN"))" ;;
esac

# Source compiles with -Wall -Wextra without a single warning.
if /usr/bin/clang -fsyntax-only -Wall -Wextra -mmacosx-version-min=11.0 "$SRC" >"$OUT" 2>"$ERR"; then
    if [ -s "$ERR" ]; then
        fail "source is -Wall -Wextra clean" "$(head -3 "$ERR")"
    else
        pass "source compiles -Wall -Wextra clean (no warnings)"
    fi
else
    fail "source compiles with -Wall -Wextra" "$(head -3 "$ERR")"
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
# 3. --ui-test (structured SUBMIT incl. images:[])
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

ui_test_case "no CFG -> null selection + text + images:[]" "你好" \
    '{"text":"你好","workspaceId":null,"provider":null,"model":null,"reasoningEffort":null,"images":[]}'
ui_test_case "CFG selection passthrough (ws-2/anthropic/sonnet/high)" "你好" \
    '{"text":"你好","workspaceId":"ws-2","provider":"anthropic","model":"sonnet","reasoningEffort":"high","images":[]}' "$CFG_FULL"
ui_test_case "CFG null selection -> first workspace/model, no effort" "hello" \
    '{"text":"hello","workspaceId":"ws-default","provider":"deepseek","model":"chat","reasoningEffort":null,"images":[]}' "$CFG_NULL_SELECTION"
ui_test_case "CFG selected model w/o effort -> that model's defaultEffort" "x" \
    '{"text":"x","workspaceId":"ws-default","provider":"deepseek","model":"reasoner","reasoningEffort":"low","images":[]}' "$CFG_REASONER_DEFAULT"
ui_test_case "JSON-special text is escaped correctly" 'a"b\c 你好' \
    '{"text":"a\"b\\c 你好","workspaceId":null,"provider":null,"model":null,"reasoningEffort":null,"images":[]}'

# --cfg flag + base64 CFG forms
"$BIN" cmd+shift+space --ui-test "flag" --cfg "$CFG_FULL" >"$OUT" 2>"$ERR"; code=$?
line="$(sed -n '1p' "$OUT")"
if [ "$code" -eq 0 ] && [ "$(wc -l < "$OUT" | tr -d ' ')" -eq 1 ] \
    && json_equal "$(decode_submit "$line")" \
        '{"text":"flag","workspaceId":"ws-2","provider":"anthropic","model":"sonnet","reasoningEffort":"high","images":[]}'; then
    pass "--ui-test --cfg JSON form"
else
    fail "--ui-test --cfg JSON form" "exit=$code stdout=$(tr '\n' '|' < "$OUT")"
fi

CFG_B64="$(printf '%s' "$CFG_FULL" | base64 | tr -d '\n')"
"$BIN" cmd+shift+space --ui-test "$CFG_B64" "b64" >"$OUT" 2>"$ERR"; code=$?
line="$(sed -n '1p' "$OUT")"
if [ "$code" -eq 0 ] \
    && json_equal "$(decode_submit "$line")" \
        '{"text":"b64","workspaceId":"ws-2","provider":"anthropic","model":"sonnet","reasoningEffort":"high","images":[]}'; then
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

"$BIN" cmd+shift+space --ui-test-ack >"$OUT" 2>"$ERR"; code=$?
if [ "$code" -eq 2 ] && grep -q '^ERROR invalid-spec' "$OUT"; then
    pass "--ui-test-ack without a text argument -> ERROR invalid-spec, exit 2"
else
    fail "--ui-test-ack missing argument" "exit=$code stdout=$(tr '\n' '|' < "$OUT")"
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

"$BIN" cmd+shift+space --ui-test "x" --ui-test-ack >"$OUT" 2>"$ERR"; code=$?
if [ "$code" -eq 2 ] && grep -q '^ERROR invalid-spec' "$OUT"; then
    pass "--ui-test + --ui-test-ack together -> ERROR invalid-spec, exit 2"
else
    fail "mode combination rejection" "exit=$code stdout=$(tr '\n' '|' < "$OUT")"
fi

"$BIN" cmd+shift+space --interaction-test "extra" >"$OUT" 2>"$ERR"; code=$?
if [ "$code" -eq 2 ] && grep -q '^ERROR invalid-spec' "$OUT"; then
    pass "--interaction-test with extra args -> ERROR invalid-spec, exit 2"
else
    fail "--interaction-test extra args" "exit=$code stdout=$(tr '\n' '|' < "$OUT")"
fi

# ---------------------------------------------------------------------------
# 4. host-ack lifecycle: SUBMIT_OK / SUBMIT_FAIL / timeout
# ---------------------------------------------------------------------------
"$BIN" cmd+shift+space --ui-test-ack "hello" >"$OUT" 2>"$ERR" <<< "SUBMIT_OK"
code=$?
if [ "$code" -eq 0 ] && [ "$(stdout_submit_count "$OUT")" -eq 1 ] \
    && [ "$(wc -l < "$OUT" | tr -d ' ')" -eq 1 ] \
    && grep -q 'ui-test-ack ack=ok state=sent-then-closed text-cleared=1' "$ERR"; then
    pass "stdin SUBMIT_OK -> SUBMIT emitted once, panel closed after sent check (exit 0)"
else
    fail "SUBMIT_OK lifecycle" "exit=$code stdout=$(tr '\n' '|' < "$OUT") ack=$(grep 'ui-test-ack' "$ERR" | tail -1)"
fi

printf 'SUBMIT_FAIL 模型不可用\n' | "$BIN" cmd+shift+space --ui-test-ack "hello" >"$OUT" 2>"$ERR"
code=$?
if [ "$code" -eq 0 ] && [ "$(stdout_submit_count "$OUT")" -eq 1 ] \
    && grep -q 'ui-test-ack ack=fail state=error text-kept=1 text-len=5 error-row=模型不可用' "$ERR"; then
    pass "stdin SUBMIT_FAIL <text> -> inline error, text kept, one SUBMIT (exit 0)"
else
    fail "SUBMIT_FAIL lifecycle" "exit=$code stdout=$(tr '\n' '|' < "$OUT") ack=$(grep 'ui-test-ack' "$ERR" | tail -1)"
fi

printf 'SUBMIT_OK\n' | "$BIN" cmd+shift+space --ui-test-ack "$CFG_FULL" "你好" >"$OUT" 2>"$ERR"
code=$?
line="$(sed -n '1p' "$OUT")"
if [ "$code" -eq 0 ] && [ "$(wc -l < "$OUT" | tr -d ' ')" -eq 1 ] \
    && json_equal "$(decode_submit "$line")" \
        '{"text":"你好","workspaceId":"ws-2","provider":"anthropic","model":"sonnet","reasoningEffort":"high","images":[]}' \
    && grep -q 'ui-test-ack ack=ok' "$ERR"; then
    pass "--ui-test-ack with CFG keeps the selection + ack lifecycle"
else
    fail "--ui-test-ack CFG" "exit=$code stdout=$(tr '\n' '|' < "$OUT")"
fi

QUICKBAR_ACK_TIMEOUT_MS=400 "$BIN" cmd+shift+space --ui-test-ack "hello" </dev/null >"$OUT" 2>"$ERR"
code=$?
if [ "$code" -eq 0 ] && [ "$(stdout_submit_count "$OUT")" -eq 1 ] \
    && grep -q 'ui-test-ack ack=timeout state=error text-kept=1 text-len=5' "$ERR"; then
    pass "missing ack -> ~timeout fallback shows inline error, text kept (exit 0)"
else
    fail "ack timeout fallback" "exit=$code stdout=$(tr '\n' '|' < "$OUT") ack=$(grep 'ui-test-ack' "$ERR" | tail -1)"
fi

# ---------------------------------------------------------------------------
# 5. --interaction-test: toggle / draft / Esc / paste-image / auto-grow / design
# ---------------------------------------------------------------------------
"$BIN" cmd+shift+space --interaction-test >"$OUT" 2>"$ERR"; code=$?
interaction_stdout_lines="$(wc -l < "$OUT" | tr -d ' ')"
interaction_fails="$(grep -c '^INTERACTION fail' "$ERR" 2>/dev/null || true)"
interaction_oks="$(grep -c '^INTERACTION ok' "$ERR" 2>/dev/null || true)"
if [ "$code" -eq 0 ] && [ "$interaction_fails" -eq 0 ] && [ "$interaction_oks" -ge 20 ] \
    && [ "$interaction_stdout_lines" -eq 2 ] \
    && [ "$(sed -n '1p' "$OUT")" = "CANCEL" ] \
    && sed -n '2p' "$OUT" | grep -qE '^SUBMIT [A-Za-z0-9+/=]+$'; then
    pass "--interaction-test: $interaction_oks assertions ok, stdout = CANCEL + one SUBMIT"
else
    fail "--interaction-test" "exit=$code ok=$interaction_oks fail=$interaction_fails stdout=$(tr '\n' '|' < "$OUT")"
fi

interaction_assert() { # <label> <regex>
    if grep -qE "$2" "$ERR"; then
        pass "interaction: $1"
    else
        fail "interaction: $1" "missing line matching: $2"
    fi
}
interaction_assert "hotkey toggle hides/preserves draft" 'toggle while visible -> hidden, draft preserved, no submit'
interaction_assert "reopen keeps draft" 'toggle while hidden -> visible, draft still there'
interaction_assert "Esc hides + clears (CANCEL)" 'Esc -> hidden \+ content cleared'
interaction_assert "paste-image chips + 4-image cap" 'Cmd\+V image chips: 4 attached, 5th rejected \(max 4\) with inline error'
interaction_assert "inline error row" 'inline error row visible for the image limit'
interaction_assert "image chip remove" 'chip remove button drops the image \(4 -> 3\)'
interaction_assert "SUBMIT images payload shape" 'SUBMIT payload images\[\]: mediaType/base64/width/height valid PNG'
interaction_assert "multi-line auto-grow to 5 lines + scroll" 'auto-grows to 5 lines then scrolls .*scroller=YES'
interaction_assert "Shift+Enter newline without SUBMIT" 'Shift\+Enter inserts a newline, no SUBMIT'
interaction_assert "Enter -> sending state" 'Enter -> one SUBMIT \+ sending: input disabled, spinner, panel open'
interaction_assert "motion budget <= 250ms" 'motion open=180ms close=120ms sent=150ms \(all <= 250ms\)'
interaction_assert "material card radius 16, single shadow, no border" 'card material=popover radius=16 masks=YES outer-border=none'
interaction_assert "position remembered via NSUserDefaults" 'origin remembered in NSUserDefaults key quickbar.popup.origin'

# ---------------------------------------------------------------------------
# 6. invalid spec contract
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
# 7. interactive mode: READY, alive >= 3 s, exit 0 on SIGTERM
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
# 8. SIGINT -> clean exit 0
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
# 9. stdin control: CFG + junk + trigger + ack lines with no pending submit
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
        # v5 ack lines with no submission in flight must be ignored (no stdout).
        printf 'SUBMIT_OK\nSUBMIT_FAIL stale failure\n' >&9
        sleep 0.3
        if [ "$(wc -l < "$OUT" | tr -d ' ')" -eq 2 ] && kill -0 "$HELPER_PID" 2>/dev/null; then
            pass "stdin SUBMIT_OK/SUBMIT_FAIL with no pending submit are ignored (no stdout)"
        else
            fail "stale ack lines" "stdout=$(tr '\n' '|' < "$OUT")"
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
# 10. grammar: every documented key parses and self-tests
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
# 11. implementation constraints (no accessibility, Cocoa loop, protocol)
# ---------------------------------------------------------------------------
if grep -Fq '[NSApp run]' "$SRC" && ! grep -q 'RunApplicationEventLoop' "$SRC"; then
    pass "main loop is [NSApp run] (Cocoa), not RunApplicationEventLoop"
else
    fail "main loop implementation"
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

if grep -q 'hasMarkedText' "$SRC"; then
    pass "source: IME-aware Enter (hasMarkedText guard before submit)"
else
    fail "source must guard IME marked text on Enter"
fi

if grep -q 'workspaceId' "$SRC" && grep -q 'reasoningEffort' "$SRC" \
    && grep -q '"CFG"' "$SRC" && grep -q 'base64EncodedStringWithOptions' "$SRC" \
    && grep -q '"images"' "$SRC" && grep -q '"mediaType"' "$SRC"; then
    pass "source: CFG parsing + structured SUBMIT (selection + images, base64)"
else
    fail "source structured protocol implementation"
fi

if grep -q 'SUBMIT_OK' "$SRC" && grep -q 'SUBMIT_FAIL' "$SRC" \
    && grep -q 'reportSubmitResult\|handleSubmitOk\|handleSubmitFail' "$SRC"; then
    pass "source: stdin SUBMIT_OK / SUBMIT_FAIL ack lifecycle"
else
    fail "source ack lifecycle"
fi

# ---------------------------------------------------------------------------
# 12. v5 design assertions (native/DESIGN.md is authoritative)
# ---------------------------------------------------------------------------
if grep -q 'buildPillInto:&_workspacePill' "$SRC" \
    && grep -q 'buildPillInto:&_modelPill' "$SRC" \
    && grep -q 'buildPillInto:&_effortPill' "$SRC" \
    && grep -q 'NSFloatingWindowLevel' "$SRC" \
    && grep -q 'NSWindowCollectionBehaviorCanJoinAllSpaces' "$SRC" \
    && grep -q 'NSWindowCollectionBehaviorFullScreenAuxiliary' "$SRC"; then
    pass "source: three pill selectors (workspace/model/effort) in a floating borderless panel (all spaces/fullscreen auxiliary)"
else
    fail "source popup toolbar"
fi

design_fail=""
grep -q 'NSVisualEffectView' "$SRC" || design_fail="$design_fail material"
grep -q 'NSVisualEffectMaterialPopover' "$SRC" || design_fail="$design_fail popover"
grep -q 'kQBCardCornerRadius = 16.0' "$SRC" || design_fail="$design_fail radius16"
grep -q 'setMasksToBounds:YES' "$SRC" || design_fail="$design_fail rounded-mask"
grep -q 'setHasShadow:YES' "$SRC" || design_fail="$design_fail shadow"
grep -q 'setBorderWidth' "$SRC" && design_fail="$design_fail outer-border"
grep -q 'kQBOpenDurationMs = 180' "$SRC" || design_fail="$design_fail open180"
grep -q 'kQBCloseDurationMs = 120' "$SRC" || design_fail="$design_fail close120"
grep -q 'kQBSentHoldMs = 150' "$SRC" || design_fail="$design_fail sent150"
grep -q 'kQBInputFontSize = 17.0' "$SRC" || design_fail="$design_fail input17"
grep -q 'kQBControlFontSize = 13.0' "$SRC" || design_fail="$design_fail controls13"
grep -q 'kQBHintFontSize = 11.5' "$SRC" || design_fail="$design_fail hints11.5"
grep -q 'kQBSmallLabelFontSize = 11.0' "$SRC" || design_fail="$design_fail pills11"
grep -q 'imageWithSystemSymbolName:@"chevron.down"' "$SRC" || design_fail="$design_fail chevron"
grep -q 'NSPopUpNoArrow' "$SRC" || design_fail="$design_fail borderless-pills"
grep -q 'NSScrollView' "$SRC" || design_fail="$design_fail scrollview"
grep -q 'QBPasteTextView' "$SRC" || design_fail="$design_fail textview"
grep -q 'setAutomaticQuoteSubstitutionEnabled:NO' "$SRC" || design_fail="$design_fail no-smart-quotes"
grep -q 'setDrawsBackground:NO' "$SRC" || design_fail="$design_fail transparent-input"
grep -q 'controlAccentColor' "$SRC" || design_fail="$design_fail accent"
grep -q 'systemGreenColor' "$SRC" || design_fail="$design_fail sent-green"
grep -q 'systemRedColor' "$SRC" || design_fail="$design_fail error-red"
grep -q 'placeholderTextColor' "$SRC" || design_fail="$design_fail placeholder"
grep -q 'secondaryLabelColor' "$SRC" || design_fail="$design_fail secondary"
grep -q 'kQBOriginDefaultsKey = @"quickbar.popup.origin"' "$SRC" || design_fail="$design_fail origin-key"
grep -q 'windowDidResignKey' "$SRC" || design_fail="$design_fail click-outside"
grep -q 'togglePanel' "$SRC" || design_fail="$design_fail toggle"
grep -q 'kQBMaxImages = 4' "$SRC" || design_fail="$design_fail max4-images"
grep -q 'pasteFromPasteboard' "$SRC" || design_fail="$design_fail paste-image"
if [ -z "$design_fail" ]; then
    pass "design: material card, 16pt radius, single shadow, no outer border, motion, type scale, pill chevrons, multi-line input, semantic colors, position key, toggle/outside-click, 4-image paste"
else
    fail "design constants/implementation" "missing:$design_fail"
fi

# ---------------------------------------------------------------------------
# 13. binary size (report only)
# ---------------------------------------------------------------------------
SIZE_BYTES="$(stat -f '%z' "$BIN" 2>/dev/null || echo 0)"
SIZE_HUMAN="$(du -h "$BIN" 2>/dev/null | awk '{print $1}')"
pass "binary size: ${SIZE_BYTES} bytes (${SIZE_HUMAN})"

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
printf '\n%d checks, %d failure(s)\n' "$CHECKS" "$FAILURES"
[ "$FAILURES" -eq 0 ]
