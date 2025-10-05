#!/usr/bin/env bash
# xmp_find.sh (WSL-safe, no -0 required)
# 
# xmp_find.sh
# Build an ExifTool-selected (embedded + sidecar) set, then:
#   - if GNU find is available: run `find -files0-from <list> <your find args...>`
#   - else: print the NUL list to stdout (pipe to xargs -0/find fallback yourself)
#
# Usage:
#   xmp_find.sh ROOT [--if 'EXPR' | --argfile file ...]
#             [--ext 'jpg,jpeg,tif,tiff,dng,cr3,arw,raf'] [--include-sidecars]
#             [--find-args '...raw args for find...'] [--print0]
#
# Examples:
#   # print NUL-delimited list for rating>=3
#   xmp_find.sh ~/photos --if '$XMP:Rating >= 3' --print0
#
#   # GNU find: show sizes of the selected set
#   xmp_find.sh ~/photos --argfile filters/family-keyword.args \
#      --find-args '-printf %p\\ %s\\n'
#
#   # delete only .xmp sidecars for the selected set (careful!)
#   xmp_find.sh ~/photos --if '$XMP:Label eq "Reject"' \
#      --include-sidecars --find-args '-name *.xmp -delete'
#



#set -euo pipefail

#set -x  # Change this line - was "echo on"

die(){ echo "Error: $*" >&2; exit 1; }
log(){ printf '[xmp_find] %s\n' "$*" >&2; }

ROOT="${1:-}"; [[ -n "$ROOT" ]] || die "Missing ROOT"
ROOT_REAL="$(readlink -f "$ROOT")" || die "Cannot resolve ROOT path: $ROOT"
shift || true

IF_EXPR=""
ARGFILES=()
EXTS_DEFAULT="jpg,jpeg,tif,tiff,dng,cr2,CR3,nef,nrw,arw,raf,orf,rw2,heic,mp4,mov"
EXTS="$EXTS_DEFAULT"
INCLUDE_SIDECARS=0
FIND_ARGS=()
PRINT0=0
PRINT_FORMAT=""
DEBUG=0
EXIFTOOL_CMD="exiftool -m --argfile $HOME/.roaming/config/exif_filters/ext.args"


while [[ $# -gt 0 ]]; do
  case "$1" in
    --if) shift; IF_EXPR="${1:-}"; [[ -n "$IF_EXPR" ]] || die "--if needs an expression"; shift;;
    --argfile|-@) shift; ARGFILES+=("$1"); shift;;
    --ext) shift; EXTS="${1:-}"; shift;;
    --include-sidecars) INCLUDE_SIDECARS=1; shift;;
    --find-args) shift; [[ -n "${1:-}" ]] || die "--find-args needs a string"; FIND_ARGS+=("$1"); shift;;
    --print0) PRINT0=1; shift;;
    -p|--print) shift; PRINT_FORMAT="${1:-}"; [[ -n "$PRINT_FORMAT" ]] || die "-p needs a format string"; shift;;
    --debug) DEBUG=1; shift;;
    -*) die "Unknown option: $1";;
    *) break;;
  esac
done

command -v exiftool >/dev/null 2>&1 || die "exiftool not found"

# Extensions -> exiftool -ext args
readarray -td, EXT_ARR < <(printf '%s' "$EXTS"); unset 'EXT_ARR[-1]' || true
EXT_ARGS=()
for e in "${EXT_ARR[@]}"; do e="${e,,}"; EXT_ARGS+=( -ext "$e" ); done

## Debug output
if [[ $DEBUG -eq 1 ]]; then
  printf '[DEBUG] Extensions: %s\n' "$EXTS" >&2
  printf '[DEBUG] Extension args: %s\n' "${EXT_ARGS[*]}" >&2
  printf '[DEBUG] Full command: %s %s\n' "$EXIFTOOL_CMD" "${EXIF_ARGS[*]}" >&2
fi

# Common exiftool args (quiet, tolerant)
EXIF_ARGS=(-r -fast2 -m -q -q "${EXT_ARGS[@]}")
for a in "${ARGFILES[@]}"; do [[ -f "$a" ]] || die "argfile not found: $a"; EXIF_ARGS+=( -@ "$a" ); done
[[ -n "$IF_EXPR" ]] && EXIF_ARGS+=( -if "$IF_EXPR" )

# Proper "-@ file" pairs for sidecar pass
SIDE_ARGS=(); for a in "${ARGFILES[@]}"; do SIDE_ARGS+=( -@ "$a" ); done

# Detect -0 support; use newline->NUL fallback if missing
NULLFLAG=(); NUL_FALLBACK=1
if exiftool -0 -ver >/dev/null 2>&1; then
  NULLFLAG=(-0); NUL_FALLBACK=0
fi

tmp_all="$(mktemp)"; tmp_sorted="$(mktemp)"
cleanup(){ rm -f "$tmp_all" "$tmp_sorted"; }; trap cleanup EXIT

# Helper: run exiftool path print with NUL output regardless of -0 support
exif_paths_nul() {
  # args: exiftool ... then we append (-p '$FilePath' .)
  if [[ $NUL_FALLBACK -eq 0 ]]; then
    $EXIFTOOL_CMD "$@" -p '$FilePath' .
  else
    # newline output -> convert to NULs
    $EXIFTOOL_CMD "$@" -p '$FilePath' . | awk '{printf "%s\0",$0}'
  fi
}

(
  cd "$ROOT_REAL" || exit 1

  # (A) Embedded matches in primaries
  exif_paths_nul "${EXIF_ARGS[@]}" "${NULLFLAG[@]}"

  # (B) Sidecar matches -> map to primaries
  exif_paths_nul -r -fast2 -m -q -q -ext xmp "${SIDE_ARGS[@]}" ${IF_EXPR:+-if "$IF_EXPR"} |
  sed -z 's/\.xmp$//' |
  while IFS= read -r -d '' base; do
      for e in "${EXT_ARR[@]}"; do
        f="${base}.${e}"
        if [[ -f "$f" ]]; then printf '%s\0' "$f"; break; fi
      done
    done

  # (C) optionally include sidecars themselves
  if [[ $INCLUDE_SIDECARS -eq 1 ]]; then
    exif_paths_nul "${EXIF_ARGS[@]}" "${NULLFLAG[@]}" \
    | while IFS= read -r -d '' p; do
        base="${p%.*}"
        [[ -f "${base}.xmp" ]] && printf '%s\0' "${base}.xmp"
      done
  fi
) > "$tmp_all"

# Deduplicate NUL list
sort -z -u "$tmp_all" > "$tmp_sorted"
SEL_COUNT=$(tr -cd '\0' < "$tmp_sorted" | wc -c | tr -d ' ')

if [[ $DEBUG -eq 1 ]]; then
  printf '[DEBUG] "Selected files: %d" \n' "$SEL_COUNT" >&2
fi



# If custom print format specified, use ExifTool to format output
if [[ -n "$PRINT_FORMAT" ]]; then
  cd "$ROOT_REAL" || exit 1
  while IFS= read -r -d '' filepath; do
    # Convert absolute path back to relative for ExifTool
    relpath="${filepath#$PWD/}"
    computed_path="$ROOT${filepath#$ROOT_REAL}"
    if [[ -f "$relpath" ]]; then
      # Check if XMP sidecar exists and read from it for XMP tags
      base="${relpath%.*}"
      if [[ -f "${base}.xmp" ]]; then
        # First try to get the rating from the XMP file, fallback to main file
        rating=$(exiftool -s -s -s -XMP:Rating "${base}.xmp" 2>/dev/null)
        [[ -z "$rating" ]] && rating=$(exiftool -s -s -s -XMP:Rating "$relpath" 2>/dev/null)
        [[ -z "$rating" ]] && rating="0"
        
        # Replace placeholders in the format string
        format_with_rating="${PRINT_FORMAT//\$FilePath/$computed_path}"
        format_with_rating="${format_with_rating//\$XMP:Rating/$rating}"
        exiftool -m -p "$format_with_rating" "$relpath" 2>/dev/null
      else
        # Process just the main file
        format_with_rating="${PRINT_FORMAT//\$FilePath/$computed_path}"
        exiftool -m -p "$format_with_rating" "$relpath" 2>/dev/null
      fi
    fi
  done < "$tmp_sorted"
  exit 0
fi

# If requested, emit the NUL list and exit
if [[ $PRINT0 -eq 1 ]]; then
  cat "$tmp_sorted"
  exit 0
fi

# Use GNU find if available; otherwise emit list to stdout
if command -v find >/dev/null 2>&1 && find --version 2>/dev/null | grep -qi 'GNU findutils'; then
  if [[ ${#FIND_ARGS[@]} -eq 0 ]]; then
    find -files0-from "$tmp_sorted" -print
  else
    # shellcheck disable=SC2086
    eval "find -files0-from \"${tmp_sorted}\" ${FIND_ARGS[*]}"
  fi
else
  log "Non-GNU find detected; printing NUL list to stdout. Pipe to: xargs -0 …"
  cat "$tmp_sorted"
fi
