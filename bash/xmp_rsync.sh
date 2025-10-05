#!/usr/bin/env bash
# xmp_rsync.sh
# Rsync files filtered by XMP metadata using ExifTool
#
# Usage:
#   xmp_rsync.sh SRC DEST [--if 'EXPR' | --argfile file ...]
#             [--ext 'jpg,jpeg,tif,tiff,dng,cr3,arw,raf'] [--include-sidecars]
#             [--rsync-args '...'] [--verbose|-v] [--debug]
#
# Examples:
#   # Basic usage with argfile
#   xmp_rsync.sh ~/photos ~/backup --argfile ~/.roaming/config/exif_filters/rating3plus.args 
#
#   # With custom rsync arguments and verbose mode
#   xmp_rsync.sh ~/photos ~/backup --if '$XMP:Rating >= 3' --rsync-args '--dry-run --stats' -v
#
# IF expression examples (quotes required):
#   '$XMP:Rating >= 3'
#   '$XMP:Label eq "Red"'
#   '$XMP:HierarchicalSubject =~ /Family/i'
#   '$DateTimeOriginal ge "2025:08:01 00:00:00" and $DateTimeOriginal lt "2025:09:01 00:00:00"'
#



#set -euo pipefail

#set -x  # Change this line - was "echo on"

die(){ echo "Error: $*" >&2; exit 1; }
log(){ printf '[xmp_rsync] %s\n' "$*" >&2; }

# Usage function  
usage() {
cat >&2 << 'EOF'
Usage: xmp_rsync.sh SRC DEST [OPTIONS]

OPTIONS:
  --if 'EXPRESSION'      ExifTool -if expression (single quotes recommended)
  --argfile FILE         ExifTool argfile containing options
  --ext 'ext1,ext2'      Comma-separated extensions (default: jpg,jpeg,tif,tiff,dng,cr2,cr3,nef,nrw,arw,raf,orf,rw2,heic,mp4,mov)
  --include-sidecars     Include .xmp sidecar files in output
  --rsync-args 'ARGS'    Additional arguments to pass to rsync
  --verbose, -v          Show verbose output during file discovery
  --debug                Show debug information
  --help, -h             Show this help

Examples:
  xmp_rsync.sh ~/photos ~/backup --argfile ~/.roaming/config/exif_filters/rating3plus.args
  xmp_rsync.sh ~/photos ~/backup --if '$XMP:Rating >= 3' --verbose --rsync-args '--dry-run'
EOF
}

# Parse arguments
SRC="${1:-}"; DEST="${2:-}"
[[ -n "$SRC" ]] || die "Missing SRC directory"
[[ -n "$DEST" ]] || die "Missing DEST directory"
SRC_REAL="$(readlink -f "$SRC")" || die "Cannot resolve SRC path: $SRC"
shift 2 || true

IF_EXPR=""
ARGFILES=()
EXTS_DEFAULT="jpg,jpeg,tif,tiff,dng,cr2,cr3,nef,nrw,arw,raf,orf,rw2,heic,mp4,mov"
EXTS="$EXTS_DEFAULT"
INCLUDE_SIDECARS=0
RSYNC_ARGS=()
DEBUG=0
VERBOSE=0
EXIFTOOL_CMD="exiftool -m --argfile $HOME/.roaming/config/exif_filters/ext.args"


while [[ $# -gt 0 ]]; do
  case "$1" in
    --if) shift; IF_EXPR="${1:-}"; [[ -n "$IF_EXPR" ]] || die "--if needs an expression";;
    --argfile|-@) shift; ARGFILES+=("$1");;
    --ext) shift; EXTS="${1:-}";;
    --include-sidecars) INCLUDE_SIDECARS=1;;
    --rsync-args) shift; [[ -n "${1:-}" ]] || die "--rsync-args needs arguments"; RSYNC_ARGS+=("$1");;
    --verbose|-v) VERBOSE=1;;
    --debug) DEBUG=1;;
    --help|-h) usage; exit 0;;
    -*) die "Unknown option: $1";;
    *) break;;
  esac
  shift || true
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

echo "Using exiftool command: $EXIFTOOL_CMD"

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
  cd "$SRC_REAL" || exit 1

  # (A) Embedded matches in primaries
  [[ $VERBOSE -eq 1 ]] && log "Scanning for files with embedded metadata..."
  exif_paths_nul "${EXIF_ARGS[@]}" "${NULLFLAG[@]}" | while IFS= read -r -d '' filepath; do
    [[ -z "$filepath" ]] && continue
    relpath="${filepath#$PWD/}"
    [[ $VERBOSE -eq 1 ]] && log "Found [embedded]: $relpath"
    printf '%s\0' "$relpath"
  done

  # (B) Sidecar matches -> map to primaries
  [[ $VERBOSE -eq 1 ]] && log "Scanning for files with XMP sidecar metadata..."
  exif_paths_nul -r -fast2 -m -q -q -ext xmp "${SIDE_ARGS[@]}" ${IF_EXPR:+-if "$IF_EXPR"} |
  sed -z 's/\.xmp$//' |
  while IFS= read -r -d '' base; do
      relpath="${base#$PWD/}"
      for e in "${EXT_ARR[@]}"; do
        f="${base}.${e}"
        if [[ -f "$f" ]]; then 
          f_rel="${f#$PWD/}"
          [[ $VERBOSE -eq 1 ]] && log "Found [sidecar]: $f_rel via ${relpath}.xmp"
          printf '%s\0' "$f_rel"
          break
        fi
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
log "Selected files: $SEL_COUNT"

# If custom print format specified, use ExifTool to format output
if [[ -n "$PRINT_FORMAT" ]]; then
  cd "$ROOT" || exit 1
  while IFS= read -r -d '' filepath; do
    # Convert absolute path back to relative for ExifTool
    relpath="${filepath#$PWD/}"
    if [[ -f "$relpath" ]]; then
      # Check if XMP sidecar exists and read from it for XMP tags
      base="${relpath%.*}"
      if [[ -f "${base}.xmp" ]]; then
        # Create a temporary combined read using process substitution
        # First try to get the rating from the XMP file, fallback to main file
        rating=$(exiftool -s -s -s -XMP:Rating "${base}.xmp" 2>/dev/null)
        [[ -z "$rating" ]] && rating=$(exiftool -s -s -s -XMP:Rating "$relpath" 2>/dev/null)
        [[ -z "$rating" ]] && rating="0"
        
        # Replace $XMP:Rating in the format string with the actual rating
        format_with_rating="${PRINT_FORMAT//\$XMP:Rating/$rating}"
        exiftool -m -p "$format_with_rating" "$relpath" 2>/dev/null
      else
        # Process just the main file
        exiftool -m -p "$PRINT_FORMAT" "$relpath" 2>/dev/null
      fi
    fi
  done < "$tmp_sorted"
  exit 0
fi

# Validate directories and create destination
[[ -d "$SRC" ]] || die "SRC directory does not exist: $SRC"
mkdir -p "$DEST" || die "Cannot create DEST directory: $DEST"

# Count selected files
SEL_COUNT=$(tr '\0' '\n' < "$tmp_sorted" | wc -l)
log "Selected $SEL_COUNT files"

# Debug: show first few files
if [[ $DEBUG -eq 1 ]]; then
  printf '[DEBUG] Files to sync:\n' >&2
  tr '\0' '\n' < "$tmp_sorted" | head -10 >&2
  [[ $SEL_COUNT -gt 10 ]] && printf '[DEBUG] ... and %d more\n' $((SEL_COUNT - 10)) >&2
fi

# Sync only those files, keeping directory structure relative to SRC
log "Starting rsync..."
if [[ ${#RSYNC_ARGS[@]} -eq 0 ]]; then
  rsync -av --from0 --files-from="$tmp_sorted" "$SRC/" "$DEST/" 2> >(grep '^rsync:' >&2 || true)
else
  rsync -av --from0 --files-from="$tmp_sorted" "${RSYNC_ARGS[@]}" "$SRC/" "$DEST/" 2> >(grep '^rsync:' >&2 || true)
fi
log "Rsync completed"
