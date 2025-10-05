# XMP Utilities

Extensions of Unix CLI utilities supporting filtering with XMP metadata awareness. These scripts provide powerful tools for managing photo collections based on XMP metadata embedded in files or stored in XMP sidecar files.

## Compatibility

- **Linux**: Fully supported and tested
- **WSL2 (Windows Subsystem for Linux 2) on Windows 11**: Fully compatible
- **macOS**: Not yet tested, but should work with proper dependencies

## Dependencies

- **ExifTool**: Required for all metadata operations
  - Linux: `sudo apt install libimage-exiftool-perl` or `sudo dnf install perl-Image-ExifTool`
  - WSL2: Same as Linux
  - macOS: `brew install exiftool`
- **GNU findutils**: Optional but recommended for `xmp_find.sh`
- **rsync**: Required for `xmp_rsync.sh`

## Scripts Overview

### xmp_find.sh

A powerful file discovery tool that uses ExifTool to find files based on XMP metadata criteria. It builds a filtered set of files and then optionally runs GNU `find` commands on that set.

**Key Features:**
- Searches both embedded XMP metadata and XMP sidecar files
- Supports complex ExifTool expressions for filtering
- Compatible with older ExifTool versions (automatic fallback for missing `-0` flag)
- Integrates with GNU find for advanced file operations
- Custom output formatting support

**Usage:**
```bash
xmp_find.sh ROOT [--if 'EXPR' | --argfile file ...]
          [--ext 'jpg,jpeg,tif,tiff,dng,cr3,arw,raf'] [--include-sidecars]
          [--find-args '...raw args for find...'] [--print0]
```

**Examples:**
```bash
# Find files with rating >= 3 and print as NUL-delimited list
xmp_find.sh ~/photos --if '$XMP:Rating >= 3' --print0

# Use argfile filter and show file sizes with GNU find
xmp_find.sh ~/photos --argfile bash/exif_filters/family-keyword.args \
   --find-args '-printf %p\\ %s\\n'

# Find and delete XMP sidecars for rejected images (use with caution!)
xmp_find.sh ~/photos --if '$XMP:Label eq "Reject"' \
   --include-sidecars --find-args '-name *.xmp -delete'

# Custom formatted output showing file paths and ratings
xmp_find.sh ~/photos --if '$XMP:Rating >= 3' -p '$FilePath [$XMP:Rating]'
```

### xmp_rsync.sh

Synchronizes files filtered by XMP metadata using rsync, maintaining directory structure while only copying files that match specified criteria.

**Key Features:**
- Filters files based on XMP metadata before syncing
- Preserves directory structure relative to source
- Supports both embedded XMP and sidecar files
- Includes comprehensive logging and progress reporting
- Flexible rsync argument passing

**Usage:**
```bash
xmp_rsync.sh SRC DEST [--if 'EXPR' | --argfile file ...]
           [--ext 'jpg,jpeg,tif,tiff,dng,cr3,arw,raf'] [--include-sidecars]
           [--rsync-args '...'] [--verbose|-v] [--debug]
```

**Examples:**
```bash
# Sync only files with rating 3 or higher
xmp_rsync.sh ~/photos ~/backup --argfile bash/exif_filters/rating3plus.args

# Dry run with custom rsync arguments and verbose output
xmp_rsync.sh ~/photos ~/backup --if '$XMP:Rating >= 3' \
   --rsync-args '--dry-run --stats' -v

# Sync family photos based on keywords
xmp_rsync.sh ~/photos ~/family_backup --argfile bash/exif_filters/family-keyword.args --verbose
```

## EXIF Filter Files

The `bash/exif_filters/` directory contains predefined ExifTool argument files for common filtering scenarios:

### ext.args
Defines additional file extensions to process:
```
-ext CR3
-ext CR2 
-ext RAF
-ext TIF
-ext cr3
```

### family-keyword.args
Filters for family-related photos using hierarchical subjects or keywords:
```
-if
$XMP:HierarchicalSubject =~ /Family/i or $XMP:Subject =~ /\bFamily\b/i
```

### rating3plus.args
Filters for photos with rating 3 or higher:
```
-if
$XMP:Rating ge 3
```

## ExifTool Expression Examples

The scripts support complex ExifTool expressions for sophisticated filtering:

```bash
# Rating-based filters
'$XMP:Rating >= 3'
'$XMP:Rating eq 5'

# Label-based filters
'$XMP:Label eq "Red"'
'$XMP:Label ne "Reject"'

# Keyword searches (case-insensitive)
'$XMP:HierarchicalSubject =~ /Family/i'
'$XMP:Subject =~ /\bVacation\b/i'

# Date range filtering
'$DateTimeOriginal ge "2025:08:01 00:00:00" and $DateTimeOriginal lt "2025:09:01 00:00:00"'

# Complex combinations
'($XMP:Rating >= 3 or $XMP:Label eq "Green") and $XMP:HierarchicalSubject =~ /Family/i'
```

## File Extensions

Default supported extensions include:
- **RAW formats**: dng, cr2, cr3, nef, nrw, arw, raf, orf, rw2
- **Standard formats**: jpg, jpeg, tif, tiff
- **Modern formats**: heic, mp4, mov

Use `--ext` to specify custom extensions as a comma-separated list.

## Tips and Best Practices

1. **Always test with dry run**: Use `--rsync-args '--dry-run'` to preview operations
2. **Use single quotes**: Wrap ExifTool expressions in single quotes to prevent shell interpretation
3. **Leverage argfiles**: Create reusable filter files for common scenarios
4. **Check sidecar files**: Use `--include-sidecars` when working with software that stores metadata externally
5. **Monitor performance**: Use `--verbose` and `--debug` flags for troubleshooting large operations

## Configuration

Both scripts reference `$HOME/.roaming/config/exif_filters/ext.args` by default. Create this directory structure and populate with your preferred extensions and filters.

## Troubleshooting

- **ExifTool not found**: Install ExifTool using your system's package manager
- **Non-GNU find detected**: The script will fallback to printing NUL-delimited lists for use with `xargs -0`
- **Permission errors**: Ensure read access to source directories and write access to destination
- **Large file sets**: Use `--debug` to monitor progress and consider breaking large operations into smaller chunks
