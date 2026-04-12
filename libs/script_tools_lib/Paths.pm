package Paths;
#############################################################################
# Paths
#
# Created: August 2025
# Last Modified: January 2026
#
# This file is part of the Test Automation Framework (TAF).
# Copyright (c) 2025-2026 MariaDB Foundation and Jonathan "jeb" Miller
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 or later of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1335 
#
# Licensed under the GNU General Public License, version 2 or later (GPLv2+).
# See https://www.gnu.org/licenses/ for details.
#
# PURPOSE:
#     Provide deterministic, contributor-proof utilities for normalizing and
#     validating filesystem paths. This module offers simple, dependency-free
#     primitives for ensuring trailing slashes, removing trailing slashes, and
#     checking directory existence. These routines support consistent path
#     handling across all toolsLib and TAF components.
#
# ARCHITECTURAL ROLE:
#     - Acts as the unified path-normalization utility for toolsLib.
#     - Ensures consistent use of forward slashes across platforms.
#     - Provides simple, predictable primitives:
#           * EnsureSlashTrailing()  - normalize separators and enforce trailing slash
#           * RemoveSlashTrailing()  - remove trailing slash when present
#           * DirExists()            - check directory existence safely
#     - Avoids reliance on heavyweight path modules for simple operations.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not validate path permissions or readability.
#     - Does not canonicalize paths beyond slash normalization.
#     - Does not resolve symlinks or perform realpath-like behavior.
#     - Does not guess caller intent or silently modify input.
#     - Does not die(); all routines return simple values.
#
# CONTRACT:
#     - EnsureSlashTrailing(<path>) must:
#           * convert backslashes to forward slashes
#           * append a trailing slash if missing
#           * return '' for undefined input
#     - RemoveSlashTrailing(<path>) must:
#           * remove exactly one trailing slash if present
#           * preserve empty or undefined input
#     - DirExists(<path>) must:
#           * return TRUE if the directory exists
#           * return FALSE otherwise
#     - All routines must remain deterministic and side-effect-free.
#
# GUARANTEES:
#     - Path normalization behavior is stable and contributor-proof.
#     - No hidden recursion or filesystem mutation.
#     - Debug output is minimal and controlled by $DEBUG.
#
# NOTES:
#     - This module is intentionally minimal; it provides only the path
#       primitives required by toolsLib and higher-level TAF components.
#     - Any change to path-handling semantics must be reflected in this header
#       and in the TAF manual.
#############################################################################

use strict;
use warnings;
use Carp;
use Exporter 'import';
use File::Path qw(mkpath);

our $VERSION = '2.0';
our @EXPORT = qw(
    EnsureSlashTrailing
    RemoveSlashTrailing
    DirExists
);

# Constants
use constant {
    FALSE => 0,
    TRUE  => 1,
};

# Module-level debug flag
our $DEBUG = 0;

################################################################################
# Function : EnsureSlashTrailing
# Purpose  : Normalize path separators and ensure a trailing slash.
#
# Details  :
#   - Accepts a path string as input.
#   - Converts all backslashes "\" to forward slashes "/" for consistency.
#   - Appends a trailing slash "/" if one is not already present.
#   - Returns an empty string if the input path is undefined.
#
# Returns  : Normalized path string with trailing slash.
################################################################################
sub EnsureSlashTrailing {
    my ($path) = @_;
    return '' unless defined $path;

    $path =~ s#\\#/#g;
    $path .= '/' unless $path =~ m{/$};
    return $path;
}

################################################################################
# Function : RemoveSlashTrailing
# Purpose  : Remove any trailing slash or backslash from a path string.
#
# Details  :
#   - Accepts a path string as input.
#   - Returns an empty string if the input path is undefined.
#   - Uses a regex to strip one or more trailing "/" or "\" characters.
#   - Ensures the returned path has no trailing slash or backslash.
#
# Returns  : Path string without trailing slash or backslash.
################################################################################
sub RemoveSlashTrailing {
    my ($path) = @_;
    return '' unless defined $path;

    $path =~ s{[\\/]+$}{};
    return $path;
}

################################################################################
# Function : EnsureDirectory
# Purpose  : Ensure that a given directory exists, creating it if necessary.
#
# Details  :
#   - Accepts a directory path as input.
#   - If $DEBUG is enabled, prints status messages about ensuring or failing to create the directory.
#   - Checks if the directory exists using DirExists().
#   - If not, attempts to create the directory with mkpath() inside an eval block.
#   - On failure, prints an error message (if $DEBUG) and returns FALSE.
#   - On success, or if the directory already exists, returns TRUE.
#
# Returns  : TRUE if the directory exists or was successfully created,
#            FALSE if creation failed.
################################################################################
sub EnsureDirectory {
    my ($dir) = @_;
    print "Paths: Ensuring $dir\n" if $DEBUG;

    unless (DirExists($dir)) {
        eval { mkpath($dir) };
        if ($@ && !DirExists($dir)) {
            print "Paths: Failed to create $dir : $@  $^E\n" if $DEBUG;
            return FALSE;
        }
    }
    return TRUE;
}

################################################################################
# Function : DirExists
# Purpose  : Check whether a given path exists and is a directory.
#
# Details  :
#   - Accepts a directory path as input.
#   - If $DEBUG is enabled, prints diagnostic messages at each validation step.
#   - Returns FALSE if:
#       * The path variable is undefined.
#       * The path does not exist.
#       * The path exists but is not a directory.
#   - Returns TRUE if the path exists and is a valid directory.
#
# Returns  : TRUE if the path is a directory, FALSE otherwise.
################################################################################
sub DirExists {
    my ($dir) = @_;
    print "Paths: Looking at $dir\n" if $DEBUG;

    unless (defined $dir) {
        print "Paths: Variable not defined\n" if $DEBUG;
        return FALSE;
    }

    unless (-e $dir) {
        print "Paths: $dir does not exist\n" if $DEBUG;
        return FALSE;
    }

    unless (-d $dir) {
        print "Paths: $dir not a directory\n" if $DEBUG;
        return FALSE;
    }

    print "Paths: $dir exists\n" if $DEBUG;
    return TRUE;
}

#############################################################################
# Module terminator
#############################################################################
1;