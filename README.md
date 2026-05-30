# Claude Code statusline with pace delta

A Claude Code statusline that shows whether you're burning your 5h and 7d
quota faster than the time window allows. Most statuslines show usage
percentage. This one tells you if that percentage is sustainable. This is
a good place to be lazy.

## What it looks like

Two-line output:

```
Claude Opus 4.7 (200k) | git:master
▓▓▓░░░░░░░ 24% | 5h 🟢 32% ↓18% 2h45m | 7d 🟡 41% ↑3% 4d:12h
```

Reading the second line:

- `▓▓▓░░░░░░░ 24%`: context window used, with a colored progress bar.
  Green under 50%, yellow 50 to 75%, red above. The last two cells fade
  to dim red as a visual 80% marker.
- `5h 🟢 32% ↓18% 2h45m`: 5-hour window is at 32%, you're 18% **below**
  the pace you'd need to maintain to hit 100% exactly at reset. Resets
  in 2h45m. Green light because you have headroom.
- `7d 🟡 41% ↑3% 4d:12h`: 7-day window is at 41%, 3% **above** pace.
  Yellow because you're slightly ahead of schedule. Resets in 4 days,
  12 hours (DD:HH format for granularity beyond just "4d").

The pace delta is the headline number. `↓` means you have more room than
the elapsed time suggests. `↑` means you're spending faster than your
budget allows. `→` means on pace.

## Setup

1. Drop the script somewhere. The simplest is `~/.claude/statusline.sh`:

   ```bash
   curl -L https://raw.githubusercontent.com/rmf34/claude-statusline/main/statusline.sh \
     -o ~/.claude/statusline.sh
   chmod +x ~/.claude/statusline.sh
   ```

   Or clone the repo and symlink it in:

   ```bash
   git clone https://github.com/rmf34/claude-statusline ~/code/claude-statusline
   ln -s ~/code/claude-statusline/statusline.sh ~/.claude/statusline.sh
   ```

2. Point Claude Code at it. Edit `~/.claude/settings.json`:

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/statusline.sh",
       "refreshInterval": 10
     }
   }
   ```

   `refreshInterval` (seconds) keeps the countdown timers and pace deltas
   accurate between tool-use events. Without it the status line only
   updates when Claude Code triggers a render. Requires Claude Code
   >=2.1.97.

3. Restart Claude Code (or `/statusline` to reload).

## Two scripts

- `statusline.sh` (the one you want): two-line, model + context bar +
  5h/7d rate windows with pace delta and reset times.
- `statusline-command.sh`: one-line, just model + 20-char context bar +
  percentage. Useful if you want a minimal version to fork from, or you
  don't have rate-limit data to work with.

## How the pace delta works

The 5h window resets every 5 hours. If you've used 60% of it 1 hour in,
that means you're spending roughly 6x faster than sustainable. Plain
percentage doesn't tell you that. The pace delta does.

For a window with `window_secs` total seconds and `resets_at` epoch
seconds in the future:

```
elapsed_pct = (window_secs - (resets_at - now)) / window_secs * 100
delta       = used_pct - elapsed_pct
```

A delta of zero means usage is exactly tracking elapsed time. Negative
delta means you're spending slower than time is passing (good).
Positive delta means you'll hit the cap before the window resets unless
you slow down.

Tolerance bands keep the colors useful:

- First hour of any window: ±10% band, plus suppression of green vs
  yellow distinction. With only minutes elapsed, "you've used 4%" is
  noise, not signal.
- After the first hour: ±5% band. Below pace -> green. Within band ->
  yellow. Above pace -> red.

## Dependencies

- `bash` (the script uses bashisms like `printf -v` and arithmetic
  expressions)
- `jq` for JSON parsing
- `bc` for floating-point arithmetic (bash arithmetic is integer-only)

On Ubuntu/Debian:

```bash
sudo apt install jq bc
```

On macOS:

```bash
brew install jq
```

(`bc` ships with macOS.)

## Customizing

The script is one self-contained file with named helper functions. The
parts you'd reasonably want to change are at the top of the helpers:

- `traffic_light()`: thresholds for green/yellow/red on raw percentages
  (default 50% / 75%).
- `bar_color()`: same thresholds but for the context bar's ANSI color.
- `rate_light()`: pace tolerance bands (10% in first hour, 5% after).
- `make_bar()`: bar width (10 cells) and where the dim-red "danger zone"
  marker starts (cell 8, i.e. 80%).

Window sizes are defined as constants at the top of the script
(`WINDOW_5H=18000`, `WINDOW_7D=604800`) and referenced everywhere else,
so changing them is a one-line edit.

## Tests

26 integration tests, plain bash, no extra deps. They pipe synthetic
session JSON into the script and check the output for expected values,
covering rate_light branches, traffic_light boundaries, pace_delta
arrows, reset-time formatting, context bar rendering, float truncation,
model name preservation, and malformed-input fallback:

```bash
bash test_statusline.sh
```

## Compatibility

This relies on the JSON shape Claude Code feeds to statusline commands
on stdin. Specifically these fields:

```
.model.display_name
.context_window.used_percentage
.context_window.context_window_size
.rate_limits.five_hour.used_percentage
.rate_limits.five_hour.resets_at
.rate_limits.seven_day.used_percentage
.rate_limits.seven_day.resets_at
```

Verified working on:

- Claude Code 2.1.124
- bash 5.2, jq 1.7, bc 1.07
- Ubuntu 24.04 LTS

Check your version with `claude --version`. If the script renders zeroes
or "unknown" everywhere despite Claude Code clearly using context, the
JSON shape probably changed. Run the script with the raw JSON to debug:

```bash
echo '{"model":{"display_name":"Test"},"context_window":{"used_percentage":50,"context_window_size":200000},"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":0},"seven_day":{"used_percentage":40,"resets_at":0}}}' | bash statusline.sh
```

If that prints sane output but Claude Code's live statusline does not,
the field names or nesting have shifted in your version. Open the issue
or send a PR with a sample of what Claude Code now emits (you can dump
it with `bash -c 'cat > /tmp/cc_session.json'` as your statusline
command for one render, then revert).

Known fragile assumptions:

- The 5h and 7d window durations are hardcoded as 18000s and 604800s in
  `statusline.sh`. If Anthropic changes these limits, the pace math
  silently drifts. Update the two arguments at the bottom of the script
  if so.
- Older Claude Code versions may not emit `rate_limits` at all. The
  script falls back to default 0% gracefully, but you lose the pace
  delta entirely. Upgrade Claude Code or remove the rate sections from
  the printf at the bottom.

## License

[MIT](LICENSE).

## Notes from building this

**Plain percentage is the wrong number to display alone.** "5h: 60%"
sounds fine until you remember the 5h window has been open for 10
minutes. Once the time-budget context is on screen alongside the usage,
the decision of "should I keep going or wait for reset" gets easy.

**First-hour noise is real.** Right after a window resets, even tiny
amounts of usage register as huge "ahead of pace" deltas. A naive ±5%
band has the light flickering yellow/red for the first 20 minutes of
every window. The fix is a wider band (±10%) and a "no yellow, just
green or red" rule until enough time has elapsed for the ratio to
stabilize.

**`bc` for everything floating-point.** Bash arithmetic only handles
integers. `(( $(echo "$pct < 50" | bc -l) ))` looks ugly but is the
standard way to do float comparison in pure bash. The alternative is
shelling out to `awk` or `python`, both of which add startup cost on
every statusline render (statuslines render *often*).

**ANSI codes survive `printf %b`.** The bar is built as a string with
embedded `\033[...m` sequences and rendered with `printf "%b"` so the
escapes get interpreted, not literally printed.
