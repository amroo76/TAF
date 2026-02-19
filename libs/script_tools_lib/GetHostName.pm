package GetHostName;
#############################################################################
# GetHostName
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
#     Provide a deterministic, cross-platform mechanism for retrieving a system's
#     hostname without relying on Sys::Hostname. This module normalizes hostname
#     behavior across Windows, Linux, Solaris, and Cygwin environments, ensuring
#     consistent results for all TAF components that require host identification.
#
# ARCHITECTURAL ROLE:
#     - Acts as the unified hostname-retrieval utility for testtoolsLib.
#     - Provides short-form hostname resolution with platform-specific cleanup.
#     - Supplies GetByIP() for reverse-lookup scenarios where hostname must be
#       derived from an IP address.
#     - Ensures all hostname retrieval is explicit, predictable, and free of
#       platform quirks that would otherwise leak into higher-level modules.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not return fully-qualified domain names.
#     - Does not perform DNS resolution beyond simple reverse lookup.
#     - Does not validate network configuration or interface state.
#     - Does not guess or infer hostnames from environment variables.
#     - Does not die(); all failures return fallback values.
#
# CONTRACT:
#     - GetName() returns:
#           * the short hostname on success
#           * "Unknown_Host" on failure
#     - Solaris/Linux output containing "has address" must be sanitized.
#     - All returned hostnames must be trimmed of whitespace and newlines.
#     - GetByIP(<ip>) must return a hostname or "Unknown_Host".
#     - No routine may throw exceptions; all errors must be handled internally.
#
# GUARANTEES:
#     - Cross-platform behavior is deterministic and contributor-proof.
#     - No external modules (Sys::Hostname) are required.
#     - Hostname output is always normalized and sanitized.
#     - Fallback behavior is stable and predictable across all environments.
#
# NOTES:
#     - This module is intentionally minimal; it provides only the hostname
#       primitives required by TAF's testtoolsLib.
#     - Any change to hostname-retrieval semantics must be reflected in this
#       header and in the TAF manual.
#############################################################################
use strict;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK $VERSION);
use Exporter;

@ISA = qw(Exporter toolsLib);
@EXPORT = qw(&GetName &GetByIP);
$VERSION = '2.0';

use constant IS_WINDOWS => ($^O =~ /^(mswin)/oi);
use constant IS_CYGWIN  => ($^O =~ /^(cygwin)/oi);
use constant IS_LINUX   => ($^O =~ /^(linux)/oi);
use constant IS_SOLARIS => ($^O =~ /^(solaris)/oi);

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
# Subroutine: GetName
#
# Purpose:
#   Retrieve the short hostname of the current system. Provides fallback to
#   "Unknown_Host" if hostname cannot be determined, and includes Solaris/Linux
#   specific handling for cases where the hostname command returns additional
#   text (e.g., "has address").
#
# Globals Used:
#   Constants: IS_SOLARIS, IS_LINUX
#   Utility subs: Trim
#
# Parameters:
#   None (invoked without arguments)
#
# Behavior:
#   - Executes `hostname -s` to capture the system's short hostname.
#   - If hostname is undefined:
#       * Returns "Unknown_Host".
#   - On Solaris or Linux:
#       * If hostname output contains "has address":
#           - Splits string at "has address" and keeps only the first part.
#   - Trims whitespace/newlines from hostname via Trim().
#   - Returns normalized hostname string.
#
# Returns:
#   String - Short hostname of the system
#   "Unknown_Host" - If hostname cannot be determined
#
# Notes:
#   - This routine is INTERNAL; not intended for external callers.
#   - Uses `hostname -s` which typically returns the short form (without domain).
#   - Solaris/Linux handling ensures compatibility with variations in hostname
#     command output.
#   - Trim() is used to sanitize the final result before returning.
################################################################################
sub GetName {
    my $hostName = `hostname -s`;
    return "Unknown_Host" unless defined $hostName;

    if (IS_SOLARIS || IS_LINUX) {
        if ($hostName =~ /has address/) {
            ($hostName) = split(/has address/, $hostName);
        }
    }

    return Trim($hostName);
}

################################################################################
# Subroutine: GetByIP
#
# Purpose:
#   Resolve a hostname from a given IPv4 address. Provides a short form of the
#   hostname (up to the first dot) if resolution succeeds. Returns undef if the
#   IP is invalid or cannot be resolved.
#
# Globals Used:
#   None
#
# Parameters:
#   $ip (string) - IPv4 address to resolve (required)
#
# Behavior:
#   - Validates that $ip is defined; returns undef if missing.
#   - Uses Socket::inet_aton() to pack the IP address into binary form.
#       * Returns undef if packing fails (invalid IP).
#   - Calls gethostbyaddr() with AF_INET to resolve hostname.
#       * Returns undef if resolution fails.
#   - If resolved hostname contains dots:
#       * Splits on "." and keeps only the first segment (short hostname).
#   - Returns the resolved short hostname string.
#
# Returns:
#   String - Short hostname resolved from IP
#   undef  - If IP is invalid or resolution fails
#
# Notes:
#   - This routine is INTERNAL; not intended for external callers.
#   - Requires Socket module; ideally imported at the top of the file.
#   - Only supports IPv4 addresses (AF_INET).
#   - Returns short hostname (first segment) rather than fully qualified domain name.
################################################################################
sub GetByIP {
    my ($ip) = @_;
    return unless defined $ip;

    use Socket;  # Move this to the top of the file ideally
    my $packed_ip = inet_aton($ip);
    return unless $packed_ip;

    my $name = gethostbyaddr($packed_ip, AF_INET);
    return unless defined $name;

    $name = (split(/\./, $name))[0] if $name =~ /\./;
    return $name;
}

################################################################################
# Subroutine: Trim
#
# Purpose:
#   Remove leading and trailing whitespace from a string. Ensures clean,
#   normalized values for routines that depend on sanitized input.
#
# Globals Used:
#   None
#
# Parameters:
#   $string (string) - Input string to be trimmed (required)
#
# Behavior:
#   - Captures input string.
#   - Applies regex substitution to:
#       * Remove all leading whitespace (^\s+).
#       * Remove all trailing whitespace (\s+$).
#   - Returns the sanitized string.
#
# Returns:
#   String - Input string with leading and trailing whitespace removed
#
# Notes:
#   - This routine is INTERNAL; not intended for external callers.
#   - Does not alter internal whitespace; only trims at boundaries.
#   - Useful for normalizing user input, filenames, or system command output.
#   - Lightweight and deterministic; safe for repeated use in pipelines.
################################################################################
sub Trim($){
    my $string = shift;
    $string =~ s/^\s+//;
    $string =~ s/\s+$//;
    return($string);
}

#############################################################################
# Module terminator
#############################################################################
1;