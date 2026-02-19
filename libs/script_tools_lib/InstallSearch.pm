package InstallSearch;
#############################################################################
# InstallSearch
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
#     Provide deterministic, cross-platform search utilities for locating files,
#     directories, and executables within installation trees. This module forms
#     part of the foundational toolsLib layer and is used by installers,
#     validators, and test harness components that require predictable,
#     contributor-proof filesystem discovery.
#
# ARCHITECTURAL ROLE:
#     - Acts as the unified search engine for installation-related lookups.
#     - Provides simple, dependency-free primitives:
#           * FindBin()  - locate executables across candidate paths
#           * FindReg()  - locate files matching patterns or registry-style names
#           * GetBaseDirList() - list immediate subdirectories
#     - Normalizes platform differences (Windows, Cygwin, Unix-like systems).
#     - Ensures consistent behavior across all TAF components that rely on
#       filesystem discovery.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not recurse deeply unless explicitly requested.
#     - Does not perform content inspection or metadata analysis.
#     - Does not guess caller intent or silently skip errors.
#     - Does not modify the filesystem.
#     - Does not perform path normalization beyond what is required for search.
#
# CONTRACT:
#     - FindBin(<name>) must:
#           * search candidate paths deterministically
#           * apply platform-specific executable extensions (.exe on Windows/Cygwin)
#           * return a full path or undef
#     - FindReg(<pattern>) must:
#           * use explicit globbing rules
#           * return matching paths or an empty list
#     - GetBaseDirList(<dir>) must:
#           * return only immediate subdirectories
#           * skip hidden entries
#           * croak on unreadable directories
#     - All routines must return predictable values and must not die() except
#       where explicitly documented (e.g., croak on invalid directory access).
#
# GUARANTEES:
#     - No silent fallbacks or ambiguous behavior.
#     - Cross-platform search semantics are deterministic and contributor-proof.
#     - Debug output is consistent and traceable when enabled.
#     - All search operations are minimal, safe, and free of side effects.
#
# NOTES:
#     - This module is intentionally narrow in scope; it provides the building
#       blocks for higher-level install and validation workflows.
#     - Any change to search semantics or platform-specific behavior must be
#       reflected in this header and in the TAF manual.
#############################################################################

use strict;
use warnings;
use Exporter 'import';
use Carp;
use File::Basename;
use File::Glob ':bsd_glob';

our @EXPORT = qw(FindBin FindReg GetBaseDirList);
our $VERSION = '2.0';

use constant IS_WINDOWS => ($^O =~ /^(mswin)/oi);
use constant IS_CYGWIN  => ($^O =~ /^(cygwin)/oi);

our $DEBUG  = 0;
our $DEBUG2 = 0;

################################################################################
# Create an Object
################################################################################
sub new {
    my $class = shift;
    my $self = {};
    bless $self, $class;
    return $self;
}

################################################################################
# Subroutine: GetBaseDirList
#
# Purpose:
#   Retrieve a list of immediate subdirectories within a specified base directory.
#   Skips hidden entries (those beginning with ".") and provides optional debug
#   output for traceability.
#
# Globals Used:
#   $DEBUG              - Boolean flag controlling verbosity of printed messages
#   Constants: croak (exception handling)
#
# Parameters:
#   $self    (hashref) - Caller object reference
#   $baseDir (string)  - Directory to scan for subdirectories (required)
#
# Behavior:
#   - Attempts to open baseDir; croaks if unable to access.
#   - Reads directory entries.
#   - Filters entries:
#       * Excludes hidden entries (names beginning with ".").
#       * Includes only entries that are directories.
#   - Closes directory handle.
#   - If DEBUG is enabled:
#       * Prints baseDir label.
#       * Prints each subdirectory name found.
#   - Returns reference to array of subdirectory names.
#
# Returns:
#   ArrayRef - Reference to list of subdirectory names in baseDir
#
# Notes:
#   - This routine is INTERNAL; not intended for external callers.
#   - Only lists immediate subdirectories; does not recurse into nested levels.
#   - Debug mode provides traceability of baseDir and discovered subdirectories.
#   - Skips hidden entries to avoid system/metadata directories.
################################################################################
sub GetBaseDirList {
    my ($self, $baseDir) = @_;
    opendir(my $dh, $baseDir) || croak "Unable to open $baseDir: $!";
    my @dirs = grep { !/^\./ && -d "$baseDir/$_" } readdir($dh);
    closedir($dh);
    if ($DEBUG) {
        print "$baseDir list of dirs\n";
        print "Dir = $_\n" for @dirs;
    }
    return \@dirs;
}

################################################################################
# Subroutine: FindBin
#
# Purpose:
#   Locate an executable binary file by searching through candidate paths and
#   names. Supports platform-specific extensions (e.g., ".exe" on Windows/Cygwin)
#   and provides optional debug output for traceability.
#
# Globals Used:
#   $DEBUG   - Boolean flag controlling verbosity of printed messages
#   $DEBUG2  - Secondary debug flag for deeper trace output
#   Constants: IS_WINDOWS, IS_CYGWIN
#   Utility subs: croak, find_paths
#
# Parameters:
#   $self    (hashref) - Caller object reference
#   $base    (string)  - Base directory to anchor search (required)
#   $paths   (arrayref)- Candidate path list to search (required)
#   $names   (string)  - Binary name(s) to locate (required)
#   $binExt  (string)  - Optional extension override (without leading dot)
#
# Behavior:
#   - Validates argument count; croaks with usage message if fewer than 3 provided.
#   - Determines extension:
#       * Uses provided binExt if defined.
#       * Defaults to ".exe" on Windows/Cygwin.
#       * Defaults to empty string otherwise.
#   - Prints extension if DEBUG enabled.
#   - Calls find_paths() with base, paths, names, and extension to generate
#     candidate paths.
#   - Iterates through candidate paths:
#       * Prints "Checking: path" if DEBUG2 enabled.
#       * If path is executable and not a directory, returns path.
#       * On Windows/Cygwin, also accepts plain files (-f).
#   - If no valid binary found:
#       * Prints failure message if DEBUG enabled.
#       * Returns undef.
#
# Returns:
#   String - Full path to located binary
#   undef  - If no matching binary found
#
# Notes:
#   - This routine is INTERNAL; not intended for external callers.
#   - Provides cross-platform handling of binary extensions.
#   - Debug mode provides traceability of extension selection and candidate checks.
#   - Relies on find_paths() to generate candidate search paths.
################################################################################
sub FindBin {
    my ($self, $base, $paths, $names, $binExt) = @_;
    croak "usage: FindBin(<base>, <paths>, <names>, [<ext>])" unless @_ >= 3;

    my $ext = defined $binExt ? ".$binExt" : (IS_WINDOWS || IS_CYGWIN ? ".exe" : "");
    print "Extension = $ext\n" if $DEBUG;

    foreach my $path (find_paths($base, $paths, $names, $ext)) {
        print "Checking: $path\n" if $DEBUG2;
        if ((-x $path && !-d $path) || ((IS_WINDOWS || IS_CYGWIN) && -f $path)) {
            return $path;
        }
    }

    print "FindBin() unable to locate binary: $names\n" if $DEBUG;
    return undef;
}

################################################################################
# Subroutine: FindReg
#
# Purpose:
#   Locate a regular file by searching through candidate paths and names.
#   Supports optional extension handling and provides optional debug output
#   for traceability. Returns the first matching file found.
#
# Globals Used:
#   $DEBUG   - Boolean flag controlling verbosity of printed messages
#   $DEBUG2  - Secondary debug flag for deeper trace output
#   Constants: IS_WINDOWS, IS_CYGWIN
#   Utility subs: croak, find_paths
#
# Parameters:
#   $self    (hashref) - Caller object reference
#   $base    (string)  - Base directory to anchor search (required)
#   $paths   (arrayref)- Candidate path list to search (required)
#   $names   (string)  - File name(s) to locate (required)
#   $binExt  (string)  - Optional extension override (without leading dot)
#
# Behavior:
#   - Validates argument count; croaks with usage message if fewer than 3 provided.
#   - Determines extension:
#       * Uses provided binExt if defined.
#       * Defaults to empty string otherwise.
#   - Calls find_paths() with base, paths, names, and extension to generate
#     candidate paths.
#   - Iterates through candidate paths:
#       * Prints "Checking: path" if DEBUG2 enabled.
#       * If path exists (-e), returns path.
#       * On Windows/Cygwin, also accepts plain files (-f).
#   - If no valid file found:
#       * Prints failure message if DEBUG enabled.
#       * Returns undef.
#
# Returns:
#   String - Full path to located file
#   undef  - If no matching file found
#
# Notes:
#   - This routine is INTERNAL; not intended for external callers.
#   - Provides cross-platform handling of file existence checks.
#   - Debug mode provides traceability of candidate checks and failure messages.
#   - Relies on find_paths() to generate candidate search paths.
################################################################################
sub FindReg {
    my ($self, $base, $paths, $names, $binExt) = @_;
    croak "usage: FindReg(<base>, <paths>, <names>, [<ext>])" unless @_ >= 3;

    my $ext = defined $binExt ? ".$binExt" : "";

    foreach my $path (find_paths($base, $paths, $names, $ext)) {
        print "Checking: $path\n" if $DEBUG2;
        if (-e $path || ((IS_WINDOWS || IS_CYGWIN) && -f $path)) {
            return $path;
        }
    }

    print "FindReg() unable to locate file: $names\n" if $DEBUG;
    return undef;
}

################################################################################
# Function : find_paths
# Purpose  : Generate candidate file paths by combining a base directory,
#            search paths, file names, and optional extension.
#
# Details  :
#   - Accepts scalar or array refs for $paths and $names.
#   - Safely applies extension if provided.
#   - Expands platform specific directories (Windows/Cygwin adds build dirs).
#   - Uses globbing to resolve wildcards in typical MySQL/MariaDB layouts.
#   - Produces fully qualified paths for each name under each candidate path.
#
# Returns  : List of expanded file paths suitable for existence checks or iteration.
################################################################################
sub find_paths {
    my ($base, $paths, $names, $extension) = @_;

    my @names = ref $names eq 'ARRAY' ? @$names : ($names);
    my @paths = ref $paths eq 'ARRAY' ? @$paths : ($paths);

    # Apply extension safely
    @names = map { /\.(\w+)$/ ? $_ : "$_$extension" } @names if defined $extension;

    my @extra_dirs = (
        "lib64/mysql", "bin", "sbin", "include", "english", "mysql/*",
        "share/*", "share/mysql*/english", "doc/*", "usr/*",
        "mysql*/english", "share/doc/mysql*"
    );

    push @extra_dirs, ("release", "relwithdebinfo", "debug")
        if IS_WINDOWS || IS_CYGWIN;

    push @paths, map { my $p = $_; map { "$p/$_" } @extra_dirs } @paths;

    @paths = map { "$base/$_" } @paths;
    @paths = map { bsd_glob($_) } @paths;
    @paths = map { my $p = $_; map { "$p/$_" } @names } @paths;

    return @paths;
}

#############################################################################
# Module terminator
#############################################################################
1;