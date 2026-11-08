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
export SCORER_ARGS="${SCORER_ARGS:- }"       # extra scorer flags, e.g. "--top_n 8" or "--same_pool"
export PORT="${PORT:-8787}"                 # local port for the leaderboard page
export API_URL="${API_URL:-https://kragsentrale.co.za/api/v0}"
export SWORD_URL="${SWORD_URL:-https://kragsentrale.co.za/signup-sword.png}"
# QR code for https://kragsentrale.co.za/qualifiers, shown under the sword
QR_SVG='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 33 33" shape-rendering="crispEdges"><rect width="100%" height="100%" fill="#fff"/><path fill="#000" d="M2 2h1v1h-1zM3 2h1v1h-1zM4 2h1v1h-1zM5 2h1v1h-1zM6 2h1v1h-1zM7 2h1v1h-1zM8 2h1v1h-1zM12 2h1v1h-1zM17 2h1v1h-1zM19 2h1v1h-1zM20 2h1v1h-1zM21 2h1v1h-1zM24 2h1v1h-1zM25 2h1v1h-1zM26 2h1v1h-1zM27 2h1v1h-1zM28 2h1v1h-1zM29 2h1v1h-1zM30 2h1v1h-1zM2 3h1v1h-1zM8 3h1v1h-1zM10 3h1v1h-1zM11 3h1v1h-1zM12 3h1v1h-1zM15 3h1v1h-1zM17 3h1v1h-1zM18 3h1v1h-1zM20 3h1v1h-1zM22 3h1v1h-1zM24 3h1v1h-1zM30 3h1v1h-1zM2 4h1v1h-1zM4 4h1v1h-1zM5 4h1v1h-1zM6 4h1v1h-1zM8 4h1v1h-1zM10 4h1v1h-1zM16 4h1v1h-1zM17 4h1v1h-1zM18 4h1v1h-1zM19 4h1v1h-1zM21 4h1v1h-1zM24 4h1v1h-1zM26 4h1v1h-1zM27 4h1v1h-1zM28 4h1v1h-1zM30 4h1v1h-1zM2 5h1v1h-1zM4 5h1v1h-1zM5 5h1v1h-1zM6 5h1v1h-1zM8 5h1v1h-1zM11 5h1v1h-1zM14 5h1v1h-1zM15 5h1v1h-1zM17 5h1v1h-1zM18 5h1v1h-1zM21 5h1v1h-1zM24 5h1v1h-1zM26 5h1v1h-1zM27 5h1v1h-1zM28 5h1v1h-1zM30 5h1v1h-1zM2 6h1v1h-1zM4 6h1v1h-1zM5 6h1v1h-1zM6 6h1v1h-1zM8 6h1v1h-1zM10 6h1v1h-1zM11 6h1v1h-1zM12 6h1v1h-1zM14 6h1v1h-1zM16 6h1v1h-1zM17 6h1v1h-1zM18 6h1v1h-1zM19 6h1v1h-1zM20 6h1v1h-1zM24 6h1v1h-1zM26 6h1v1h-1zM27 6h1v1h-1zM28 6h1v1h-1zM30 6h1v1h-1zM2 7h1v1h-1zM8 7h1v1h-1zM10 7h1v1h-1zM12 7h1v1h-1zM14 7h1v1h-1zM17 7h1v1h-1zM18 7h1v1h-1zM19 7h1v1h-1zM20 7h1v1h-1zM21 7h1v1h-1zM22 7h1v1h-1zM24 7h1v1h-1zM30 7h1v1h-1zM2 8h1v1h-1zM3 8h1v1h-1zM4 8h1v1h-1zM5 8h1v1h-1zM6 8h1v1h-1zM7 8h1v1h-1zM8 8h1v1h-1zM10 8h1v1h-1zM12 8h1v1h-1zM14 8h1v1h-1zM16 8h1v1h-1zM18 8h1v1h-1zM20 8h1v1h-1zM22 8h1v1h-1zM24 8h1v1h-1zM25 8h1v1h-1zM26 8h1v1h-1zM27 8h1v1h-1zM28 8h1v1h-1zM29 8h1v1h-1zM30 8h1v1h-1zM10 9h1v1h-1zM12 9h1v1h-1zM13 9h1v1h-1zM15 9h1v1h-1zM17 9h1v1h-1zM19 9h1v1h-1zM21 9h1v1h-1zM22 9h1v1h-1zM2 10h1v1h-1zM3 10h1v1h-1zM5 10h1v1h-1zM8 10h1v1h-1zM9 10h1v1h-1zM13 10h1v1h-1zM14 10h1v1h-1zM16 10h1v1h-1zM18 10h1v1h-1zM21 10h1v1h-1zM24 10h1v1h-1zM25 10h1v1h-1zM26 10h1v1h-1zM28 10h1v1h-1zM29 10h1v1h-1zM7 11h1v1h-1zM10 11h1v1h-1zM11 11h1v1h-1zM13 11h1v1h-1zM14 11h1v1h-1zM15 11h1v1h-1zM18 11h1v1h-1zM20 11h1v1h-1zM24 11h1v1h-1zM27 11h1v1h-1zM30 11h1v1h-1zM4 12h1v1h-1zM5 12h1v1h-1zM6 12h1v1h-1zM7 12h1v1h-1zM8 12h1v1h-1zM10 12h1v1h-1zM13 12h1v1h-1zM14 12h1v1h-1zM15 12h1v1h-1zM16 12h1v1h-1zM18 12h1v1h-1zM19 12h1v1h-1zM20 12h1v1h-1zM21 12h1v1h-1zM25 12h1v1h-1zM27 12h1v1h-1zM28 12h1v1h-1zM29 12h1v1h-1zM2 13h1v1h-1zM7 13h1v1h-1zM11 13h1v1h-1zM12 13h1v1h-1zM13 13h1v1h-1zM14 13h1v1h-1zM15 13h1v1h-1zM17 13h1v1h-1zM21 13h1v1h-1zM24 13h1v1h-1zM25 13h1v1h-1zM28 13h1v1h-1zM29 13h1v1h-1zM3 14h1v1h-1zM4 14h1v1h-1zM6 14h1v1h-1zM8 14h1v1h-1zM9 14h1v1h-1zM12 14h1v1h-1zM13 14h1v1h-1zM16 14h1v1h-1zM17 14h1v1h-1zM18 14h1v1h-1zM19 14h1v1h-1zM22 14h1v1h-1zM23 14h1v1h-1zM24 14h1v1h-1zM27 14h1v1h-1zM29 14h1v1h-1zM30 14h1v1h-1zM4 15h1v1h-1zM5 15h1v1h-1zM13 15h1v1h-1zM15 15h1v1h-1zM16 15h1v1h-1zM19 15h1v1h-1zM21 15h1v1h-1zM22 15h1v1h-1zM23 15h1v1h-1zM3 16h1v1h-1zM4 16h1v1h-1zM6 16h1v1h-1zM7 16h1v1h-1zM8 16h1v1h-1zM9 16h1v1h-1zM11 16h1v1h-1zM13 16h1v1h-1zM15 16h1v1h-1zM16 16h1v1h-1zM18 16h1v1h-1zM19 16h1v1h-1zM20 16h1v1h-1zM23 16h1v1h-1zM24 16h1v1h-1zM26 16h1v1h-1zM27 16h1v1h-1zM28 16h1v1h-1zM29 16h1v1h-1zM30 16h1v1h-1zM2 17h1v1h-1zM3 17h1v1h-1zM5 17h1v1h-1zM7 17h1v1h-1zM9 17h1v1h-1zM10 17h1v1h-1zM11 17h1v1h-1zM12 17h1v1h-1zM13 17h1v1h-1zM18 17h1v1h-1zM19 17h1v1h-1zM20 17h1v1h-1zM21 17h1v1h-1zM22 17h1v1h-1zM25 17h1v1h-1zM27 17h1v1h-1zM29 17h1v1h-1zM2 18h1v1h-1zM6 18h1v1h-1zM8 18h1v1h-1zM9 18h1v1h-1zM11 18h1v1h-1zM12 18h1v1h-1zM14 18h1v1h-1zM15 18h1v1h-1zM19 18h1v1h-1zM20 18h1v1h-1zM22 18h1v1h-1zM23 18h1v1h-1zM29 18h1v1h-1zM3 19h1v1h-1zM5 19h1v1h-1zM6 19h1v1h-1zM10 19h1v1h-1zM11 19h1v1h-1zM12 19h1v1h-1zM14 19h1v1h-1zM15 19h1v1h-1zM16 19h1v1h-1zM18 19h1v1h-1zM19 19h1v1h-1zM23 19h1v1h-1zM24 19h1v1h-1zM25 19h1v1h-1zM27 19h1v1h-1zM30 19h1v1h-1zM2 20h1v1h-1zM5 20h1v1h-1zM6 20h1v1h-1zM7 20h1v1h-1zM8 20h1v1h-1zM11 20h1v1h-1zM13 20h1v1h-1zM14 20h1v1h-1zM16 20h1v1h-1zM19 20h1v1h-1zM23 20h1v1h-1zM29 20h1v1h-1zM30 20h1v1h-1zM5 21h1v1h-1zM6 21h1v1h-1zM7 21h1v1h-1zM10 21h1v1h-1zM11 21h1v1h-1zM14 21h1v1h-1zM16 21h1v1h-1zM17 21h1v1h-1zM18 21h1v1h-1zM19 21h1v1h-1zM20 21h1v1h-1zM23 21h1v1h-1zM25 21h1v1h-1zM29 21h1v1h-1zM30 21h1v1h-1zM2 22h1v1h-1zM3 22h1v1h-1zM6 22h1v1h-1zM7 22h1v1h-1zM8 22h1v1h-1zM9 22h1v1h-1zM17 22h1v1h-1zM18 22h1v1h-1zM22 22h1v1h-1zM23 22h1v1h-1zM24 22h1v1h-1zM25 22h1v1h-1zM26 22h1v1h-1zM28 22h1v1h-1zM10 23h1v1h-1zM11 23h1v1h-1zM12 23h1v1h-1zM13 23h1v1h-1zM16 23h1v1h-1zM18 23h1v1h-1zM19 23h1v1h-1zM20 23h1v1h-1zM21 23h1v1h-1zM22 23h1v1h-1zM26 23h1v1h-1zM28 23h1v1h-1zM29 23h1v1h-1zM30 23h1v1h-1zM2 24h1v1h-1zM3 24h1v1h-1zM4 24h1v1h-1zM5 24h1v1h-1zM6 24h1v1h-1zM7 24h1v1h-1zM8 24h1v1h-1zM10 24h1v1h-1zM11 24h1v1h-1zM12 24h1v1h-1zM20 24h1v1h-1zM22 24h1v1h-1zM24 24h1v1h-1zM26 24h1v1h-1zM29 24h1v1h-1zM2 25h1v1h-1zM8 25h1v1h-1zM16 25h1v1h-1zM17 25h1v1h-1zM18 25h1v1h-1zM20 25h1v1h-1zM22 25h1v1h-1zM26 25h1v1h-1zM27 25h1v1h-1zM28 25h1v1h-1zM2 26h1v1h-1zM4 26h1v1h-1zM5 26h1v1h-1zM6 26h1v1h-1zM8 26h1v1h-1zM12 26h1v1h-1zM14 26h1v1h-1zM17 26h1v1h-1zM18 26h1v1h-1zM19 26h1v1h-1zM22 26h1v1h-1zM23 26h1v1h-1zM24 26h1v1h-1zM25 26h1v1h-1zM26 26h1v1h-1zM29 26h1v1h-1zM30 26h1v1h-1zM2 27h1v1h-1zM4 27h1v1h-1zM5 27h1v1h-1zM6 27h1v1h-1zM8 27h1v1h-1zM10 27h1v1h-1zM12 27h1v1h-1zM13 27h1v1h-1zM14 27h1v1h-1zM19 27h1v1h-1zM20 27h1v1h-1zM22 27h1v1h-1zM24 27h1v1h-1zM26 27h1v1h-1zM27 27h1v1h-1zM28 27h1v1h-1zM29 27h1v1h-1zM2 28h1v1h-1zM4 28h1v1h-1zM5 28h1v1h-1zM6 28h1v1h-1zM8 28h1v1h-1zM11 28h1v1h-1zM14 28h1v1h-1zM19 28h1v1h-1zM23 28h1v1h-1zM26 28h1v1h-1zM27 28h1v1h-1zM28 28h1v1h-1zM30 28h1v1h-1zM2 29h1v1h-1zM8 29h1v1h-1zM10 29h1v1h-1zM12 29h1v1h-1zM14 29h1v1h-1zM15 29h1v1h-1zM16 29h1v1h-1zM17 29h1v1h-1zM19 29h1v1h-1zM20 29h1v1h-1zM22 29h1v1h-1zM26 29h1v1h-1zM29 29h1v1h-1zM2 30h1v1h-1zM3 30h1v1h-1zM4 30h1v1h-1zM5 30h1v1h-1zM6 30h1v1h-1zM7 30h1v1h-1zM8 30h1v1h-1zM10 30h1v1h-1zM11 30h1v1h-1zM12 30h1v1h-1zM13 30h1v1h-1zM15 30h1v1h-1zM16 30h1v1h-1zM19 30h1v1h-1zM22 30h1v1h-1zM27 30h1v1h-1zM29 30h1v1h-1z"/></svg>'
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
<title>$(printf '%s' "$comp" | html_escape) – Live</title>
<style>
  :root { --bg:#000; --fg:#fff; --accent:#607b98; color-scheme:dark; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--fg); font:3.4vmin/1.35 system-ui, sans-serif; text-transform:uppercase; letter-spacing:.04em; }
  main { display:grid; grid-template-columns:1fr 38vh 1fr; gap:3vmin; padding:4vmin; }
  .gap { pointer-events:none; } /* empty middle column: the sword sits here */
  h2 { margin:0 0 1.5vmin; text-align:center; font-size:4.5vmin; color:var(--accent); font-weight:600; }
  ol { list-style:none; margin:0; padding:0; }
  li { background:rgba(0,0,0,.55); display:grid; grid-template-columns:7vmin 1fr auto; gap:2.5vmin; padding:1vmin 1.5vmin; border-bottom:1px solid #222; }
  li.final { background:var(--accent); border-color:var(--accent); font-weight:600; }
  li.empty { display:block; color:var(--accent); border:0; }
  .pos { text-align:right; }
  .name { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .score { font-variant-numeric:tabular-nums; }
  /* 3D spinning sword from the sign-up page, in the middle column between Men and Women */
  .scene { position:fixed; inset:0; z-index:-1; pointer-events:none; perspective:1200px; display:grid; place-items:center; opacity:.9; }
  .cover { position:relative; height:54vh; height:54svh; aspect-ratio:474/1277; transform-style:preserve-3d; animation:spin 16s linear infinite; }
  .cover img { position:absolute; inset:0; width:100%; height:100%; }
  @keyframes spin { from { transform:rotateX(15deg) rotateY(0) rotateZ(-10deg); } to { transform:rotateX(15deg) rotateY(360deg) rotateZ(-10deg); } }
  @media (prefers-reduced-motion: reduce) { .cover { animation:none; } }
  /* Clock above the sword, QR code below it, both in the middle column */
  .clock { position:fixed; top:3vh; left:50%; transform:translateX(-50%); font-size:8vh; font-weight:600; font-variant-numeric:tabular-nums; letter-spacing:.02em; }
  .qr { position:fixed; bottom:3vh; left:50%; transform:translateX(-50%); width:20vh; height:20vh; }
  .qr svg { display:block; width:100%; height:100%; }
</style>
</head>
<body>
<div class="scene" aria-hidden="true"><div class="cover" id="sword"></div></div>
<div class="clock" id="clock"></div>
<div class="qr" title="https://kragsentrale.co.za/qualifiers">$QR_SVG</div>
<main>
$(column mens "Men" "$rows")
<div class="gap"></div>
$(column womens "Women" "$rows")
</main>
<script>
(function () {
  // Build the 3D sword: 12 copies 1.5px apart; inner ones darker so the edge looks solid
  var sword = document.getElementById("sword"), N = 12;
  for (var i = 0; i < N; i++) {
    var img = new Image();
    img.src = "$SWORD_URL"; img.alt = "";
    img.style.transform = "translateZ(" + ((i - (N - 1) / 2) * 1.5) + "px)";
    if (i !== 0 && i !== N - 1) img.style.filter = "brightness(.45)";
    img.onerror = function () { if (sword.parentElement) sword.parentElement.remove(); };
    sword.appendChild(img);
  }
  // Clock above the sword
  var clock = document.getElementById("clock");
  function tick() { clock.textContent = new Date().toLocaleTimeString("en-ZA", { hour: "2-digit", minute: "2-digit", hour12: false }); }
  tick(); setInterval(tick, 1000);

  // Swap in fresh rankings without reloading, so the sword keeps spinning smoothly
  setInterval(function () {
    fetch(location.href, { cache: "no-store" })
      .then(function (r) { return r.text(); })
      .then(function (html) {
        var fresh = new DOMParser().parseFromString(html, "text/html").querySelector("main");
        if (fresh) document.querySelector("main").replaceWith(fresh);
      })
      .catch(function () {});
  }, $(( INTERVAL * 1000 )));
})();
</script>
</body>
</html>
HTML
}

run_scorer() { "$SCORER" $SCORER_ARGS --top-n 8 --verbosity 1 /dev/stdin <<< "$1"; }

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

