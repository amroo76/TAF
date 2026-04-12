package Trim;
#############################################################################
# Trim
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
#     Provide deterministic, contributor-proof string normalization utilities.
#     This module offers two simple primitives for removing whitespace:
#         * trim()     - remove leading, trailing, and internal spaces
#         * trimLite() - remove leading and trailing spaces only
#     These routines support consistent string handling across toolsLib and
#     higher-level TAF components.
#
# ARCHITECTURAL ROLE:
#     - Acts as the unified whitespace-normalization utility for toolsLib.
#     - Ensures predictable behavior for string cleanup in parsing, system
#       information gathering, and configuration processing.
#     - Provides minimal, dependency-free helpers suitable for use in any
#       context where whitespace normalization is required.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not perform Unicode normalization or locale-aware trimming.
#     - Does not collapse tabs, newlines, or other non-space whitespace unless
#       explicitly matched by regex substitutions.
#     - Does not guess caller intent or silently modify undefined values.
#     - Does not die(); all routines return simple string values.
#
# CONTRACT:
#     - trim(<string>) must:
#           * return '' for undefined input
#           * remove leading whitespace
#           * remove trailing whitespace
#           * remove all internal space characters
#     - trimLite(<string>) must:
#           * return '' for undefined input
#           * remove leading whitespace
#           * remove trailing whitespace
#           * preserve internal spaces
#     - Both routines must remain deterministic and side-effect-free.
#
# GUARANTEES:
#     - No silent fallbacks or ambiguous behavior.
#     - Normalization behavior is stable and contributor-proof.
#     - Returned values are predictable across platforms and environments.
#
# NOTES:
#     - This module is intentionally minimal; it provides only the whitespace
#       primitives required by toolsLib and higher-level TAF components.
#     - Any change to trimming semantics must be reflected in this header and
#       in the TAF manual.
#############################################################################

use strict;
use warnings;
use Exporter 'import';

our $VERSION = '2.0';
our @EXPORT  = qw(trim trimLite);

################################################################################
# Subroutine : trim
#
# Purpose:
#   Utility function to sanitize a string by removing all leading, trailing,
#   and internal whitespace characters. Ensures normalized values for use in
#   system information or parsing routines.
#
# Globals Used:
#   None explicitly.
#
# Parameters:
#   $string (string) - Input string to be trimmed. May be undefined.
#
# Behavior:
#   - Returns empty string if input is undefined.
#   - Removes leading whitespace using regex substitution.
#   - Removes trailing whitespace using regex substitution.
#   - Removes all remaining space characters within the string.
#   - Returns the fully cleaned string.
#
# Returns:
#   String - Input value with all whitespace removed.
#
# Notes:
#   - INTERNAL helper; not intended for external callers.
#   - Differs from _trim() by also removing *internal* spaces, not just
#     leading/trailing whitespace.
#   - Useful when strict normalization of identifiers or tokens is required.
################################################################################
sub trim {
    my ($string) = @_;
    return '' unless defined $string;

    $string =~ s/^\s+//;
    $string =~ s/\s+$//;
    $string =~ s/ //g;
    return $string;
}

################################################################################
# Subroutine : trimLite
#
# Purpose:
#   Utility function to normalize a string by removing leading and trailing
#   whitespace only. Provides a lighter alternative to trim() that preserves
#   internal spaces.
#
# Globals Used:
#   None explicitly.
#
# Parameters:
#   $string (string) - Input string to be trimmed. May be undefined.
#
# Behavior:
#   - Returns empty string if input is undefined.
#   - Removes leading whitespace using regex substitution.
#   - Removes trailing whitespace using regex substitution.
#   - Leaves internal spaces intact.
#   - Returns the cleaned string.
#
# Returns:
#   String - Input value with leading/trailing whitespace removed, internal
#            spaces preserved.
#
# Notes:
#   - INTERNAL helper; not intended for external callers.
#   - Differs from trim() by preserving internal spaces.
#   - Useful when whitespace between words or tokens must be retained.
################################################################################
sub trimLite {
    my ($string) = @_;
    return '' unless defined $string;

    $string =~ s/^\s+//;
    $string =~ s/\s+$//;
    return $string;
}

#############################################################################
# Module terminator
#############################################################################
1;