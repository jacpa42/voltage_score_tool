#!/usr/bin/env bash
# Live qualifier leaderboard in the browser. Nothing is written to disk.
#
# Runs a small web server on http://localhost:$PORT. Every time the page reloads (every
# INTERVAL seconds) it fetches all entries, pipes this comp's entries as CSV into the Odin
# scorer, and sends back the leaderboard HTML straight from memory. Ctrl+C to quit.
#
# Usage:
#   ./live.sh
#   COMP="Voltage Qualifiers" DATE=2026-11-07 FINALISTS=8 SCORER_ARGS="--top_n 8" ./live.sh
#   DEBUG=1 ./live.sh     # run each step once, print what it got, and exit
set -uo pipefail

# Leave COMP/DATE empty to follow the comp of the most recently updated entry.
export COMP="${COMP:-}"                     # competition_name to show
export DATE="${DATE:-}"                     # competition_date (YYYY-MM-DD)
export INTERVAL="${INTERVAL:-15}"           # seconds between refreshes
export FINALISTS="${FINALISTS:-6}"          # how many per category to highlight as finalists
export SCORER="${SCORER:-./score}"          # the compiled Odin scorer
export SCORER_ARGS="${SCORER_ARGS:-}"       # extra scorer flags, e.g. "--top_n 8" or "--same_pool"
export PORT="${PORT:-8787}"                 # local port for the leaderboard page
export API_URL="${API_URL:-https://kragsentrale.co.za/api/v0}"
export TOKEN_FILE="${TOKEN_FILE:-$HOME/.cache/krag_token}"   # jwt saved by krag_cli
VERSION=8                                   # shown on the page, so you can tell which copy is running

# Print every qualifier entry as JSON (the QualifierFetchAll output) on stdout.
# Uses the jwt from your krag_cli sign-in; the route's `()` input is sent as `null`.
fetch_entries() {
    local token
    token="$(tr -d '[:space:]' < "$TOKEN_FILE")" || return 1
    token="${token#Bearer}"
    curl -sS --fail --max-time 10 -X POST "$API_URL/qualifier/fetch-all" \
        -H "authorization: Bearer $token" \
        -H "content-type: application/json" \
        --data 'null'
}

# Which comp/date to show: COMP/DATE if set, otherwise the most recently updated entry's
pick_comp() {
    jq -r --arg comp "$COMP" --arg date "$DATE" '
        (if $comp == "" or $date == "" then (max_by(.uat) // {}) else {} end) as $latest
        | [ (if $comp != "" then $comp else ($latest.competition_name // "") end),
            (if $date != "" then $date else ($latest.competition_date // "") end) ]
        | @tsv'
}

# JSON entries -> the CSV columns parse_competitor_csv looks for
to_csv() {
    jq -r --arg comp "$1" --arg date "$2" '
        ["Timestamp","Email","First Name","Last Name","Category","Results"],
        (.[]
         | select(.competition_name == $comp and .competition_date == $date)
         | [ (.uat | strftime("%Y/%m/%d %I:%M:%S %p") | ascii_downcase),
             .email, .first_name, .last_name,
             (if .climb_category == "m" then "Men" else "Women" end),
             .boulder_results ])
        | @csv'
}

# Scorer verbosity-1 lines look like:  "  1 mens 733.33 : Alex Honnold | alex@x.com"
# Keep category, position, score and name; the email is dropped here and never shown.
to_rows() {
    sed -nE 's/^ *([0-9]+) (mens|womens) +([0-9.]+) : (.*) \| .*$/\2\t\1\t\3\t\4/p'
}

html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# One column of the leaderboard for a category
column() {
    local cat="$1" title="$2" rows="$3" c pos score name n=0 cls
    echo "<section><h2>$title</h2><ol>"
    while IFS=$'\t' read -r c pos score name; do
        [[ "$c" == "$cat" ]] || continue
        n=$((n + 1))
        pos=$((10#$pos))   # scorer prints "001"; leading zeros would otherwise mean octal
        cls=""
        if (( pos <= FINALISTS )); then cls=' class="final"'; fi
        printf '<li%s><span class="pos">%s</span><span class="name">%s</span><span class="score">%.0f</span></li>\n' \
            "$cls" "$pos" "$(printf '%s' "$name" | html_escape)" "$score"
    done <<< "$rows"
    if (( n == 0 )); then echo '<li class="empty">No entries yet</li>'; fi
    echo "</ol></section>"
}

# The whole page. <!--ERR--> is where the server drops an error when showing an older result.
render() {
    local comp="$1" rows="$2" count="$3" status="$4" stale="$5"
    cat <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="$INTERVAL">
<title>$(printf '%s' "$comp" | html_escape) – Live</title>
<style>
  :root { --bg:#000; --fg:#fff; --accent:#607b98; color-scheme:dark; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--fg); font:3.4vmin/1.35 system-ui, sans-serif; text-transform:uppercase; letter-spacing:.04em; }
  main { display:grid; grid-template-columns:1fr 1fr; gap:4vmin; padding:4vmin; }
  h2 { margin:0 0 1.5vmin; font-size:4.5vmin; color:var(--accent); font-weight:600; }
  ol { list-style:none; margin:0; padding:0; }
  li { display:grid; grid-template-columns:7vmin 1fr auto; gap:2.5vmin; padding:1vmin 1.5vmin; border-bottom:1px solid #222; }
  li.final { background:var(--accent); border-color:var(--accent); font-weight:600; }
  li.empty { display:block; color:var(--accent); border:0; }
  .pos { text-align:right; }
  .name { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .score { font-variant-numeric:tabular-nums; }
</style>
</head>
<body>
<main>
$(column mens "Men" "$rows")
$(column womens "Women" "$rows")
</main>
</body>
</html>
HTML
}

run_scorer() { "$SCORER" $SCORER_ARGS --verbosity 1 /dev/stdin <<< "$1"; }

# First line of a failing command's error output
first_err() { "$@" 2>&1 >/dev/null | grep -m1 . | cut -c1-120; }

# Build one page on stdout. Exit 0 when it's fresh; on failure print the error on stderr and exit 1
# (the server then keeps showing the last good page with the error on it).
page() {
    local now json picked comp date csv count scored rows err
    now="$(date +%H:%M:%S)"
    if ! json="$(fetch_entries 2>/dev/null)"; then
        err="fetch failed at $now: $(first_err fetch_entries)"
    elif [[ -z "${json//[[:space:]]/}" ]]; then
        err="fetch returned nothing at $now: $(first_err fetch_entries)"
    elif ! picked="$(printf '%s' "$json" | pick_comp 2>/dev/null)"; then
        err="fetch didn't return JSON at $now: $(printf '%s' "$json" | head -c 80)"
    else
        IFS=$'\t' read -r comp date <<< "$picked"
        csv="$(printf '%s' "$json" | to_csv "$comp" "$date")"
        count=$(( $(printf '%s\n' "$csv" | wc -l) - 1 ))
        if [[ "$csv" != '"Timestamp"'* ]]; then
            err="building the CSV failed at $now (got ${#csv} bytes)"
            printf '%s\n' "$err" >&2
            render "${comp:-Qualifiers}" "" 0 "$err" stale
            return 1
        fi
        # The CSV goes in on stdin as a here-string: bash fills the pipe *before* the scorer
        # starts, so it can never read too early and see an empty file. Nothing touches disk.
        if ! scored="$(run_scorer "$csv" 2>/dev/null)"; then
            err="scorer failed at $now (fed ${#csv} bytes, $count entries): $(run_scorer "$csv" 2>&1 >/dev/null | grep -m1 . | cut -c1-160)"
        else
            rows="$(printf '%s\n' "$scored" | to_rows)"
            if (( count == 0 )); then
                render "$comp" "" 0 "no entries for '$comp' on '$date' ($(printf '%s' "$json" | jq length) fetched in total)" stale
                return 0
            elif [[ -z "$rows" ]]; then
                err="scorer printed no rankings at $now (try DEBUG=1)"
            else
                render "$comp" "$rows" "$count" "$date · updated $now" ""
                return 0
            fi
        fi
    fi
    printf '%s\n' "$err" >&2
    render "${COMP:-Qualifiers}" "" 0 "$err" stale
    return 1
}

# Called by the server for every page load
if [[ "${1:-}" == "--page" ]]; then
    page
    exit $?
fi

# DEBUG=1: run every step once and show what came out, then exit
if [[ "${DEBUG:-}" == 1 ]]; then
    echo "== fetch"; json="$(fetch_entries)"; echo "exit $?, ${#json} bytes"; printf '%s\n' "$json" | head -c 400; echo
    echo "== comps in the data"; printf '%s' "$json" | jq -c 'group_by([.competition_name, .competition_date])[] | {name: .[0].competition_name, date: .[0].competition_date, entries: length}'
    IFS=$'\t' read -r comp date < <(printf '%s' "$json" | pick_comp)
    echo "== showing: '$comp' on '$date'"
    csv="$(printf '%s' "$json" | to_csv "$comp" "$date")"; echo "== csv"; printf '%s\n' "$csv" | head -5
    echo "== scorer"; run_scorer "$csv"; echo "exit $?"
    exit 0
fi

# Tiny local web server: runs `live.sh --page` for each request and keeps the last good page
# in memory, so a failed fetch shows the previous leaderboard with the error on it.
url="http://localhost:$PORT"
echo "live.sh v$VERSION · scorer: $(command -v "$SCORER" || echo "$SCORER (not found!)")"

# Self-test: score a one-climber CSV exactly the way the page does, before starting the server
selftest_csv=$'"Timestamp","Email","First Name","Last Name","Category","Results"\n"2026/11/07 10:00:00 am","self@test","Self","Test","Men","ft"'
if out="$(run_scorer "$selftest_csv" 2>&1)" && grep -q "Self Test" <<< "$out"; then
    echo "scorer self-test: OK"
else
    echo "scorer self-test FAILED. Scorer output:"; printf '%s\n' "$out" | sed 's/^/    /'
fi

echo "Live leaderboard on $url (Ctrl+C to quit)"
( sleep 1; if command -v xdg-open >/dev/null; then xdg-open "$url"; elif command -v open >/dev/null; then open "$url"; fi ) >/dev/null 2>&1 &

exec python3 - "$PORT" "$(realpath "$0")" <<'PY'
import html, http.server, subprocess, sys

port, script = int(sys.argv[1]), sys.argv[2]
last_good = None

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global last_good
        if self.path.split("?")[0] not in ("/", "/index.html"):
            self.send_error(404)
            return
        r = subprocess.run(["bash", script, "--page"], capture_output=True)
        if r.returncode == 0:
            last_good = body = r.stdout
        else:
            err = r.stderr.decode(errors="replace").strip()
            print(err, file=sys.stderr)
            if last_good is not None:
                note = f'<span class="stale">· {html.escape(err)} · showing last results</span>'
                body = last_good.replace(b"<!--ERR-->", note.encode())
            else:
                body = r.stdout
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

try:
    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
except KeyboardInterrupt:
    pass
PY
