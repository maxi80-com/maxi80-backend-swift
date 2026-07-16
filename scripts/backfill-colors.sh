#!/usr/bin/env bash
#
# One-off migration: convert every v2/<artist>/<title>/metadata.json from the old single-`color`
# field to the new `colors` palette (bg + text1..4), sourced from the co-located search.json.
# No Apple Music calls — search.json already contains Apple's palette. ~2,571 tracks, ~$0.02.
#
# The chosen song matches the collector's selectBestMatch: first song WITH artwork, else first song.
#
# DEFAULT IS DRY-RUN. Pass --apply to actually write. Idempotent; safe to re-run.
#
# Usage:
#   scripts/backfill-colors.sh            # dry-run: report only
#   scripts/backfill-colors.sh --apply    # perform the migration
#   AWS_PROFILE=maxi80 scripts/backfill-colors.sh --apply
#
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-maxi80}"
AWS_REGION="${AWS_REGION:-eu-central-1}"
BUCKET="${BUCKET:-artwork.maxi80.com}"
PREFIX="${PREFIX:-v2}"

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 1; }

aws() { command aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }

echo "Mode:   $([ $APPLY -eq 1 ] && echo APPLY || echo 'DRY-RUN (pass --apply to write)')"
echo "Bucket: s3://$BUCKET/$PREFIX/"
echo

# jq program: given a search.json, emit the palette JSON object or empty on failure.
# Picks first song with artwork, else first song; normalizes each hex to #UPPER; requires all 5.
read -r -d '' JQ_PALETTE <<'JQ' || true
def norm:
  if type=="string" and test("^#?[0-9a-fA-F]{6}$")
  then (ltrimstr("#") | ascii_upcase | "#" + .)
  else null end;
(.results.songs.data // []) as $songs
| ( [ $songs[] | select(.attributes.artwork != null) ][0] // $songs[0] ) as $song
| ($song.attributes.artwork) as $a
| if $a == null then empty
  else
    { bg: ($a.bgColor|norm),
      text1: ($a.textColor1|norm), text2: ($a.textColor2|norm),
      text3: ($a.textColor3|norm), text4: ($a.textColor4|norm) }
    | if (to_entries | all(.value != null)) then . else empty end
  end
JQ

converted=0; skipped=0; unchanged=0; total=0

# List every metadata.json key under the prefix.
while IFS= read -r key; do
  [ -z "$key" ] && continue
  total=$((total+1))
  dir="${key%/metadata.json}"
  search_key="$dir/search.json"

  meta_json="$(aws s3 cp "s3://$BUCKET/$key" - 2>/dev/null || true)"
  [ -z "$meta_json" ] && { echo "SKIP (no metadata): $key"; skipped=$((skipped+1)); continue; }

  # Already migrated? has colors and no legacy color -> leave as is.
  if echo "$meta_json" | jq -e 'has("colors") and (has("color")|not)' >/dev/null 2>&1; then
    unchanged=$((unchanged+1)); continue
  fi

  search_json="$(aws s3 cp "s3://$BUCKET/$search_key" - 2>/dev/null || true)"
  [ -z "$search_json" ] && { echo "SKIP (no search.json): $dir"; skipped=$((skipped+1)); continue; }

  palette="$(echo "$search_json" | jq -c "$JQ_PALETTE" 2>/dev/null || true)"
  [ -z "$palette" ] && { echo "SKIP (no usable palette): $dir"; skipped=$((skipped+1)); continue; }

  # Merge: add colors, drop legacy color.
  new_meta="$(echo "$meta_json" | jq -c --argjson c "$palette" '.colors=$c | del(.color)')"

  if [ $APPLY -eq 1 ]; then
    echo "$new_meta" | aws s3 cp - "s3://$BUCKET/$key" --content-type application/json >/dev/null
    echo "CONVERTED: $dir -> $palette"
  else
    echo "WOULD CONVERT: $dir -> $palette"
  fi
  converted=$((converted+1))
done < <(aws s3 ls "s3://$BUCKET/$PREFIX/" --recursive | sed -E 's/^[0-9-]+ +[0-9:]+ +[0-9]+ +//' | grep '/metadata.json$')

echo
echo "── Summary ─────────────────────────────"
echo "total metadata.json: $total"
echo "converted:           $converted$([ $APPLY -eq 0 ] && echo ' (dry-run, not written)')"
echo "already migrated:    $unchanged"
echo "skipped:             $skipped"
