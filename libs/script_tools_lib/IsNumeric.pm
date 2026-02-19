package IsNumeric;
#############################################################################
# IsNumeric
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
#     Provide deterministic, contributor-proof routines for validating whether
#     a given value is numeric or resembles an IPv4 address. This module offers
#     minimal, dependency-free primitives used throughout testtoolsLib for
#     argument validation, configuration parsing, and input sanitization.
#
# ARCHITECTURAL ROLE:
#     - Acts as the unified numeric/IP validation utility for toolsLib.
#     - Supplies two simple, stable predicates:
#           * IsThisANumber() - numeric validation with optional sign/decimal
#           * IsThisAnIP()    - basic dotted-quad IPv4 pattern check
#     - Ensures consistent validation semantics across all TAF components.
#     - Avoids reliance on heavyweight parsing modules for simple checks.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not validate IPv4 octet ranges (0-255).
#     - Does not validate IPv6 addresses.
#     - Does not perform locale-aware numeric parsing.
#     - Does not guess caller intent or silently coerce values.
#     - Does not die(); all routines return TRUE/FALSE only.
#
# CONTRACT:
#     - IsThisANumber(<value>) must:
#           * accept optional leading sign
#           * accept optional decimal point
#           * return TRUE for valid numeric strings, FALSE otherwise
#     - IsThisAnIP(<value>) must:
#           * match dotted-quad patterns of 1-3 digits per octet
#           * return TRUE for IPv4-like strings, FALSE otherwise
#     - Both routines must:
#           * return FALSE for undefined input
#           * avoid throwing exceptions
#           * remain deterministic and side-effect-free
#
# GUARANTEES:
#     - Validation behavior is stable, predictable, and contributor-proof.
#     - No hidden coercion, no implicit parsing, no exceptions.
#     - Debug output is minimal and controlled by $DEBUG.
#
# NOTES:
#     - This module is intentionally minimal; it provides only the validation
#       primitives required by toolsLib and higher-level TAF components.
#     - Any change to numeric or IP validation semantics must be reflected in
#       this header and in the TAF manual.
#############################################################################

use strict;
use warnings;
use Exporter 'import';
use Carp;

# Constants
use constant {
    TRUE  => 1,
    FALSE => 0,
};

# Exported symbols
our @EXPORT = qw(IsThisANumber IsThisAnIP);
our $VERSION = '2.0';
our $DEBUG   = 0;

################################################################################
# Function : IsThisANumber
# Purpose  : Validate whether a given value is numeric.
#
# Details  :
#   - Accepts optional sign (+/-).
#   - Matches digits with optional decimal point.
#   - Returns TRUE if the value is numeric, FALSE otherwise.
#   - Prints "Opps" on failure for debugging visibility.
#
# Returns  : TRUE if numeric, FALSE otherwise.
################################################################################
sub IsThisANumber {
    my ($self, $value) = @_;
    return FALSE unless defined $value;

    # Match optional sign, digits, optional decimal, digits
    if ($value =~ /^[+-]?\d*\.?\d+$/) {
        return TRUE;
    }

    return FALSE;
}

################################################################################
# Function : IsThisAnIP
# Purpose  : Validate whether a given value matches a basic IPv4 pattern.
#
# Details  :
#   - Accepts dotted-quad format (four groups of 1 - 3 digits).
#   - Does not enforce numeric range (0 - 255) for each octet.
#   - Returns TRUE if the value matches the pattern, FALSE otherwise.
#
# Returns  : TRUE if IPv4-like, FALSE otherwise.
################################################################################
sub IsThisAnIP {
    my ($self, $value) = @_;
    return FALSE unless defined $value;

    # Basic IPv4 pattern
    if ($value =~ /^(\d{1,3}\.){3}\d{1,3}$/) {
        return TRUE;
    }
    return FALSE;
}

#############################################################################
# Module terminator
#############################################################################
1;