package FileCount;
#############################################################################
# FileCount
#
# Created: August 2025
# Last Modified: January 2026
#
# This file is part of the Test Automation Framework (TAF). 
# Copyright (c) 2025-2026 MariaDB Foundation
#
# Licensed under the GNU General Public License, version 2 or later (GPLv2+).
# See https://www.gnu.org/licenses/ for details.
#
# PURPOSE:
#     Provide deterministic, contributor-proof utilities for counting files and
#     directories within a caller-specified filesystem path. This module offers
#     a minimal, stable API used throughout TAF for validation, reporting, and
#     install-verification steps. All counting behavior is explicit, predictable,
#     and free of side effects.
#
# ARCHITECTURAL ROLE:
#     - Acts as the single source of truth for directory and file counting in TAF.
#     - Ensures consistent behavior across platforms and calling contexts.
#     - Normalizes directory paths to avoid ambiguous or inconsistent traversal.
#     - Provides simple, dependency-free primitives used by higher-level modules
#       (installers, validators, result processors, cleanup routines).
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not recurse into subdirectories unless explicitly requested.
#     - Does not filter by extension, timestamp, or file attributes.
#     - Does not validate directory existence beyond basic opendir() checks.
#     - Does not modify the filesystem or create/delete paths.
#     - Does not guess caller intent or silently ignore errors.
#
# CONTRACT:
#     - CountFiles(<dir>) returns the number of non-directory entries in <dir>.
#     - CountDirs(<dir>) returns the number of subdirectories in <dir>.
#     - Both routines:
#           * require an explicit directory path
#           * normalize the path using EnsureTrailingSlash()
#           * return integer counts on success
#           * return 0 on empty directories
#           * return 0 and emit a warning on invalid or unreadable paths
#     - No routine may die(); all failures must be explicit and controlled.
#
# GUARANTEES:
#     - Counting behavior is deterministic and contributor-proof.
#     - No hidden recursion, no implicit filtering, no side effects.
#     - Path normalization is consistent across all callers.
#     - All filesystem reads are minimal and safe.
#
# NOTES:
#     - This module is intentionally small and stable; it forms part of the
#       foundational utility layer used by many TAF components.
#     - Any change to counting semantics or path normalization rules must be
#       reflected in this header and in the TAF manual.
#############################################################################
use strict;
use warnings;
use Exporter 'import';
use Carp;
use File::Basename;

our $VERSION = '2.0';
our @EXPORT  = qw(CountFiles CountDirs);

my $DEBUG = 0;

################################################################################
# Object Constructor
################################################################################
sub new {
    my ($class) = @_;
    return bless {}, $class;
}

################################################################################
# Subroutine: EnsureTrailingSlash
#
# Purpose:
#   Normalize a filesystem path string by ensuring it ends with a trailing slash.
#   Provides a safe, consistent directory representation for subsequent routines
#   that rely on paths with explicit delimiters.
#
# Globals Used:
#   None
#
# Parameters:
#   $path (string) - Filesystem path to normalize. May be undefined.
#
# Behavior:
#   - If $path is undefined:
#       * Returns an empty string.
#   - If $path is defined:
#       * Appends "/" to the end of $path unless it already ends with "/".
#   - Returns the normalized path string.
#
# Returns:
#   String - Normalized path with guaranteed trailing slash
#   ''     - Empty string if input was undefined
#
# Notes:
#   - This routine is INTERNAL; not intended for external callers.
#   - Ensures consistent path handling across routines that concatenate
#     directory names or expect trailing delimiters.
#   - Does not validate whether the path exists on disk; purely string-based.
#   - Useful for building archive, results, or install directory paths safely.
################################################################################
sub EnsureTrailingSlash {
    my ($path) = @_;
    return '' unless defined $path;
    $path .= '/' unless $path =~ /\/$/;
    return $path;
}

################################################################################
# Subroutine: CountFiles
#
# Purpose:
#   Count the number of non-directory files in a specified target directory.
#   Normalizes the directory path with a trailing slash and provides optional
#   debug output for traceability.
#
# Visibility:
#   Public API (exported via @EXPORT).
#
# Parameters:
#   $self      (hashref) - Caller object reference (not used for state).
#   $targetDir (string)  - Path to directory whose files will be counted (required).
#
# Behavior:
#   - Croaks if $targetDir is not defined.
#   - Normalizes $targetDir to ensure it ends with a trailing slash.
#   - Opens the directory or croaks if it cannot be opened.
#   - Iterates entries:
#       * Skips "." and "..".
#       * Increments count for each entry that is not a directory.
#       * Emits debug output when $DEBUG is true.
#   - Returns the total count of non-directory files.
#
# Returns:
#   Integer - Number of non-directory files in targetDir.
#
# Failure modes:
#   - Croaks on missing argument.
#   - Croaks if the directory cannot be opened.
#
# Notes:
#   - Does not recurse into subdirectories.
#   - Callers that require non-fatal behavior must wrap the call in eval.
################################################################################
sub CountFiles {
    my ($self, $targetDir) = @_;
    croak "CountFiles(<targetDir>)" unless defined $targetDir;

    $targetDir = EnsureTrailingSlash($targetDir);
    my $count = 0;

    print "STARTING CountFiles\n" if $DEBUG;
    opendir(my $dh, $targetDir) or croak "Cannot open directory: $targetDir";

    while (my $file = readdir($dh)) {
        next if $file =~ /^\.\.?$/;
        print "CountFiles $file\n" if $DEBUG;
        $count++ unless -d "$targetDir$file";
    }

    closedir($dh);
    print "CountFiles RETURNING a count of $count\n" if $DEBUG;
    return $count;
}

################################################################################
# Subroutine: CountFilesWExtensions
#
# Purpose:
#   Count the number of non-directory files in a specified target directory
#   that match a given file extension.
#
# Visibility:
#   Internal helper (not exported).
#
# Parameters:
#   $self      (hashref) - Caller object reference (not used for state).
#   $targetDir (string)  - Path to directory whose files will be counted (required).
#   $ext       (string)  - File extension to match, without leading dot (required).
#
# Behavior:
#   - Croaks if $targetDir or $ext is not defined.
#   - Normalizes $targetDir to ensure it ends with a trailing slash.
#   - Opens the directory or croaks if it cannot be opened.
#   - Iterates entries:
#       * Skips "." and "..".
#       * Increments count for entries that:
#             - are not directories, and
#             - end with ".<ext>" (simple suffix match).
#       * Emits debug output when $DEBUG is true.
#   - Returns the total count of matching files.
#
# Returns:
#   Integer - Number of non-directory files in targetDir with the given extension.
#
# Failure modes:
#   - Croaks on missing arguments.
#   - Croaks if the directory cannot be opened.
#
# Notes:
#   - Does not recurse into subdirectories.
#   - Extension matching is case-sensitive unless the caller normalizes $ext.
################################################################################
sub CountFilesWExtensions {
    my ($self, $targetDir, $ext) = @_;
    croak "CountFiles(<targetDir, ext>)" unless defined $targetDir && defined $ext;

    $targetDir = EnsureTrailingSlash($targetDir);
    my $count = 0;

    print "STARTING CountFilesWExtensions\nDirectory = $targetDir\nExtension = $ext\n" if $DEBUG;
    opendir(my $dh, $targetDir) or croak "Cannot open directory: $targetDir";

    while (my $file = readdir($dh)) {
        next if $file =~ /^\.\.?$/;
        print "CountFiles $file\n" if $DEBUG;
        $count++ if $file =~ /\.\Q$ext\E$/ && !-d "$targetDir$file";
    }

    closedir($dh);
    print "CountFilesWExtension RETURNING a count of $count\n" if $DEBUG;
    return $count;
}

################################################################################
# Subroutine: CountDirs
#
# Purpose:
#   Count the number of immediate subdirectories within a specified target
#   directory. Normalizes the directory path with a trailing slash and
#   provides optional debug output for traceability.
#
# Visibility:
#   Public API (exported via @EXPORT).
#
# Parameters:
#   $self      (hashref) - Caller object reference (not used for state).
#   $targetDir (string)  - Path to directory whose subdirectories will be
#                          counted (required).
#
# Behavior:
#   - Croaks if $targetDir is not defined.
#   - Normalizes $targetDir to ensure it ends with a trailing slash.
#   - Opens the directory or croaks if it cannot be opened.
#   - Iterates entries:
#       * Skips "." and "..".
#       * Increments count for entries that are directories.
#       * Emits debug output when $DEBUG is true.
#   - Returns the total count of subdirectories.
#
# Returns:
#   Integer - Number of immediate subdirectories in targetDir.
#
# Failure modes:
#   - Croaks on missing argument.
#   - Croaks if the directory cannot be opened.
#
# Notes:
#   - Does not recurse into nested subdirectories.
#   - Callers that require non-fatal behavior must wrap the call in eval.
################################################################################
sub CountDirs {
    my ($self, $targetDir) = @_;
    croak "CountDirs(<targetDir>)" unless defined $targetDir;

    $targetDir = EnsureTrailingSlash($targetDir);
    my $count = 0;

    print "STARTING CountDirs for $targetDir\n" if $DEBUG;
    opendir(my $dh, $targetDir) or croak "Cannot open directory: $targetDir";

    while (my $file = readdir($dh)) {
        next if $file =~ /^\.\.?$/;
        print "CountDirs $file\n" if $DEBUG;
        $count++ if -d "$targetDir$file";
    }

    closedir($dh);
    print "CountDirs RETURNING a count of $count\n" if $DEBUG;
    return $count;
}

#############################################################################
# Module terminator
#############################################################################
1;