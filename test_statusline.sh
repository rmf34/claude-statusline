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
#    resets_at = now + 4d + 12h = now + 388800
out=$(make_json 24 40 0 40 $((now + 388800)) | bash "$SCRIPT")
assert_contains "7d_reset_renders_dd_hh" "4d:12h" "$out"

# 8. Malformed input (not JSON) produces fallback output without errors.
out=$(echo "this is not json" | bash "$SCRIPT" 2>/dev/null)
assert_contains "malformed_input_shows_model_fallback" "unknown" "$out"

# 9. Empty input produces fallback output without errors.
out=$(echo "" | bash "$SCRIPT" 2>/dev/null)
assert_contains "empty_input_shows_model_fallback" "unknown" "$out"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
