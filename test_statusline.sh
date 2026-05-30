#!/bin/bash
# Integration tests for statusline.sh.
# Pipes synthetic session JSON into the script and checks the output for
# the expected pace-light emoji, exercising the rate_light() branches.
#
# Run with:
#     bash test_statusline.sh

set -u
SCRIPT="$(dirname "$0")/statusline.sh"
PASS=0
FAIL=0

# Build a session_info JSON payload with the fields the statusline reads.
# Args: ctx_pct  rate_5h_pct  rate_5h_resets_at  rate_7d_pct  rate_7d_resets_at
make_json() {
    printf '{"model":{"display_name":"Test"},"context_window":{"used_percentage":%s,"context_window_size":200000},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' \
        "$1" "$2" "$3" "$4" "$5"
}

assert_contains() {
    local name=$1 needle=$2 output=$3
    if [[ "$output" == *"$needle"* ]]; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name"
        echo "  expected: $needle"
        echo "  got:      $output"
        FAIL=$((FAIL + 1))
    fi
}

now=$(date +%s)

# Window math reminder:
#   5h window = 18000s, first-hour boundary = 3600s elapsed.
#   resets_at = now + (18000 - elapsed_secs)
#   So 4h in (post-first-hour): resets_at = now + 3600
#      10m in (first hour):     resets_at = now + 17400

# 1. Below pace, post-first-hour: green.
#    Elapsed 80%, used 30%, delta = -50% < -5  -> green.
out=$(make_json 24 30 $((now + 3600)) 0 0 | bash "$SCRIPT")
assert_contains "below_pace_post_first_hour_is_green" "5h 🟢" "$out"

# 2. Above pace, post-first-hour: red.
#    Elapsed 80%, used 90%, delta = +10% > +5  -> red.
out=$(make_json 24 90 $((now + 3600)) 0 0 | bash "$SCRIPT")
assert_contains "above_pace_post_first_hour_is_red" "5h 🔴" "$out"

# 3. On pace within +/-5% band, post-first-hour: yellow.
#    Elapsed 80%, used 78%, delta = -2% within band -> yellow.
out=$(make_json 24 78 $((now + 3600)) 0 0 | bash "$SCRIPT")
assert_contains "on_pace_post_first_hour_is_yellow" "5h 🟡" "$out"

# 4. First hour, low usage: green (yellow is suppressed in the first hour).
#    Elapsed 3.3%, used 0%, delta = -3.3% but in first hour -> green.
out=$(make_json 24 0 $((now + 17400)) 0 0 | bash "$SCRIPT")
assert_contains "first_hour_low_usage_is_green" "5h 🟢" "$out"

# 5. First hour, high usage: red.
#    Elapsed 3.3%, used 50%, delta = +46.7% > +10  -> red even in first hour.
out=$(make_json 24 50 $((now + 17400)) 0 0 | bash "$SCRIPT")
assert_contains "first_hour_high_usage_is_red" "5h 🔴" "$out"

# 6. No rate data falls back to traffic_light on raw usage %.
#    resets_at = 0  -> rate_light skips pace math, calls traffic_light(used).
#    Used 30% < 50%  -> green.
out=$(make_json 24 30 0 0 0 | bash "$SCRIPT")
assert_contains "no_rate_data_falls_back_to_traffic_light" "5h 🟢" "$out"

# 7. 7d reset renders in DD:HH format.
#    resets_at = now + 4d + 12h + 60s = now + 388860 (extra 60s absorbs clock skew)
out=$(make_json 24 40 0 40 $((now + 388860)) | bash "$SCRIPT")
assert_contains "7d_reset_renders_dd_hh" "4d:12h" "$out"

# 8. Malformed input (not JSON) produces fallback output without errors.
out=$(echo "this is not json" | bash "$SCRIPT" 2>/dev/null)
assert_contains "malformed_input_shows_model_fallback" "unknown" "$out"

# 9. Empty input produces fallback output without errors.
out=$(echo "" | bash "$SCRIPT" 2>/dev/null)
assert_contains "empty_input_shows_model_fallback" "unknown" "$out"

# ── 7d rate_light (mirrors 5h tests but exercises the 7d path) ────────────
# 7d window = 604800s. 6d in (post-first-hour): resets_at = now + 86400

# 10. 7d below pace: green.
#     Elapsed ~85.7%, used 30%, delta = -55.7% < -5  -> green.
out=$(make_json 24 0 0 30 $((now + 86400)) | bash "$SCRIPT")
assert_contains "7d_below_pace_is_green" "7d 🟢" "$out"

# 11. 7d above pace: red.
#     Elapsed ~85.7%, used 95%, delta = +9.3% > +5  -> red.
out=$(make_json 24 0 0 95 $((now + 86400)) | bash "$SCRIPT")
assert_contains "7d_above_pace_is_red" "7d 🔴" "$out"

# 12. 7d on pace: yellow.
#     Elapsed ~85.7%, used 84%, delta = -1.7% within ±5  -> yellow.
out=$(make_json 24 0 0 84 $((now + 86400)) | bash "$SCRIPT")
assert_contains "7d_on_pace_is_yellow" "7d 🟡" "$out"

# ── traffic_light boundary values ─────────────────────────────────────────

# 13. Exactly 50% -> yellow (not green). resets_at=0 forces traffic_light fallback.
out=$(make_json 24 50 0 0 0 | bash "$SCRIPT")
assert_contains "traffic_light_50_is_yellow" "5h 🟡" "$out"

# 14. Exactly 75% -> red (not yellow).
out=$(make_json 24 75 0 0 0 | bash "$SCRIPT")
assert_contains "traffic_light_75_is_red" "5h 🔴" "$out"

# ── pace_delta arrows ─────────────────────────────────────────────────────

# 15. Pace delta shows ↑ when well above pace.
#     5h: elapsed 80%, used 90%, delta = +10 -> ↑10%
out=$(make_json 24 90 $((now + 3600)) 0 0 | bash "$SCRIPT")
assert_contains "pace_delta_up_arrow" "↑" "$out"

# 16. Pace delta shows ↓ when well below pace.
#     5h: elapsed 80%, used 30%, delta = -50 -> ↓50%
out=$(make_json 24 30 $((now + 3600)) 0 0 | bash "$SCRIPT")
assert_contains "pace_delta_down_arrow" "↓" "$out"

# 17. Pace delta shows → when on pace.
#     5h: elapsed 80%, used 79%, delta = -1 within ±1 -> →
out=$(make_json 24 79 $((now + 3600)) 0 0 | bash "$SCRIPT")
assert_contains "pace_delta_on_pace_arrow" "→" "$out"

# ── format_reset_5h ───────────────────────────────────────────────────────

# 18. 5h reset: hours + minutes format (Xh pattern present).
#     resets_at = now + 2h31m = now + 9060 (extra 60s absorbs clock skew)
out=$(make_json 24 40 $((now + 9060)) 0 0 | bash "$SCRIPT")
assert_contains "5h_reset_hours_minutes" "2h30m" "$out"

# 19. 5h reset: minutes-only when under 1h.
#     resets_at = now + 45m + 30s = now + 2730 (extra 30s absorbs clock skew)
out=$(make_json 24 40 $((now + 2730)) 0 0 | bash "$SCRIPT")
assert_contains "5h_reset_minutes_only" "45m" "$out"

# 20. 5h reset: "now" when already past.
#     resets_at = now - 60 (in the past)
out=$(make_json 24 40 $((now - 60)) 0 0 | bash "$SCRIPT")
assert_contains "5h_reset_past_shows_now" "now" "$out"

# ── format_reset_7d ───────────────────────────────────────────────────────

# 21. 7d reset: "now" when already past.
out=$(make_json 24 0 0 40 $((now - 60)) | bash "$SCRIPT")
assert_contains "7d_reset_past_shows_now" "7d" "$out"

# 22. 7d reset: 0d:XXh when less than a day remains.
#     resets_at = now + 5h + 60s = now + 18060 (extra 60s absorbs clock skew)
out=$(make_json 24 0 0 40 $((now + 18060)) | bash "$SCRIPT")
assert_contains "7d_reset_under_one_day" "0d:05h" "$out"

# ── Model name with spaces (validates @tsv extraction) ────────────────────

# 23. Model name containing spaces is preserved intact.
json=$(printf '{"model":{"display_name":"Claude Opus 4.7"},"context_window":{"used_percentage":24,"context_window_size":200000},"rate_limits":{"five_hour":{"used_percentage":0,"resets_at":0},"seven_day":{"used_percentage":0,"resets_at":0}}}')
out=$(echo "$json" | bash "$SCRIPT")
assert_contains "model_name_with_spaces" "Claude Opus 4.7" "$out"

# ── Float inputs from upstream (validates truncation) ─────────────────────

# 24. Float percentage is truncated cleanly (no bc errors).
json=$(printf '{"model":{"display_name":"Test"},"context_window":{"used_percentage":67.8,"context_window_size":200000},"rate_limits":{"five_hour":{"used_percentage":42.3,"resets_at":0},"seven_day":{"used_percentage":51.9,"resets_at":0}}}')
out=$(echo "$json" | bash "$SCRIPT" 2>&1)
assert_contains "float_ctx_pct_truncated" "67%" "$out"

# ── Context bar boundaries ────────────────────────────────────────────────

# 25. 0% context: bar is all empty (no filled blocks).
out=$(make_json 0 0 0 0 0 | bash "$SCRIPT")
# Should NOT contain ▓ (filled block)
if [[ "$out" != *"▓"* ]]; then
    echo "PASS: context_bar_0pct_all_empty"
    PASS=$((PASS + 1))
else
    echo "FAIL: context_bar_0pct_all_empty"
    echo "  expected: no ▓ characters"
    echo "  got:      $out"
    FAIL=$((FAIL + 1))
fi

# 26. 100% context: bar is all filled (10 filled blocks).
out=$(make_json 100 0 0 0 0 | bash "$SCRIPT")
# Should NOT contain ░ (empty block)
if [[ "$out" != *"░"* ]]; then
    echo "PASS: context_bar_100pct_all_filled"
    PASS=$((PASS + 1))
else
    echo "FAIL: context_bar_100pct_all_filled"
    echo "  expected: no ░ characters"
    echo "  got:      $out"
    FAIL=$((FAIL + 1))
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
