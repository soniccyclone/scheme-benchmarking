#!/usr/bin/env bash
# Fetch the phase 0 corpus into knowledge/sources/.
#
# No agents do this. It is a deterministic script so a rerun is free and a
# failure is diagnosable.
#
# Behaviour:
#   - sequential per host, parallel across hosts, so no single host is hammered
#   - exponential backoff with jitter, honouring Retry-After on 429 and 503
#   - resumable: a file already present with a recorded sha256 is skipped
#   - writes knowledge/sources/manifest.tsv, which is the tracked artifact
#
# Usage:
#   tools/fetch-sources.sh              fetch everything missing
#   tools/fetch-sources.sh --force      refetch even if present
#   tools/fetch-sources.sh --check      report status, download nothing
#   tools/fetch-sources.sh --jobs N     host-parallelism (default 6)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_TSV="$ROOT/tools/sources.tsv"
OUT_DIR="$ROOT/knowledge/sources"
MANIFEST="$OUT_DIR/manifest.tsv"
UA='Mozilla/5.0 (compatible; scheme-benchmarking-research/1.0)'

MAX_ATTEMPTS=5
BASE_DELAY=2
MAX_DELAY=120
CONNECT_TIMEOUT=20
MAX_TIME=300
JOBS=6
FORCE=0
CHECK_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --check) CHECK_ONLY=1 ;;
    --jobs)  JOBS="${2:?--jobs needs a number}"; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v sha256sum >/dev/null || { echo "sha256sum is required" >&2; exit 1; }
[ -f "$SRC_TSV" ] || { echo "missing $SRC_TSV" >&2; exit 1; }
mkdir -p "$OUT_DIR"

host_of() { printf '%s' "${1#*://}" | cut -d/ -f1; }

# sleep for Retry-After if it is a sane integer, else exponential backoff with jitter
backoff() {
  local attempt="$1" retry_after="$2" delay
  if [[ "$retry_after" =~ ^[0-9]+$ ]] && [ "$retry_after" -gt 0 ] && [ "$retry_after" -le "$MAX_DELAY" ]; then
    delay="$retry_after"
  else
    delay=$(( BASE_DELAY * (2 ** (attempt - 1)) ))
    [ "$delay" -gt "$MAX_DELAY" ] && delay="$MAX_DELAY"
    delay=$(( delay + RANDOM % 3 ))
  fi
  printf '      backoff %ss\n' "$delay" >&2
  sleep "$delay"
}

# fetch_one <slug> <section> <url> -> appends one manifest line to stdout
fetch_one() {
  local slug="$1" section="$2" url="$3"
  local dest="$OUT_DIR/$slug.pdf"
  local hdr rc code ctype retry_after sha bytes attempt=1

  if [ "$FORCE" -eq 0 ] && [ -s "$dest" ] && [ "$(head -c 4 "$dest")" = "%PDF" ]; then
    sha="$(sha256sum "$dest" | cut -d' ' -f1)"
    bytes="$(wc -c <"$dest" | tr -d ' ')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$slug" "$section" "$url" "cached" "$sha" "$bytes" "-" "$(date -u +%FT%TZ)"
    printf '  [skip] %s\n' "$slug" >&2
    return 0
  fi

  [ "$CHECK_ONLY" -eq 1 ] && { printf '  [would fetch] %s\n' "$slug" >&2; return 0; }

  hdr="$(mktemp)"
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    : >"$hdr"
    code="$(curl -sSL \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
        -A "$UA" -D "$hdr" -o "$dest.part" \
        -w '%{http_code}' "$url" 2>/dev/null)"
    rc=$?

    # A 200 is not proof of a PDF. Several hosts serve an HTML soft-404 with
    # status 200, which is exactly how 11 bad files got into an earlier run.
    if [ "$rc" -eq 0 ] && [ "$code" = "200" ] && [ -s "$dest.part" ] \
       && [ "$(head -c 4 "$dest.part")" != "%PDF" ]; then
      printf '  [FAIL] %s served %s but payload is not a PDF (%s bytes)\n' \
        "$slug" "$code" "$(wc -c <"$dest.part" | tr -d ' ')" >&2
      mv -f "$dest.part" "$dest.notpdf"
      rm -f "$hdr"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$slug" "$section" "$url" "not_pdf" "-" "0" "-" "$(date -u +%FT%TZ)"
      return 1
    fi

    if [ "$rc" -eq 0 ] && [ "$code" = "200" ] && [ -s "$dest.part" ]; then
      mv -f "$dest.part" "$dest"
      ctype="$(grep -i '^content-type:' "$hdr" | tail -1 | cut -d: -f2- | tr -d '\r' | xargs || true)"
      sha="$(sha256sum "$dest" | cut -d' ' -f1)"
      bytes="$(wc -c <"$dest" | tr -d ' ')"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$slug" "$section" "$url" "ok" "$sha" "$bytes" "${ctype:--}" "$(date -u +%FT%TZ)"
      printf '  [ok]   %s (%s bytes)\n' "$slug" "$bytes" >&2
      rm -f "$hdr"; return 0
    fi

    # retryable: rate limit, server error, or transport failure
    case "$code" in
      202|429|500|502|503|504|000)
        retry_after="$(grep -i '^retry-after:' "$hdr" | tail -1 | cut -d: -f2- | tr -d '\r' | xargs || true)"
        printf '    [retry %d/%d] %s http=%s rc=%s\n' \
          "$attempt" "$MAX_ATTEMPTS" "$slug" "$code" "$rc" >&2
        backoff "$attempt" "${retry_after:-}"
        attempt=$(( attempt + 1 ))
        ;;
      *)
        printf '  [FAIL] %s http=%s (not retryable)\n' "$slug" "$code" >&2
        rm -f "$dest.part" "$hdr"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$slug" "$section" "$url" "http_$code" "-" "0" "-" "$(date -u +%FT%TZ)"
        return 1
        ;;
    esac
  done

  printf '  [FAIL] %s exhausted %d attempts\n' "$slug" "$MAX_ATTEMPTS" >&2
  rm -f "$dest.part" "$hdr"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$slug" "$section" "$url" "exhausted" "-" "0" "-" "$(date -u +%FT%TZ)"
  return 1
}

# one worker per host, entries within a host handled in order
run_host() {
  local host="$1" line slug section url
  while IFS=$'\t' read -r slug section url; do
    [ -z "${slug:-}" ] && continue
    fetch_one "$slug" "$section" "$url" >>"$OUT_DIR/.partial.$host.tsv"
    sleep 1   # courtesy gap between requests to the same host
  done
}

printf 'phase 0 corpus fetch\n' >&2
printf '  source list : %s\n' "$SRC_TSV" >&2
printf '  destination : %s\n' "$OUT_DIR" >&2

rm -f "$OUT_DIR"/.partial.*.tsv

# group by host
declare -A HOSTS=()
while IFS=$'\t' read -r slug section url; do
  case "$slug" in ''|\#*) continue ;; esac
  h="$(host_of "$url")"
  HOSTS["$h"]=1
  printf '%s\t%s\t%s\n' "$slug" "$section" "$url" >>"$OUT_DIR/.queue.$h.tsv"
done < <(tail -n +2 "$SRC_TSV")

printf '  hosts       : %d, parallelism %d\n\n' "${#HOSTS[@]}" "$JOBS" >&2

running=0
for h in "${!HOSTS[@]}"; do
  run_host "$h" < "$OUT_DIR/.queue.$h.tsv" &
  running=$(( running + 1 ))
  if [ "$running" -ge "$JOBS" ]; then wait -n 2>/dev/null || wait; running=$(( running - 1 )); fi
done
wait

if [ "$CHECK_ONLY" -eq 0 ]; then
  {
    printf '# slug\tsection\turl\tstatus\tsha256\tbytes\tcontent_type\tfetched_at\n'
    cat "$OUT_DIR"/.partial.*.tsv 2>/dev/null | sort
  } >"$MANIFEST"
fi
rm -f "$OUT_DIR"/.partial.*.tsv "$OUT_DIR"/.queue.*.tsv

if [ -f "$MANIFEST" ]; then
  total=$(( $(wc -l <"$MANIFEST") - 1 ))
  ok=$(awk -F'\t' '$4=="ok"{n++} END{print n+0}' "$MANIFEST")
  cached=$(awk -F'\t' '$4=="cached"{n++} END{print n+0}' "$MANIFEST")
  bad=$(awk -F'\t' 'NR>1 && $4!="ok" && $4!="cached"{n++} END{print n+0}' "$MANIFEST")
  printf '\nfetched %s, cached %s, failed %s, of %s\n' "$ok" "$cached" "$bad" "$total" >&2
  if [ "$bad" -gt 0 ]; then
    printf '\nfailures:\n' >&2
    awk -F'\t' 'NR>1 && $4!="ok" && $4!="cached"{printf "  %-12s %s\n  %s\n", $4, $1, $3}' "$MANIFEST" >&2
    exit 1
  fi
fi
