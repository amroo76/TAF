package Archiver;
#############################################################################
# Archiver
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
#     Provide a deterministic, cross platform archiving utility for TAF and
#     test tooling. This module abstracts platform differences (Windows,
#     Cygwin, Linux, Solaris) and exposes a unified interface for creating
#     compressed or uncompressed archives from files and directories.
#
# ARCHITECTURAL ROLE:
#     - Acts as a standalone utility module used by test tools, not by the
#       core TAF runtime.
#     - Normalizes archive creation across platforms by selecting the correct
#       compression command (zip or tar) at construction time.
#     - Provides four archive entry points:
#           Archive()
#           ArchiveNoCompression()
#           ArchiveRelative()
#           ArchiveRelativeNoCompression()
#     - Ensures consistent invocation of OS specific utilities and suppresses
#       platform noise via redirectable devNull settings.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not interpret TAF context or metadata.
#     - Does not manage result directories or reporting.
#     - Does not guess archive formats; behavior is explicit per method.
#     - Does not silently fall back to alternative tools if zip/tar is missing.
#
# CONTRACT:
#     - Caller must instantiate the module via Archiver->new().
#     - Constructor performs platform detection and sets:
#           zipCmd
#           noCompressCmd
#           devNull
#     - Caller must pass valid paths to Archive* routines.
#     - All failures (missing tools, missing paths, OS errors) must be explicit.
#
# GUARANTEES:
#     - Archive behavior is deterministic across supported platforms.
#     - Compression commands are resolved once at construction time.
#     - No modification of caller working directory beyond temporary changes
#       required for relative archiving.
#
# NOTES:
#     - This module predates the TAF plugin architecture but is maintained
#       for compatibility with existing test tooling.
#     - Future archive behavior (e.g., zstd, pigz) must be added explicitly
#       and documented in this header.
#############################################################################
use strict;
use warnings;
use Carp;
use Cwd;
use FindBin qw($Bin);
use Exporter 'import';

our @EXPORT_OK = qw(Archive 
                    ArchiveNoCompression 
                    ArchiveRelative 
                    ArchiveRelativeNoCompression);
our $VERSION   = '2.0';

# Platform constants
use constant IS_WINDOWS => ($^O =~ /^(mswin)/oi);
use constant IS_CYGWIN  => ($^O =~ /^(cygwin)/oi);
use constant IS_LINUX   => ($^O =~ /^(linux)/oi);
use constant IS_SOLARIS => ($^O =~ /^(solaris)/oi);

###############################################################################
# Constructor
###############################################################################
sub new {
    my ($class, %args) = @_;
    my $self = {
        DEBUG         => $args{DEBUG} // 0,
        startDir      => getcwd,
        zipCmd        => undef,
        noCompressCmd => undef,
        devNull       => undef,
    };
    bless $self, $class;
    $self->_setup_zip_command;
    return $self;
}

################################################################################
# Subroutine : _setup_zip_command
#
# Purpose:
#   Initialize compression command properties based on the detected operating
#   system. Ensures zip/tar utilities are available and sets $self attributes
#   for consistent invocation across platforms.
#
# Globals Used:
#   $Bin  - Script base directory, used to construct candidate paths
#   $^O   - Perl built-in variable indicating current OS
#
# Parameters:
#   $self (hashref) - Caller object reference; must contain:
#                       startDir => original working directory to restore
#
# Behavior:
#   - On Windows/Cygwin:
#       * Checks for zip.exe in $Bin.
#       * If found, resolves absolute path and sets:
#           $self->{zipCmd}        = "<zip.exe> -qr"
#           $self->{noCompressCmd} = "<zip.exe> -0qr"
#           $self->{devNull}       = "> NUL 2>NUL"
#       * Restores working directory to $self->{startDir}.
#       * Croaks if zip.exe is not found.
#
#   - On Linux:
#       * Sets tar-based commands:
#           $self->{zipCmd}        = "tar -czvf"
#           $self->{noCompressCmd} = "tar -cvf"
#           $self->{devNull}       = "> /dev/null 2>&1"
#
#   - On Solaris:
#       * Uses gtar instead of tar:
#           $self->{zipCmd}        = "gtar -czvf"
#           $self->{noCompressCmd} = "gtar -cvf"
#           $self->{devNull}       = "> /dev/null 2>&1"
#
#   - On unsupported OS:
#       * Croaks with explicit error message including $^O.
#
# Returns:
#   None explicitly. Updates $self hashref in place with compression command
#   properties appropriate for the current platform.
#
# Notes:
#   - INTERNAL routine; not intended for external callers.
#   - Candidate paths are now limited to $Bin/zip.exe.
#   - Temporary chdir is used to resolve absolute path to zip.exe; caller (TM)s
#     working directory is restored immediately after.
################################################################################
sub _setup_zip_command {
    my $self = shift;

    if (IS_WINDOWS() || IS_CYGWIN()) {
        my $zip = File::Spec->catfile($Bin, 'helpers', 'zip.exe');

        if (-e $zip) {
            my $full = File::Spec->rel2abs($zip);
            $self->{zipCmd}        = "\"$full\" -qr";
            $self->{noCompressCmd} = "\"$full\" -0qr";
            $self->{devNull}       = "> NUL 2>NUL";
            return;
        }
        croak "Unable to locate zip.exe in $Bin/helpers from $self->{startDir}";
    }
    elsif (IS_LINUX()) {
        $self->{zipCmd}        = "tar -czvf";
        $self->{noCompressCmd} = "tar -cvf";
        $self->{devNull}       = "> /dev/null 2>&1";
    }
    elsif (IS_SOLARIS()) {
        $self->{zipCmd}        = "gtar -czvf";
        $self->{noCompressCmd} = "gtar -cvf";
        $self->{devNull}       = "> /dev/null 2>&1";
    }
    else {
        croak "Unsupported operating system: $^O";
    }
}

################################################################################
# Subroutine: Archive
#
# Purpose:
#   Create a compressed archive of a target directory or file using the
#   platform-specific compression command previously set up in _setup_zip_command.
#   Provides optional naming of the archive file and supports debug output.
#
# Globals Used:
#   $self->{zipCmd}        - Compression command string (zip/tar/gtar) with flags
#   $self->{devNull}       - OS-specific redirection string to suppress output
#   $self->{DEBUG}         - Boolean flag controlling verbosity
#
# Parameters:
#   $self   (hashref)      - Caller object reference containing compression settings
#   $target (string)       - Path to directory or file to be archived (required)
#   $zipName (string)      - Name of archive file to create (optional, defaults to "archive.gz")
#
# Behavior:
#   - Validates that $target is defined; croaks with usage message if missing.
#   - Defaults $zipName to "archive.gz" if not provided.
#   - Constructs compression command:
#       * If DEBUG is true: include zipCmd and target, no output suppression.
#       * If DEBUG is false: append devNull redirection to suppress command output.
#   - Prints the command string to STDOUT when DEBUG is enabled.
#   - Executes the command via system() and returns its exit status.
#
# Returns:
#   Integer exit code from system() call:
#     0   - Success
#     >0  - Error code from compression utility
#
# Notes:
#   - Relies on _setup_zip_command having initialized $self->{zipCmd} and $self->{devNull}.
#   - Archive name extension (.gz, .zip, etc.) should match the compression utility in use.
#   - Debug mode is useful for troubleshooting command construction and execution.
#   - This routine is INTERNAL; not intended for external callers without proper setup.
################################################################################
sub Archive {
    my ($self, $target, $zipName) = @_;
    croak "usage: Archive(<target>, [<archive name>])" unless defined $target;
    $zipName ||= "archive.gz";

    my $cmd = $self->{DEBUG}
        ? "$self->{zipCmd} $zipName $target"
        : "$self->{zipCmd} $zipName $target $self->{devNull}";

    print "Running: $cmd\n" if $self->{DEBUG};
    return system($cmd);
}

################################################################################
# Subroutine: ArchiveNoCompression
#
# Purpose:
#   Create an archive of a target directory or file without applying compression.
#   Uses the platform-specific "no compression" command initialized by
#   _setup_zip_command and supports optional archive naming and debug output.
#
# Globals Used:
#   $self->{noCompressCmd} - Archive command string (zip/tar/gtar) with flags
#   $self->{devNull}       - OS-specific redirection string to suppress output
#   $self->{DEBUG}         - Boolean flag controlling verbosity
#
# Parameters:
#   $self    (hashref)     - Caller object reference containing archive settings
#   $target  (string)      - Path to directory or file to be archived (required)
#   $zipName (string)      - Name of archive file to create (optional, defaults to "archive.gz")
#
# Behavior:
#   - Validates that $target is defined; croaks with usage message if missing.
#   - Defaults $zipName to "archive.gz" if not provided.
#   - Constructs archive command:
#       * If DEBUG is true: include noCompressCmd and target, no output suppression.
#       * If DEBUG is false: append devNull redirection to suppress command output.
#   - Prints the constructed command string to STDOUT when DEBUG is enabled.
#   - Executes the command via system() and returns its exit status.
#
# Returns:
#   Integer exit code from system() call:
#     0   - Success
#     >0  - Error code from archive utility
#
# Notes:
#   - Relies on _setup_zip_command having initialized $self->{noCompressCmd}
#     and $self->{devNull}.
#   - Archive name extension (.gz, .zip, etc.) should match the utility in use.
#   - Debug mode is useful for troubleshooting command construction and execution.
#   - This routine is INTERNAL; not intended for external callers without proper setup.
################################################################################
sub ArchiveNoCompression {
    my ($self, $target, $zipName) = @_;
    croak "usage: ArchiveNoCompression(<target>, [<archive name>])"
        unless defined $target;

    $zipName ||= "archive.gz";
    my $cmd = $self->{DEBUG}
        ? "$self->{noCompressCmd} $zipName $target"
        : "$self->{noCompressCmd} $zipName $target $self->{devNull}";

    print "ArchiveNoCompression -> $cmd\n" if $self->{DEBUG};
    return system($cmd);
}

################################################################################
# Subroutine: ArchiveRelative
#
# Purpose:
#   Create a compressed archive of a target directory using relative paths.
#   Temporarily changes into the target directory so that only its contents
#   (not the absolute path) are included in the archive. Supports optional
#   archive naming and debug output.
#
# Globals Used:
#   $self->{zipCmd}        - Compression command string (zip/tar/gtar) with flags
#   $self->{devNull}       - OS-specific redirection string to suppress output
#   $self->{DEBUG}         - Boolean flag controlling verbosity
#   $self->{startDir}      - Original working directory to restore after archiving
#
# Parameters:
#   $self    (hashref)     - Caller object reference containing compression settings
#   $target  (string)      - Path to directory whose contents will be archived (required)
#   $zipName (string)      - Name of archive file to create (optional, defaults to "archive.gz")
#
# Behavior:
#   - Validates that $target is defined; croaks with usage message if missing.
#   - Defaults $zipName to "archive.gz" if not provided.
#   - Changes working directory to $target; croaks if chdir fails.
#   - Constructs compression command:
#       * If DEBUG is true: include zipCmd and target contents, no output suppression.
#       * If DEBUG is false: append devNull redirection to suppress command output.
#   - Prints debug messages showing chdir, command string, and return code.
#   - Executes the command via system() and captures its exit status.
#   - Restores working directory to $self->{startDir}; croaks if chdir fails.
#   - Prints debug message confirming restoration of working directory.
#
# Returns:
#   Integer exit code from system() call:
#     0   - Success
#     >0  - Error code from compression utility
#
# Notes:
#   - Relies on _setup_zip_command having initialized $self->{zipCmd} and $self->{devNull}.
#   - Relative archiving ensures the archive contains only the target (TM)s contents,
#     not its full path.
#   - Debug mode provides traceability of directory changes, command execution,
#     and return codes for troubleshooting.
#   - This routine is INTERNAL; not intended for external callers without proper setup.
################################################################################
sub ArchiveRelative {
    my ($self, $target, $zipName) = @_;
    croak "usage: ArchiveRelative(<target>, [<archive name>])"
        unless defined $target;

    $zipName ||= "archive.gz";
    chdir($target) or croak "Failed to chdir to $target: $!";

    my $cmd = $self->{DEBUG}
        ? "$self->{zipCmd} $zipName *"
        : "$self->{zipCmd} $zipName * $self->{devNull}";

    print "ArchiveRelative -> chdir to $target\n" if $self->{DEBUG};
    print "ArchiveRelative -> $cmd\n" if $self->{DEBUG};

    my $rc = system($cmd);

    chdir($self->{startDir}) or croak "Failed to chdir back to $self->{startDir}: $!";
    print "ArchiveRelative -> chdir back to $self->{startDir}\n" if $self->{DEBUG};
    print "ArchiveRelative -> Return Code = $rc\n" if $self->{DEBUG};

    return $rc;
}

################################################################################
# Subroutine: ArchiveRelativeNoCompression
#
# Purpose:
#   Create an archive of a target directory using relative paths, but without
#   applying compression. Temporarily changes into the target directory so that
#   only its contents (not the absolute path) are included in the archive.
#   Supports optional archive naming and debug output.
#
# Globals Used:
#   $self->{noCompressCmd} - Archive command string (zip/tar/gtar) with flags
#   $self->{devNull}       - OS-specific redirection string to suppress output
#   $self->{DEBUG}         - Boolean flag controlling verbosity
#   $self->{startDir}      - Original working directory to restore after archiving
#
# Parameters:
#   $self    (hashref)     - Caller object reference containing archive settings
#   $target  (string)      - Path to directory whose contents will be archived (required)
#   $zipName (string)      - Name of archive file to create (optional, defaults to "archive.gz")
#
# Behavior:
#   - Validates that $target is defined; croaks with usage message if missing.
#   - Defaults $zipName to "archive.gz" if not provided.
#   - Changes working directory to $target; croaks if chdir fails.
#   - Constructs archive command:
#       * If DEBUG is true: include noCompressCmd and target contents, no output suppression.
#       * If DEBUG is false: append devNull redirection to suppress command output.
#   - Prints debug messages showing chdir, command string, and return code.
#   - Executes the command via system() and captures its exit status.
#   - Restores working directory to $self->{startDir}; croaks if chdir fails.
#   - Prints debug message confirming restoration of working directory.
#
# Returns:
#   Integer exit code from system() call:
#     0   - Success
#     >0  - Error code from archive utility
#
# Notes:
#   - Relies on _setup_zip_command having initialized $self->{noCompressCmd}
#     and $self->{devNull}.
#   - Relative archiving ensures the archive contains only the target (TM)s contents,
#     not its full path.
#   - Debug mode provides traceability of directory changes, command execution,
#     and return codes for troubleshooting.
#   - This routine is INTERNAL; not intended for external callers without proper setup.
################################################################################
sub ArchiveRelativeNoCompression {
    my ($self, $target, $zipName) = @_;
    croak "usage: ArchiveRelativeNoCompression(<target>, [<archive name>])"
        unless defined $target;

    $zipName ||= "archive.gz";
    chdir($target) or croak "Failed to chdir to $target: $!";

    my $cmd = $self->{DEBUG}
        ? "$self->{noCompressCmd} $zipName *"
        : "$self->{noCompressCmd} $zipName * $self->{devNull}";

    print "ArchiveRelativeNoCompression -> chdir to $target\n" if $self->{DEBUG};
    print "ArchiveRelativeNoCompression -> $cmd\n" if $self->{DEBUG};

    my $rc = system($cmd);

    chdir($self->{startDir}) or croak "Failed to chdir back to $self->{startDir}: $!";
    print "ArchiveRelativeNoCompression -> chdir back to $self->{startDir}\n" if $self->{DEBUG};
    print "ArchiveRelativeNoCompression -> Return Code = $rc\n" if $self->{DEBUG};

    return $rc;
}

#############################################################################
# Module terminator
#############################################################################
1;
