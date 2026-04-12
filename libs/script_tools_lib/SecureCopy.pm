package SecureCopy;
#############################################################################
# SecureCopy
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
#     Provide deterministic, cross-platform routines for securely copying files
#     between hosts. This module wraps platform-specific scp implementations
#     and provides a unified interface for file transfer operations used
#     throughout toolsLib and higher-level TAF components.
#
# ARCHITECTURAL ROLE:
#     - Acts as the unified scp wrapper for toolsLib.
#     - Provides simple, predictable primitives:
#           * SCPTO()           - copy a file from local to remote
#           * SCPFROM()         - copy a file from remote to local
#           * ScpToRecursive()  - recursively copy directories to remote hosts
#     - Normalizes platform differences across Windows, Linux, and Solaris.
#     - Ensures consistent command construction, quoting, and error handling.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not implement SSH authentication or key management.
#     - Does not validate network connectivity or remote host availability.
#     - Does not perform retries, throttling, or transfer resumption.
#     - Does not guess caller intent or silently ignore failures.
#     - Does not die(); all routines return OK or ERROR.
#
# CONTRACT:
#     - All routines must:
#           * construct scp commands deterministically
#           * use platform-appropriate scp binaries and flags
#           * return OK on success and ERROR on failure
#           * emit debug output only when $DEBUG is enabled
#     - BEGIN block must:
#           * locate the correct scp binary for the platform
#           * construct recursive and non-recursive command templates
#           * define a platform-appropriate null sink for output suppression
#
# GUARANTEES:
#     - No silent fallbacks or ambiguous behavior.
#     - No mutation of caller paths or environment variables.
#     - Cross-platform behavior is deterministic and contributor-proof.
#     - Debug output is minimal and traceable when enabled.
#
# NOTES:
#     - This module is intentionally narrow in scope; it provides only the
#       secure-copy primitives required by toolsLib and higher-level TAF
#       components.
#     - Any change to scp invocation semantics must be reflected in this header
#       and in the TAF manual.
#############################################################################
use strict;
use warnings;
use Carp;
use Exporter 'import';
use Cwd;
use FindBin qw($Bin);

our @ISA       = qw(Exporter testToolsLib);
our @EXPORT    = qw(new SCPTO SCPFROM ScpToRecursive);
our $VERSION   = '2.0';
our $DEBUG     = 0;
our $name      = __PACKAGE__;

use constant IS_WINDOWS => ($^O =~ /^(mswin)/oi);
use constant IS_LINUX   => ($^O =~ /^(linux)/oi);
use constant IS_SOLARIS => ($^O =~ /^(solaris)/oi);
use constant OK    => 0;
use constant ERROR => 1;

my ($scp, $scpr, $devNull);

################################################################################
# Locate SCP binary based on platform
################################################################################
BEGIN {
    if (IS_WINDOWS) {
    	$scp = "$Bin/helpers/scp.exe";
        $scpr    = "$scp -noagent -q -r -pw";
        $scp     = "$scp -noagent -q -pw";
        $devNull = "> NUL 2>NUL";
    }
    elsif (IS_LINUX || IS_SOLARIS) {
        $scp     = "scp";
        $scpr    = "scp -r";
        $devNull = "> /dev/null 2>&1";
    }
    else {
        croak "Unsupported OS platform";
    }
}

################################################################################
# Constructor
################################################################################
sub new {
    my ($class) = @_;
    return bless {}, $class;
}

################################################################################
# Debug print helper
################################################################################
sub DebugPrint {
    my ($msg) = @_;
    print "$name: $msg\n" if $DEBUG;
}

################################################################################
# Ensure trailing slash on path
################################################################################
sub EnsureSlash {
    my ($path) = @_;
    return $path =~ /\/$/ ? $path : "$path/";
}

################################################################################
# Subroutine : SCPTO
#
# Purpose:
#   Securely copy a local file to a remote host using the SCP utility.
#   Provides cross-platform handling for Linux/Solaris vs. Windows/Cygwin,
#   with optional debug output for traceability.
#
# Globals Used:
#   $DEBUG     - Boolean flag controlling verbosity of printed messages
#   Constants  : IS_LINUX, IS_SOLARIS, IS_WINDOWS, IS_CYGWIN, ERROR
#   Utility subs: DebugPrint, EnsureSlash
#   Variables  : $scp (SCP command path), $devNull (output redirection)
#
# Parameters:
#   $self       (hashref) - Caller object reference
#   $targetFile (string)  - Local file to copy (required)
#   $user       (string)  - Remote user name (required)
#   $targetHost (string)  - Remote host name or IP (required)
#   $targetPath (string)  - Remote destination path (required)
#   $pass       (string)  - Password (required for Windows/Cygwin)
#   $debug      (int)     - Optional debug flag (sets global $DEBUG)
#
# Behavior:
#   - Sets global $DEBUG to provided debug flag.
#   - Validates required arguments; croaks if missing.
#   - Normalizes targetPath with EnsureSlash().
#   - Prints debug messages showing all arguments if $DEBUG is enabled.
#   - Builds SCP command string:
#       -  On Linux/Solaris:
#           - Uses "$scp targetFile user@host:targetPath".
#           - Redirects output to $devNull unless $DEBUG.
#       -  On Windows/Cygwin:
#           - Requires $pass; croaks if missing.
#           - Uses "$scp pass targetFile user@host:targetPath".
#           - Redirects output to $devNull unless $DEBUG.
#       -  On unsupported OS:
#           - Prints debug message and returns ERROR.
#   - Executes command via system().
#   - Prints system return code if $DEBUG is enabled.
#
# Returns:
#   Integer - Exit code from system() call (0 indicates success, non-zero failure)
#
# Notes:
#   - This routine is INTERNAL; not intended for external callers.
#   - Provides cross-platform handling of SCP with password support on Windows/Cygwin.
#   - Debug mode provides traceability of arguments, command string, and system return code.
################################################################################
sub SCPTO {
    my ($self, $targetFile, $user, $targetHost, $targetPath, $pass, $debug) = @_;
    $DEBUG = $debug;

    croak "Missing required arguments" unless defined $targetFile && defined $user && defined $targetHost && defined $targetPath;
    $targetPath = EnsureSlash($targetPath);

    DebugPrint("SCPTO: targetFile = $targetFile");
    DebugPrint("SCPTO: targetHost = $targetHost");
    DebugPrint("SCPTO: targetPath = $targetPath");
    DebugPrint("SCPTO: user       = $user");
    DebugPrint("SCPTO: pass       = $pass");

    my $cmd;
    if (IS_LINUX || IS_SOLARIS) {
        $cmd = "$scp $targetFile $user\@$targetHost:$targetPath";
        $cmd .= " $devNull" unless $DEBUG;
    }
    elsif (IS_WINDOWS || IS_CYGWIN) {
        croak "Missing password for Windows/Cygwin SCP" unless defined $pass;
        $cmd = "$scp $pass $targetFile $user\@$targetHost:$targetPath";
        $cmd .= " $devNull" unless $DEBUG;
    }
    else {
        DebugPrint("Unknown OS");
        return ERROR;
    }

    DebugPrint("Executing: $cmd");
    system($cmd);
    DebugPrint("system returned $?");
    return $?;
}

################################################################################
# Subroutine : ScpToRecursive
#
# Purpose:
#   Securely copy all contents of a local root directory to a remote host
#   using recursive SCP. Provides cross-platform handling for Linux/Solaris
#   vs. Windows/Cygwin, with optional debug output for traceability.
#
# Globals Used:
#   $DEBUG     - Boolean flag controlling verbosity of printed messages
#   Constants  : IS_LINUX, IS_SOLARIS, IS_WINDOWS, IS_CYGWIN, ERROR
#   Utility subs: DebugPrint, EnsureSlash
#   Variables  : $scpr (recursive SCP command path), $devNull (output redirection)
#
# Parameters:
#   $self          (hashref) - Caller object reference
#   $targetRootDir (string)  - Local root directory to copy (required)
#   $user          (string)  - Remote user name (required)
#   $targetHost    (string)  - Remote host name or IP (required)
#   $targetPath    (string)  - Remote destination path (required)
#   $pass          (string)  - Password (required for Windows/Cygwin)
#   $debug         (int)     - Optional debug flag (sets global $DEBUG)
#
# Behavior:
#   - Sets global $DEBUG to provided debug flag.
#   - Validates required arguments; croaks if missing.
#   - Normalizes targetRootDir and targetPath with EnsureSlash().
#   - Prints debug messages showing all arguments if $DEBUG is enabled.
#   - Builds recursive SCP command string:
#       -  On Linux/Solaris:
#           - Uses "$scpr targetRootDir user@host:targetPath".
#           - Redirects output to $devNull unless $DEBUG.
#       -  On Windows/Cygwin:
#           - Requires $pass; croaks if missing.
#           - Uses "$scpr pass targetRootDir user@host:targetPath".
#           - Redirects output to $devNull unless $DEBUG.
#       -  On unsupported OS:
#           - Prints debug message and returns ERROR.
#   - Executes command via system().
#   - Prints system return code if $DEBUG is enabled.
#
# Returns:
#   Integer - Exit code from system() call (0 indicates success, non-zero failure)
#
# Notes:
#   - INTERNAL routine; not intended for external callers.
#   - Provides cross-platform handling of recursive SCP.
#   - Debug mode provides traceability of arguments, command string, and system return code.
################################################################################
sub ScpToRecursive {
    my ($self, $targetRootDir, $user, $targetHost, $targetPath, $pass, $debug) = @_;
    $DEBUG = $debug;

    croak "usage: ScpToRecursive(<targetRootDir>, <user>, <targetHost>, <targetPath>, [<pass> if windows])"
        unless defined $targetRootDir && defined $user && defined $targetHost && defined $targetPath;

    $targetRootDir = EnsureSlash($targetRootDir) . "*";
    $targetPath    = EnsureSlash($targetPath);

    DebugPrint("ScpToRecursive: targetRootDir = $targetRootDir");
    DebugPrint("ScpToRecursive: targetHost    = $targetHost");
    DebugPrint("ScpToRecursive: targetPath    = $targetPath");
    DebugPrint("ScpToRecursive: user          = $user");
    DebugPrint("ScpToRecursive: pass          = $pass");

    my $cmd;
    if (IS_LINUX || IS_SOLARIS) {
        $cmd = "$scpr $targetRootDir $user\@$targetHost:$targetPath";
        $cmd .= " $devNull" unless $DEBUG;
    }
    elsif (IS_WINDOWS || IS_CYGWIN) {
        croak "Missing password for Windows/Cygwin SCP" unless defined $pass;
        $cmd = "$scpr $pass $targetRootDir $user\@$targetHost:$targetPath";
        $cmd .= " $devNull" unless $DEBUG;
    }
    else {
        DebugPrint("ScpToRecursive: Unknown OS");
        return ERROR;
    }

    DebugPrint("ScpToRecursive: Executing -> $cmd");
    system($cmd);
    DebugPrint("ScpToRecursive: system returned $?");
    return $?;
}

################################################################################
# Subroutine : SCPFROM
#
# Purpose:
#   Securely copy a file from a remote host to a local path using SCP.
#   Provides cross-platform handling for Linux/Solaris vs. Windows/Cygwin,
#   with optional debug output for traceability.
#
# Globals Used:
#   $DEBUG     - Boolean flag controlling verbosity of printed messages
#   Constants  : IS_LINUX, IS_SOLARIS, IS_WINDOWS, IS_CYGWIN, ERROR
#   Utility subs: DebugPrint, EnsureSlash
#   Variables  : $scp (SCP command path)
#
# Parameters:
#   $self       (hashref) - Caller object reference
#   $targetFile (string)  - Remote file name (required)
#   $user       (string)  - Remote user name (required)
#   $targetHost (string)  - Remote host name or IP (required)
#   $targetPath (string)  - Remote directory path (required)
#   $pass       (string)  - Password (required for Windows/Cygwin)
#   $localPath  (string)  - Local destination path (required)
#   $debug      (int)     - Optional debug flag (sets global $DEBUG)
#
# Behavior:
#   - Sets global $DEBUG to provided debug flag.
#   - Validates required arguments; croaks if missing.
#   - Normalizes targetPath with EnsureSlash().
#   - Constructs remote file path as targetPath + targetFile.
#   - Prints debug messages showing all arguments if $DEBUG is enabled.
#   - Builds SCP command string:
#       -  On Linux/Solaris:
#           - Uses "$scp user@host:remoteFile localPath".
#       -  On Windows/Cygwin:
#           - Requires $pass; croaks if missing.
#           - Uses "$scp pass user@host:remoteFile localPath".
#       -  On unsupported OS:
#           - Prints debug message and returns ERROR.
#   - Executes command via system().
#   - Prints system return code if $DEBUG is enabled.
#
# Returns:
#   Integer - Exit code from system() call (0 indicates success, non-zero failure)
#
# Notes:
#   - INTERNAL routine; not intended for external callers.
#   - Provides cross-platform handling of SCP file retrieval.
#   - Debug mode provides traceability of arguments, command string, and system return code.
################################################################################
sub SCPFROM {
    my ($self, $targetFile, $user, $targetHost, $targetPath, $pass, $localPath, $debug) = @_;
    $DEBUG = $debug;

    croak "usage: SCPFROM(<targetFile>, <user>, <targetHost>, <targetPath>, <localPath>, [<pass> if windows])"
        unless defined $targetFile && defined $user && defined $targetHost && defined $targetPath && defined $localPath;

    $targetPath = EnsureSlash($targetPath);
    my $remoteFile = "$targetPath$targetFile";

    DebugPrint("SCPFROM: targetFile  = $targetFile");
    DebugPrint("SCPFROM: targetHost  = $targetHost");
    DebugPrint("SCPFROM: targetPath  = $targetPath");
    DebugPrint("SCPFROM: localPath   = $localPath");
    DebugPrint("SCPFROM: user        = $user");
    DebugPrint("SCPFROM: pass        = $pass");

    my $cmd;
    if (IS_LINUX || IS_SOLARIS) {
        $cmd = "$scp $user\@$targetHost:$remoteFile $localPath";
    }
    elsif (IS_WINDOWS || IS_CYGWIN) {
        croak "Missing password for Windows/Cygwin SCP" unless defined $pass;
        $cmd = "$scp $pass $user\@$targetHost:$remoteFile $localPath";
    }
    else {
        DebugPrint("SCPFROM: Unknown OS");
        return ERROR;
    }

    DebugPrint("SCPFROM: Executing -> $cmd");
    system($cmd);
    DebugPrint("SCPFROM: system returned $?");
    return $?;
}

#############################################################################
# Module terminator
#############################################################################
1;