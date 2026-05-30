#!/bin/bash
# Claude Code statusline — two-line with pace delta, progress bar, reset times

input=$(cat)
NOW=$(date +%s)

WINDOW_5H=18000
WINDOW_7D=604800

# ── Extract all values in a single jq call ────────────────────────────────
IFS=$'\t' read -r model ctx_pct ctx_size rate_5h rate_5h_resets rate_7d rate_7d_resets < <(
  echo "$input" | jq -r '[.model.display_name // "unknown", .context_window.used_percentage // 0, .context_window.context_window_size // 200000, .rate_limits.five_hour.used_percentage // 0, .rate_limits.five_hour.resets_at // 0, .rate_limits.seven_day.used_percentage // 0, .rate_limits.seven_day.resets_at // 0] | @tsv' 2>/dev/null
)

# Fallback for malformed/empty input
model=${model:-unknown}
ctx_pct=${ctx_pct:-0}
ctx_size=${ctx_size:-200000}
rate_5h=${rate_5h:-0}
rate_5h_resets=${rate_5h_resets:-0}
rate_7d=${rate_7d:-0}
rate_7d_resets=${rate_7d_resets:-0}

# Truncate to integers (guards against floats from upstream)
ctx_pct=${ctx_pct%.*}
ctx_size=${ctx_size%.*}
rate_5h=${rate_5h%.*}
rate_5h_resets=${rate_5h_resets%.*}
rate_7d=${rate_7d%.*}
rate_7d_resets=${rate_7d_resets%.*}

git_branch=$(git --no-optional-locks branch --show-current 2>/dev/null || echo "no-git")

# ── Helpers ────────────────────────────────────────────────────────────────

format_num() {
    local n=$1
    if [ "$n" -ge 1000000 ] 2>/dev/null; then
        printf "%.1fM" "$(echo "scale=1; $n / 1000000" | bc)"
    elif [ "$n" -ge 1000 ] 2>/dev/null; then
        echo "$(( n / 1000 ))k"
    else
        echo "$n"
    fi
}

traffic_light() {
    local pct=$1
    if (( pct < 50 )); then echo "🟢"
    elif (( pct < 75 )); then echo "🟡"
    else echo "🔴"
    fi
}

bar_color() {
    local pct=$1
    if (( pct < 50 )); then printf "\033[32m"
    elif (( pct < 75 )); then printf "\033[33m"
    else printf "\033[31m"
    fi
}

# Rate light based on pace delta: green = below pace, red = above pace, yellow = on track.
# Tolerance band: ±10% in first hour (low signal-to-noise), ±5% thereafter.
rate_light() {
    local used_pct=$1
    local resets_at=$2
    local window_secs=$3

    if [ "$resets_at" -le 0 ] 2>/dev/null; then
        traffic_light "$used_pct"; return
    fi

    local remaining=$(( resets_at - NOW ))
    [ "$remaining" -lt 0 ] && remaining=0
    local elapsed=$(( window_secs - remaining ))
    [ "$elapsed" -lt 0 ] && elapsed=0

    local elapsed_pct; elapsed_pct=$(echo "scale=4; $elapsed * 100 / $window_secs" | bc)
    local delta; delta=$(echo "scale=4; $used_pct - $elapsed_pct" | bc)

    if [ "$elapsed" -lt 3600 ]; then
        if (( $(echo "$delta > 10" | bc -l) )); then echo "🔴"
        else echo "🟢"
        fi
        return
    fi

    if (( $(echo "$delta > 5" | bc -l) )); then echo "🔴"
    elif (( $(echo "$delta < -5" | bc -l) )); then echo "🟢"
    else echo "🟡"
    fi
}

# 10-char progress bar with red 80% marker, colored by usage level
make_bar() {
    local pct=$1
    local filled=$(( pct * 10 / 100 ))
    local color; color=$(bar_color "$pct")
    local reset="\033[0m"
    local bar=""
    local dim_red="\033[2;31m"

    for (( i=0; i<10; i++ )); do
        if [ "$i" -lt "$filled" ]; then
            bar="${bar}${color}▓${reset}"
        elif [ "$i" -ge 8 ]; then
            bar="${bar}${dim_red}░${reset}"
        else
            bar="${bar}░"
        fi
    done
    printf "%b" "$bar"
}

# Returns seconds remaining, or prints "now" and returns 1 to signal early exit
_remaining_or_now() {
    local resets_at=$1
    local diff=$(( resets_at - NOW ))

    if [ "$resets_at" -le 0 ] || [ "$diff" -le 0 ] 2>/dev/null; then
        echo "now"; return 1
    fi
    echo "$diff"; return 0
}

format_reset_5h() {
    local diff
    diff=$(_remaining_or_now "$1") || { echo "$diff"; return; }

    local hours=$(( diff / 3600 ))
    local mins=$(( (diff % 3600) / 60 ))

    if [ "$hours" -gt 0 ]; then echo "${hours}h${mins}m"
    else echo "${mins}m"
    fi
}

format_reset_7d() {
    local diff
    diff=$(_remaining_or_now "$1") || { echo "$diff"; return; }

    local days=$(( diff / 86400 ))
    local hours=$(( (diff % 86400) / 3600 ))
    printf "%dd:%02dh" "$days" "$hours"
}

# Pace delta: ↑10% = burning faster than sustainable, ↓10% = headroom, → = on pace
pace_delta() {
    local used_pct=$1
    local resets_at=$2
    local window_secs=$3

    if [ "$resets_at" -le 0 ] 2>/dev/null; then echo ""; return; fi

    local remaining=$(( resets_at - NOW ))
    [ "$remaining" -lt 0 ] && remaining=0
    local elapsed=$(( window_secs - remaining ))
    [ "$elapsed" -lt 0 ] && elapsed=0

    local elapsed_pct; elapsed_pct=$(echo "scale=2; $elapsed * 100 / $window_secs" | bc)
    local delta; delta=$(echo "scale=1; $used_pct - $elapsed_pct" | bc)
    local abs_delta; abs_delta=$(echo "$delta" | tr -d '-')
    local int_abs; int_abs=$(printf "%.0f" "$abs_delta")

    if (( $(echo "$delta > 1" | bc -l) )); then echo "↑${int_abs}%"
    elif (( $(echo "$delta < -1" | bc -l) )); then echo "↓${int_abs}%"
    else echo "→"
    fi
}

# ── Compute ────────────────────────────────────────────────────────────────
ctx_size_fmt=$(format_num "$ctx_size")
ctx_bar=$(make_bar "$ctx_pct")
rate_5h_emoji=$(rate_light "$rate_5h" "$rate_5h_resets" "$WINDOW_5H")
rate_7d_emoji=$(rate_light "$rate_7d" "$rate_7d_resets" "$WINDOW_7D")
reset_5h=$(format_reset_5h "$rate_5h_resets")
reset_7d=$(format_reset_7d "$rate_7d_resets")
pace_5h=$(pace_delta "$rate_5h" "$rate_5h_resets" "$WINDOW_5H")
pace_7d=$(pace_delta "$rate_7d" "$rate_7d_resets" "$WINDOW_7D")

# ── Render ─────────────────────────────────────────────────────────────────
printf "%s (%s) | git:%s\n" \
    "$model" "$ctx_size_fmt" "$git_branch"

printf "%b %.0f%% | 5h %s%.0f%% %s %s | 7d %s%.0f%% %s %s\n" \
    "$ctx_bar" "$ctx_pct" \
    "$rate_5h_emoji" "$rate_5h" "$pace_5h" "$reset_5h" \
    "$rate_7d_emoji" "$rate_7d" "$pace_7d" "$reset_7d"
