package RemoveDir;
#############################################################################
# RemoveDir
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
#     Provide deterministic, contributor-proof routines for removing files and
#     directories. This module offers simple, cross-platform primitives for
#     deleting directory trees, individual files, and temporary artifacts used
#     throughout toolsLib and higher-level TAF components.
#
# ARCHITECTURAL ROLE:
#     - Acts as the unified deletion utility for toolsLib.
#     - Provides predictable, minimal wrappers around platform-specific
#       filesystem removal behavior.
#     - Ensures consistent semantics for recursive directory removal and
#       explicit file deletion.
#     - Supports cleanup operations used by installers, test harnesses, and
#       environment preparation scripts.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not perform selective pruning or pattern-based deletion.
#     - Does not modify permissions or attempt forced removal beyond what the
#       OS allows.
#     - Does not guess caller intent or silently skip failures.
#     - Does not die(); all routines return simple status values.
#
# CONTRACT:
#     - All routines must:
#           * accept explicit paths only
#           * avoid mutating anything outside caller-provided paths
#           * return OK or ERROR values consistently
#           * emit debug output only when enabled
#     - Recursive removal must be explicit and deterministic.
#     - File and directory existence checks must be performed safely.
#
# GUARANTEES:
#     - No silent fallbacks or ambiguous behavior.
#     - No mutation outside the specified path.
#     - Removal behavior is deterministic and contributor-proof.
#     - Debug output is minimal and traceable when enabled.
#
# NOTES:
#     - This module is intentionally narrow in scope; it provides only the
#       deletion primitives required by toolsLib and higher-level TAF
#       components.
#     - Any change to removal semantics must be reflected in this header and
#       in the TAF manual.
#############################################################################
#use strict;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK $VERSION);
use Carp;
use Exporter;
use Cwd;
use File::Path qw(rmtree mkpath);

@ISA = qw(Exporter);
@EXPORT = qw(&new &RemoveDirectory &RemoveSub &PurgeDir);
$VERSION = '1.0';

our $DEBUG = 0;

use constant IS_WINDOWS => ($^O =~ /^(mswin)/oi);
use constant IS_LINUX   => ($^O =~ /^(linux)/oi);
use constant IS_SOLARIS => ($^O =~ /^(solaris)/oi);
use constant OK    => 0;
use constant ERROR => 1;


################################################################################
# Create an Object
################################################################################
sub new {
    my ($class, %args) = @_;
    my $self = {};
    bless $self, $class;
    return $self;
}

################################################################################
# Function : CountSubs
# Purpose  : Count the number of entries (files and directories) inside a target directory.
#
# Details  :
#   - Arguments:
#       * $target : Path to the directory to scan.
#   - Behavior:
#       * Opens the directory handle for $target.
#       * Iterates through each entry returned by readdir().
#       * Skips the special entries '.' and '..'.
#       * Increments a counter for each remaining entry.
#       * Closes the directory handle after processing.
#
# Returns  : Integer count of entries found in the directory (excluding '.' and '..').
################################################################################
sub CountSubs {
    my $target = shift;
    my $count = 0;
    opendir(DIR,$target);
    LINE: while(my $FILE = readdir(DIR)){
        next LINE if($FILE =~ /^\.\.?/);
        $count++;
    }
    close(DIR);
    return $count;
}

################################################################################
# Function : RemoveDirectory
# Purpose  : Remove a target directory with retry logic and error diagnostics.
#
# Details  :
#   - Arguments:
#       * $targetDir : Path to the directory to remove (required).
#       * $maxLoops  : Maximum number of retry attempts (default = 10).
#       * $DEBUG     : Boolean flag to enable verbose debug output.
#
#   - Behavior:
#       * Validates that $targetDir is defined; croaks if missing.
#       * Defaults $maxLoops to 10 if not provided.
#       * Retrieves the installed File::Path version.
#       * If $DEBUG is enabled, prints diagnostic information including
#         target directory, max loops, and File::Path version.
#       * If the directory does not exist, warns (if $DEBUG) and returns ERROR.
#       * While the directory still exists and retry count < $maxLoops:
#           - Uses rmtree() to attempt removal.
#           - For File::Path versions > 2:
#               * Captures errors in $err arrayref.
#               * Prints detailed diagnostics for each error if present.
#               * Retries after sleeping for 1 second.
#           - For older versions:
#               * Wraps rmtree() in eval.
#               * On failure, prints error (if $DEBUG), retries, and sleeps.
#       * If retries exceed $maxLoops, warns (if $DEBUG) and returns ERROR.
#       * On success, returns OK.
#
# Returns  : OK on success, ERROR on failure or exceeding max retries.
################################################################################
sub RemoveDirectory {
    my ($self, $targetDir, $maxLoops, $DEBUG) = @_;
    my $retry     = 0;
    my $sleepTime = 1;

    # enforce required argument
    croak "usage: RemoveDirectory(<targetDir>, [<Max Loops>])"
        unless defined $targetDir;

    # default retry limit if caller does not supply one
    $maxLoops = 10 unless defined $maxLoops;

    # optional debug banner
    print "\n=== RemoveDirectory DEBUG START ===\n" if $DEBUG;
    print "targetDir = $targetDir\n" if $DEBUG;
    print "maxLoops  = $maxLoops\n" if $DEBUG;
    print "File::Path VERSION = $File::Path::VERSION\n" if $DEBUG;
    print "Using legacy rmtree() ONLY (vendor File::Path)\n" if $DEBUG;

    # nothing to remove if directory is already gone
    unless (-e $targetDir) {
        print "Directory does not exist at start\n" if $DEBUG;
        print "=== RemoveDirectory DEBUG END ===\n" if $DEBUG;
        return ERROR;
    }

    # retry loop to handle transient filesystem locks
    while ($retry < $maxLoops && -e $targetDir) {
        print "\n--- Attempt $retry ---\n" if $DEBUG;
        print "Directory exists before attempt: YES\n" if $DEBUG;

        eval {
            # legacy rmtree: debug flag controls verbosity, 0 = no safe mode
            File::Path::rmtree($targetDir, $DEBUG ? 1 : 0, 0);
        };

        if ($@) {
            # rmtree threw an exception; retry after delay
            print "rmtree threw exception: $@\n" if $DEBUG;
            $retry++;
            sleep $sleepTime;
            next;
        }

        print "Directory exists after attempt: "
            . (-e $targetDir ? "YES" : "NO") . "\n" if $DEBUG;

        # exit loop early if directory is gone
        last unless -e $targetDir;

        # directory still present; increment retry and wait
        $retry++;
        sleep $sleepTime;
    }

    # final state check after exhausting retries
    if (-e $targetDir) {
        print "FAILED: Directory still exists after $maxLoops attempts\n" if $DEBUG;
        print "=== RemoveDirectory DEBUG END ===\n" if $DEBUG;
        return ERROR;
    }

    print "SUCCESS: Directory removed\n" if $DEBUG;
    print "=== RemoveDirectory DEBUG END ===\n" if $DEBUG;
    return OK;
}

################################################################################
# Function : RemoveSub
# Purpose  : Remove all contents (subdirectories and files) beneath a target
#            directory while preserving the root directory itself.
#
# Details  :
#   - Arguments:
#       * $targetDir : Path to the directory whose contents should be removed.
#       * $maxLoops  : Maximum number of retry attempts (default = 10).
#
#   - Behavior:
#       * Validates that $targetDir is defined; croaks if missing.
#       * Defaults $maxLoops to 10 if not provided.
#       * Retrieves the installed File::Path version.
#       * If $DEBUG is enabled, prints diagnostic information including
#         target directory, max loops, and File::Path version.
#       * If the directory exists:
#           - Counts current entries using CountSubs().
#           - While entries remain and retry count < $maxLoops:
#               - For File::Path versions > 2:
#                   - Calls rmtree() with keep_root => 1 to remove contents only.
#                   - Captures and reports errors if present.
#                   - Retries after sleeping if errors occur.
#                   - Updates currentCount after successful removal.
#               - For older versions:
#                   - Calls rmtree() in eval.
#                   - On failure, reports error and retries.
#                   - If root directory is removed, attempts to recreate it
#                     with mkpath(); returns OK or ERROR depending on success.
#                   - Updates currentCount after successful removal.
#           - If retries exceed $maxLoops, warns (if $DEBUG) and returns ERROR.
#       * If the directory does not exist, warns (if $DEBUG) and returns ERROR.
#       * On success, returns OK.
#
# Returns  : OK on success, ERROR on failure or exceeding max retries.
################################################################################
sub RemoveSub {
    my $self = shift;
    my ($targetDir, $maxLoops) = @_;
    my $retry        = 0;
    my $sleepTime    = 1;
    my $err          = undef;
    my $currentCount = 0;

    # enforce required argument
    croak "usage: RemoveSub(<targetDir>, [<Max Loops>])"
        unless defined $targetDir;

    # default retry limit if caller does not supply one
    $maxLoops //= 10;

    my $version = $File::Path::VERSION;
    if ($DEBUG) {
        print("RemoveDir->RemoveSub-> Removing everything below $targetDir\n");
        print("RemoveDir->RemoveSub-> Max Loops = $maxLoops\n");
        print("RemoveDir->RemoveSub-> File::Path version = $version\n");
    }

    # directory must exist to perform a subtree purge
    if (-e $targetDir) {

        # count initial children to know when purge is complete
        $currentCount = CountSubs($targetDir);

        # retry loop to handle transient locks or partial removals
        while ($retry < $maxLoops && $currentCount > 0) {
            print("RemoveDir->RemoveSub-> Loop $retry, sub count = $currentCount\n") if $DEBUG;
            $err = "";

            if ($version > 2) {
                # modern rmtree API with structured error reporting
                print "RemoveDir->RemoveSub-> Using rmtree >= 2.08\n" if $DEBUG;
                rmtree($targetDir, { error => \$err, keep_root => 1, verbose => $DEBUG });

                if (@{$err}) {
                    # rmtree reported per-file diagnostics
                    if ($DEBUG) {
                        for my $diag (@{$err}) {
                            my ($file, $message) = %$diag;
                            if ($file eq '') {
                                print("RemoveDir->RemoveSub-> General error: $message\n");
                            } else {
                                print("RemoveDir->RemoveSub-> Problem unlinking $file: $message\n");
                            }
                        }
                    }
                    # retry after delay
                    $retry++;
                    sleep $sleepTime;
                } else {
                    # update remaining child count
                    $currentCount = CountSubs($targetDir);
                }

            } else {
                # legacy rmtree path: no structured error reporting
                print "RemoveDir->RemoveSub-> Using legacy rmtree\n" if $DEBUG;
                eval { rmtree($targetDir) };

                if ($@) {
                    # rmtree threw exception; retry
                    print "RemoveDir->RemoveSub-> rmtree failed: $@\n" if $DEBUG;
                    $retry++;
                    sleep $sleepTime;
                } else {

                    # legacy rmtree may remove the root; recreate if needed
                    unless (-d $targetDir) {
                        print "RemoveDir->RemoveSub-> mkpath $targetDir\n" if $DEBUG;
                        eval { mkpath($targetDir) };
                        if ($@) {
                            carp("RemoveDir->RemoveSub-> mkpath failed: $@\n") if $DEBUG;
                            return ERROR;
                        } else {
                            return OK;
                        }
                    }

                    # update remaining child count
                    $currentCount = CountSubs($targetDir);
                }
            }
        }

        # retries exhausted but children remain
        if ($retry >= $maxLoops) {
            carp("RemoveDir->RemoveSub-> retries exhausted ($retry/$maxLoops)\n") if $DEBUG;
            return ERROR;
        }

    } else {
        # directory missing at start is an immediate failure
        carp("RemoveDir->RemoveSub-> Directory $targetDir not found\n") if $DEBUG;
        return ERROR;
    }

    return OK;
}

################################################################################
# Function : PurgeDir
# Purpose  : Remove files or subdirectories older than a specified retention
#            threshold from a target directory.
#
# Details  :
#   - Arguments:
#       * $directoryToPurge : Path to the directory to purge (required).
#       * $daysToKeep       : Number of days to retain files (default = 7 if
#                             undefined or less than 1).
#       * $DEBUG            : Boolean flag to enable verbose debug output.
#
#   - Behavior:
#       * Validates that $directoryToPurge is defined; croaks if missing.
#       * If the directory does not exist, warns (if $DEBUG) and returns ERROR.
#       * Defaults $daysToKeep to 7 if not provided or invalid.
#       * If $DEBUG is enabled, prints diagnostic information including
#         target directory and retention threshold.
#       * Constructs an OS-specific purge command:
#           - On Windows:
#               - Uses `forfiles` to delete files older than $daysToKeep days.
#               - Converts forward slashes to backslashes and strips trailing
#                 backslash.
#               - Suppresses output unless $DEBUG is enabled.
#           - On Linux/Solaris:
#               - Uses `find` with `-mtime +$daysToKeep` to locate old
#                 directories and remove them recursively.
#               - Suppresses output unless $DEBUG is enabled.
#           - On unsupported OS:
#               - Warns (if $DEBUG) and returns ERROR.
#       * Executes the purge command via system().
#
# Returns  : System call result code (0 on success, non-zero on failure).
################################################################################
sub PurgeDir {
    my ($self, $directoryToPurge, $daysToKeep, $DEBUG) = @_;
    my $rc = OK;   # final return code

    croak "usage: RemoveDir::PurgeDir(<directoryToPurge>, [<daysToKeep>, <debug>])"
        unless defined $directoryToPurge;

    # Validate directory
    if(!DirIsvalid($directoryToPurge)) {
        carp "PurgeDir => Invalid directory '$directoryToPurge'" if $DEBUG;
        return ERROR;
    }

    print "PurgeDir => Called for: $directoryToPurge\n" if $DEBUG;

    # Validate days
    if (!defined $daysToKeep || $daysToKeep < 1) {
        print "PurgeDir => WARNING: Invalid daysToKeep '$daysToKeep', defaulting to 7\n" if $DEBUG;
        $daysToKeep = 7;
    }

    print "PurgeDir => Retention threshold: $daysToKeep days\n" if $DEBUG;

    # Normalize directory path
    $directoryToPurge =~ s{[\\/]+$}{};

    # Root-safety guard
    if ($directoryToPurge eq '' || $directoryToPurge eq '/' || $directoryToPurge eq '\\') {
        carp "PurgeDir => Refusing to purge unsafe directory: '$directoryToPurge'" if $DEBUG;
        return ERROR;
    }

    if (IS_WINDOWS) {

        my $winDir = $directoryToPurge;
        $winDir =~ s{/}{\\}g;

        my $cmd = "forfiles /P \"$winDir\" /S /M *.* /D -$daysToKeep /C \"cmd /c del \@path\"";
        $cmd .= " > NUL 2>NUL" unless $DEBUG;

        print "PurgeDir => Executing: $cmd\n" if $DEBUG;
        my $res = system($cmd);
        $rc = ERROR if $res != 0;
    }
    elsif (IS_LINUX || IS_SOLARIS) {

        # Delete files older than N days
        my $cmd_files = "find \"$directoryToPurge\" -mtime +$daysToKeep -type f -exec rm -f {} \\;";
        $cmd_files .= " > /dev/null 2>&1" unless $DEBUG;

        print "PurgeDir => Executing: $cmd_files\n" if $DEBUG;
        my $res = system($cmd_files);
        return ERROR if $res != OK;

        # Delete empty directories older than N days
        my $cmd_dirs = "find \"$directoryToPurge\" -mtime +$daysToKeep -type d -empty -exec rmdir {} \\;";
        $cmd_dirs .= " > /dev/null 2>&1" unless $DEBUG;

        print "PurgeDir => Executing: $cmd_dirs\n" if $DEBUG;
        $res = system($cmd_dirs);
        return ERROR if $res != OK;
    }
    else {
        carp "PurgeDir => Unsupported operating system!" if $DEBUG;
        return ERROR;
    }

    print "PurgeDir => Complete\n" if $DEBUG;
    return $rc;
}

#############################################################################
# Module terminator
#############################################################################
1;