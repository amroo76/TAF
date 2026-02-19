package FileOps;
###############################################################################
# FileOps.pm
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
#   Provide file and directory manipulation utilities used throughout TAF.
#   Includes recursive and non-recursive move operations, recursive copy
#   operations, directory content copying, file deletion by extension, and
#   file listing by extension.
#
# ARCHITECTURAL ROLE:
#   - Acts as a general-purpose file operations helper module.
#   - Provides consistent behavior across Linux and Windows environments.
#   - Wraps system commands (mv, cp, xcopy) with contributor-proof logic.
#   - Ensures predictable error handling and debug output.
#
# NOTES:
#   - All routines return OK or ERROR.
#   - Debug output is controlled by the DEBUG variable.
#   - Windows behavior uses WinHelp and RemoveDir modules.
###############################################################################
use strict;
use warnings;
use Carp;
use FindBin qw($Bin);
use lib "$Bin";
use Exporter 'import';
use File::Path qw(mkpath rmtree);
use File::Basename;
use File::Copy qw(copy);
use File::Spec;
use lib 'lib';
use lib ".";
use RemoveDir;

our @EXPORT_OK = qw(
    ListFilesWithExtension
    Move
    MoveSubs
    CopyR
    CopyRfromCurrent
    CopyContentsRecusive
    DeleteFilesWExtension
);

use constant IS_WINDOWS => ($^O =~ /^(mswin)/oi);
use constant OK         => 0;
use constant ERROR      => 1;

our $DEBUG = 0;
our $name  = __PACKAGE__;

################################################################################
# DebugPrint
#
# Purpose:
#   Print a debug message when DEBUG is enabled.
#
# Parameters:
#   $msg : Message string to print.
#
# Returns:
#   None.
################################################################################
sub DebugPrint {
    my ($msg) = @_;
    print "$name: $msg\n" if $DEBUG;
}

################################################################################
# MoveSubs
#
# Purpose:
#   Move all immediate subdirectories and files from one directory into
#   another directory (non-recursive).
#
# Behavior:
#   - Ensure the target directory exists.
#   - On Windows, delegate to Move().
#   - On Unix-like systems, iterate entries and move each item individually.
#
# Parameters:
#   $currentDir : Source directory.
#   $targetDir  : Destination directory.
#   $debug      : Debug flag.
#
# Returns:
#   OK    - All entries moved successfully.
#   ERROR - Any move operation failed.
################################################################################
sub MoveSubs {
    my ($currentDir, $targetDir, $debug) = @_;
    $DEBUG = 1;

    DebugPrint("MoveSubs: START");
    DebugPrint("MoveSubs: Source = $currentDir");
    DebugPrint("MoveSubs: Target = $targetDir");

    unless (-d $targetDir) {
        DebugPrint("MoveSubs: Creating target directory $targetDir");
        mkpath($targetDir);
    }

    if (IS_WINDOWS) {
        return Move($currentDir, $targetDir, $DEBUG);
    }

    opendir(my $dh, $currentDir) or croak "Cannot open $currentDir: $!";
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);

    foreach my $item (@entries) {
        my $source = File::Spec->catfile($currentDir, $item);
        DebugPrint("MoveSubs: Moving $source to $targetDir");
        if (Move($source, $targetDir, $DEBUG) != OK) {
            return ERROR;
        }
    }

    return OK;
}

################################################################################
# Move
#
# Purpose:
#   Move a file or directory to a target directory, recursively if needed.
#
# Behavior:
#   - Validate arguments and source existence.
#   - On Windows, use WinHelp path conversion and xcopy, then remove source.
#   - On Unix-like systems, execute mv directly.
#
# Parameters:
#   $currentDir : Source file or directory.
#   $targetDir  : Destination directory.
#   $debug      : Debug flag.
#
# Returns:
#   OK    - Move succeeded.
#   ERROR - Move failed.
################################################################################
sub Move {
    my ($currentDir, $targetDir, $debug) = @_;
    $DEBUG = 1;

    DebugPrint("Move: START");
    DebugPrint("Move: Source = $currentDir");
    DebugPrint("Move: Target = $targetDir");

    # Validate arguments
    unless (defined $currentDir && defined $targetDir) {
        DebugPrint("Move: Missing arguments");
        return ERROR;
    }

    unless (-e $currentDir) {
        DebugPrint("Move: Source does not exist -> $currentDir");
        return ERROR;
    }

    # Windows branch (unchanged from original)
    if (IS_WINDOWS) {
        $currentDir =~ s{[\\/]+$}{};  # strip trailing slash
        my $win = WinHelp->new;
        $currentDir = $win->win_path($currentDir);
        $targetDir  = $win->win_path($targetDir);

        my $cmd = $DEBUG
            ? "xcopy $currentDir $targetDir /E /Y /J"
            : "xcopy $currentDir $targetDir /Q /E /Y /J > nul 2>&1";

        DebugPrint("Move: Executing -> $cmd");
        my $rc = system($cmd);
        return ERROR if $rc != 0;

        my $rm = RemoveDir->new;
        return $rm->RemoveSub($currentDir, 50) == 0 ? OK : ERROR;
    }

    # Linux / Unix: EXACT original behavior
    DebugPrint("Move: Executing mv -> mv '$currentDir' '$targetDir'");
    my $rc = system("mv", $currentDir, $targetDir);
    DebugPrint("Move: mv exit code = $rc");

    return $rc == 0 ? OK : ERROR;
}

################################################################################
# CopyContentsRecursive
#
# Purpose:
#   Copy all contents of a source directory directly into a target directory.
#   Subdirectories are handled by the local CopyR implementation so recursion
#   remains deterministic and platform-aware.
#
# Behavior:
#   - Validate arguments and confirm source is a directory.
#   - Create target directory if missing.
#   - Enumerate entries in source directory.
#   - For each entry:
#       * If directory: recurse using $self->CopyR().
#       * If file: copy using File::Copy::copy().
#   - Return early on any failure.
#
# Parameters:
#   $self      : Invocant; provides access to CopyR().
#   $sourceDir : Directory to copy from.
#   $targetDir : Directory to copy into.
#   $debug     : Debug flag.
#
# Returns:
#   OK    - All contents copied successfully.
#   ERROR - Any copy operation failed.
#
# Notes:
#   - Recursion is intentionally delegated to CopyR to keep behavior consistent
#     across platforms and avoid mixed recursion paths.
#   - This routine performs a shallow merge: it does not delete or overwrite
#     directories beyond what CopyR handles.
################################################################################
sub CopyContentsRecursive {
    my ($self, $sourceDir, $targetDir, $debug) = @_;
    $DEBUG = $debug;

    # validate required arguments
    unless (defined $sourceDir && defined $targetDir) {
        DebugPrint("CopyContents: Missing arguments");
        return ERROR;
    }

    # enforce source must be a directory
    unless (-d $sourceDir) {
        DebugPrint("CopyContents: Source not a directory -> $sourceDir");
        return ERROR;
    }

    # ensure target directory exists before copying
    mkpath($targetDir) unless -d $targetDir;

    # open source directory for enumeration
    opendir(my $dh, $sourceDir) or return ERROR;
    while (my $entry = readdir($dh)) {

        # skip filesystem noise
        next if $entry eq '.' or $entry eq '..';

        my $src = File::Spec->catfile($sourceDir, $entry);
        my $dst = File::Spec->catfile($targetDir, $entry);

        if (-d $src) {
            # recurse into subdirectory using local CopyR implementation
            $self->CopyR($src, $targetDir, $DEBUG);
        } else {
            # copy file; fail fast on error
            copy($src, $dst) or do {
                DebugPrint("CopyContents: Failed to copy $src -> $dst");
                return ERROR;
            };
        }
    }
    closedir($dh);

    # final confirmation for debug tracing
    DebugPrint("CopyContents: copied contents of $sourceDir into $targetDir");
    return OK;
}

################################################################################
# CopyR
#
# Purpose:
#   Recursively copy a directory into a target directory.
#
# Behavior:
#   - Validate arguments.
#   - On Unix-like systems, execute cp -r.
#   - On Windows, convert paths using WinHelp and use xcopy.
#
# Parameters:
#   $self       : Invocant (unused).
#   $currentDir : Directory to copy.
#   $targetDir  : Destination directory.
#   $debug      : Debug flag.
#
# Returns:
#   System command exit code (0 indicates success).
################################################################################
sub CopyR {
    my ($self, $currentDir, $targetDir, $debug) = @_;
    $DEBUG = $debug;

    unless (defined $currentDir && defined $targetDir) {
        DebugPrint("CopyR: Missing arguments");
        return ERROR;
    }

    my $cmd = "cp -r $currentDir $targetDir";

    if (IS_WINDOWS) {
        $currentDir =~ s[/$][];
        my $winPath = WinHelp->new;
        $currentDir = $winPath->win_path($currentDir);
        $targetDir  = $winPath->win_path($targetDir);

        my $subdirName = basename($currentDir);
        my $newTarget  = "$targetDir$subdirName";
        mkpath($newTarget);

        $cmd = $DEBUG
            ? "xcopy $currentDir $newTarget /E /Y /J"
            : "xcopy $currentDir $newTarget /Q /E /Y /J > nul 2>&1";

        DebugPrint("CopyR: Windows paths -> $currentDir => $newTarget");
    }

    DebugPrint("CopyR: Executing -> $cmd");
    return system($cmd);
}

################################################################################
# CopyRfromCurrent
#
# Purpose:
#   Recursively copy all files and subdirectories from the current working
#   directory into a target directory.
#
# Behavior:
#   - Validate target directory.
#   - On Unix-like systems, execute cp -r ./*.
#   - On Windows, use xcopy with WinHelp path conversion.
#
# Parameters:
#   $self      : Invocant (unused).
#   $targetDir : Destination directory.
#   $debug     : Debug flag.
#
# Returns:
#   System command exit code (0 indicates success).
################################################################################
sub CopyRfromCurrent {
    my ($self, $targetDir, $debug) = @_;
    $DEBUG = $debug;

    unless (defined $targetDir) {
        DebugPrint("CopyRfromCurrent: Missing target directory");
        return ERROR;
    }

    my $cmd = "cp -r ./* $targetDir";

    if (IS_WINDOWS) {
        my $winPath = WinHelp->new;
        $targetDir  = $winPath->win_path($targetDir);

        $cmd = $DEBUG
            ? "xcopy * $targetDir /E /Y /J"
            : "xcopy * $targetDir /Q /E /Y /J > nul 2>&1";
    }

    DebugPrint("CopyRfromCurrent: Executing -> $cmd");
    return system($cmd);
}

################################################################################
# DeleteFilesWExtension
#
# Purpose:
#   Delete all files in a directory that match a specific file extension.
#
# Behavior:
#   - Validate directory existence.
#   - Iterate directory entries and remove matching files.
#
# Parameters:
#   $self      : Invocant (unused).
#   $targetDir : Directory to scan.
#   $targetExt : File extension to delete (without dot).
#   $debug     : Debug flag.
#
# Returns:
#   OK    - All matching files deleted.
#   ERROR - Directory missing or deletion failed.
################################################################################
sub DeleteFilesWExtension {
    my ($self, $targetDir, $targetExt, $debug) = @_;
    $DEBUG = $debug;

    DebugPrint("DeleteFilesWExtension: dir = $targetDir, ext = $targetExt");

    unless (-d $targetDir) {
        DebugPrint("DeleteFilesWExtension: Directory does not exist");
        return ERROR;
    }

    opendir(my $dh, $targetDir) or return ERROR;
    while (my $file = readdir($dh)) {
        next unless $file =~ /\.\Q$targetExt\E$/;

        my $fullPath = IS_WINDOWS
            ? "$targetDir\\$file"
            : "$targetDir/$file";

        DebugPrint("DeleteFilesWExtension: Removing $fullPath");
        unlink $fullPath or return ERROR;
    }
    closedir($dh);

    return OK;
}

################################################################################
# ListFilesWithExtension
#
# Purpose:
#   List all files in a directory that match a specific file extension.
#
# Behavior:
#   - Validate directory existence.
#   - Iterate directory entries and collect matching filenames.
#
# Parameters:
#   $self      : Invocant (unused).
#   $targetDir : Directory to scan.
#   $targetExt : File extension to match (without dot).
#   $debug     : Debug flag.
#
# Returns:
#   @fileList  - List of matching filenames.
#   ERROR      - Directory missing or read failure.
################################################################################
sub ListFilesWithExtension {
    my ($self, $targetDir, $targetExt, $debug) = @_;
    $DEBUG = $debug;
    my @fileList;

    DebugPrint("ListFilesWithExtension: dir = $targetDir, ext = $targetExt");

    unless (-d $targetDir) {
        DebugPrint("ListFilesWithExtension: Directory does not exist");
        return ERROR;
    }

    opendir(my $dh, $targetDir) or return ERROR;
    while (my $file = readdir($dh)) {
        next unless $file =~ /\.\Q$targetExt\E$/;
        DebugPrint("ListFilesWithExtension: Found $file");
        push @fileList, $file;
    }
    closedir($dh);

    return @fileList;
}

#############################################################################
# Module terminator
#############################################################################
1;