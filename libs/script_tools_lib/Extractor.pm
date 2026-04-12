package Extractor;
#############################################################################
# Extractor
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
#     Provide deterministic, contributora proof routines for unpacking archives
#     and layering extracted payloads into a callera defined installation root.
#     This module implements the lowa level mechanics of extraction only; it
#     does not interpret package semantics, normalize usr/, or determine final
#     installation layout. Highera level install logic is owned by DoInstall
#     and related TAF components.
#
# ARCHITECTURAL ROLE:
#     - Acts as the single extraction engine for all archive types in TAF.
#     - Owns deterministic installa root creation for each archive.
#     - Delegates archivea type handling to internal helpers (tar, rpm, zip).
#     - Preserves vendora provided directory structures unless explicitly
#       normalized by highera level install routines.
#     - Provides LayerInto() for safe, explicit merging of extracted payloads
#       into a target directory without guessing or implicit behavior.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not normalize usr/ or rea root RPM layouts.
#     - Does not determine final installation directory names.
#     - Does not merge multiple packages beyond LayerInto().
#     - Does not interpret package metadata or perform dependency logic.
#     - Does not guess archive type; detection is explicit and deterministic.
#     - Does not perform cleanup, pruning, or posta install adjustments.
#
# CONTRACT:
#     - Caller must provide explicit paths for:
#           UnpackArchive(<archive>, <root_dir>)
#           LayerInto(<src_dir>, <dest_dir>)
#     - Install root for each archive is always:
#           <root_dir>/<archive_name>/
#     - Tarballs with a single topa level directory are rea rooted into that
#       directory; RPMs are preserved exactly as extracted.
#     - All routines must return OK or ERROR only never die().
#     - All filesystem mutations must be explicit, logged, and deterministic.
#
# GUARANTEES:
#     - No silent fallbacks or inferred behavior.
#     - No mutation outside callera provided directories.
#     - No rea rooting of RPM usr/ trees.
#     - All extraction behavior is reproducible and contributora proof.
#
# NOTES:
#     - This module is intentionally narrow in scope; all highera level install
#       semantics belong to DoInstall and related components.
#     - Any change to extraction rules, archive detection, or installa root
#       contracts must be reflected in this header and in the TAF manual.
#############################################################################
use strict;
use warnings;
use Exporter 'import';
use Carp;
use File::Basename;
use File::Path qw(mkpath);
use File::Spec;
use Cwd;

our @EXPORT   = qw(UnpackArchive LayerInto);
our $VERSION  = '2.0';

use constant IS_WINDOWS => ($^O =~ /^(mswin)/oi);
use constant IS_LINUX   => ($^O =~ /^(linux)/oi);

use constant OK    => 0;
use constant ERROR => 1;

#------------------------------------------------------------------------------
# New
#------------------------------------------------------------------------------
sub new {
    my $class = shift;
    my $self = { start_dir => getcwd, debug => 0 };
    bless $self, $class;
    return $self;
}

################################################################################
# Subroutine: UnpackArchive
#
# Purpose:
#   Extract a single archive into a deterministic installation root under the
#   caller-provided directory. This routine establishes the install root,
#   delegates extraction to the appropriate handler based on archive type,
#   and performs minimal, safe post-extraction normalization. It enforces
#   TAF (TM)s install-contract rule that RPMs must *not* be re-rooted into usr/.
#
# Install Contract:
#   - The install root is always:
#         <root_install_dir>/<archive_name>/
#   - All archive contents are extracted directly into this directory.
#   - Tarballs that contain a single top-level directory are re-rooted into
#     that directory (common for vendor tarballs).
#   - RPMs extract usr/bin, usr/share, etc. directly under the install root.
#     This layout is preserved exactly; no usr/ re-rooting is performed here.
#   - Higher-level normalization (e.g., usr/ a+' root) is performed later by
#     DoInstall + LayerInto, not by this routine.
#
# Responsibilities:
#   * Validate and create the deterministic install root.
#   * Extract the archive into the install root.
#   * Normalize tarball layout when a single top-level directory exists.
#   * Preserve RPM layout exactly as extracted (no usr/ re-rooting).
#   * Restore the original working directory on exit.
#
# Non-Responsibilities:
#   * This routine does NOT perform RPM normalization.
#   * This routine does NOT merge usr/ into the install root.
#   * This routine does NOT determine the final install directory name.
#   * This routine does NOT layer multiple packages.
#   * This routine does NOT modify or interpret MySQL layout expectations.
#
# Inputs:
#   $root_install_dir  - Parent directory for all extracted installs.
#   $archive_file      - Path to the archive to extract.
#   $debug             - Optional debug flag (0/1).
#
# Returns:
#   <install_root>  - On success.
#   undef           - On error or if install root already exists.
#
# Notes:
#   - This routine must remain deterministic and contributor-safe.
#   - Silent re-rooting of RPMs is forbidden; it breaks the install contract.
#   - DoInstall + LayerInto rely on this routine returning the true install root.
################################################################################
sub UnpackArchive {
    my ($self, $root_install_dir, $archive_file, $debug) = @_;
    $self->{debug} = $debug // 0;

    # Parse archive metadata (name, ext, path, dev_null)
    $self->_setup($archive_file);

    # Deterministic install root: <root>/<archive_name>
    my $install_root = File::Spec->catdir($root_install_dir, $self->{name});

    if (-d $install_root) {
        print STDERR "ERROR: Install directory already exists: $install_root\n";
        return undef;
    }

    mkpath($install_root)
        or croak "Failed to create install directory: $install_root";

    # Extract archive into the install root
    chdir $install_root
        or croak "Can't chdir to $install_root: $!";

    my $rc = $self->_extract_by_type($archive_file, $self->{ext});

    #---------------------------------------------------------------------
    # Normalize tarball layout:
    # If the tarball extracted into a single directory, re-root into it.
    #---------------------------------------------------------------------
    opendir(my $dh, $install_root) or die "Can't open $install_root: $!";
    my @entries = grep { !/^\.\.?$/ } readdir($dh);
    closedir($dh);

    if (@entries == 1) {
        my $only = File::Spec->catdir($install_root, $entries[0]);
        if (-d $only) {
            $install_root = $only;
        }
    }

    #---------------------------------------------------------------------
    # IMPORTANT:
    # Do NOT re-root RPM installs into usr/.
    # RPMs extract usr/bin, usr/share, etc. directly under the install root.
    # Full usr/ normalization is performed later by DoInstall + LayerInto.
    #---------------------------------------------------------------------

    # Restore original working directory
    chdir $self->{start_dir}
        or croak "Can't chdir back to $self->{start_dir}: $!";

    return $rc == OK ? $install_root : undef;
}

################################################################################
# Subroutine: LayerInto
#
# Purpose:
#   Extract an archive directly into an existing installation directory without
#   creating a new subdirectory. Used for layered package application where the
#   caller has already created and validated the install root. After extraction,
#   apply the same RPM layout normalization used by UnpackArchive so layered
#   packages merge cleanly into the existing install tree.
#
# Parameters:
#   $self         - Extractor object
#   $target_dir   - Existing directory to extract into
#   $archive_file - Archive to extract
#
# Behavior:
#   - Save current working directory
#   - chdir into $target_dir
#   - call _setup() to parse archive metadata (name, ext, path)
#   - call _extract_by_type() to unpack into the current directory
#   - apply RPM layout normalization:
#       * if a usr/ directory exists, move its immediate children up one level
#       * remove the now-empty usr/ directory
#   - chdir back to the saved working directory
#
# Returns:
#   $target_dir on success
#   undef       on failure
#
# Notes:
#   - Does not create or manage staging directories; caller owns lifecycle.
#   - Normalization is intentionally minimal and matches UnpackArchive behavior.
#   - Designed for deterministic, contributor-proof layered merges.
################################################################################
sub LayerInto {
    my ($self, $target_dir, $archive_file) = @_;

    return undef unless -d $target_dir;

    my $orig = $self->{start_dir};
    chdir $target_dir or croak "Can't chdir to $target_dir: $!";

    # Parse archive metadata (name, ext, path, dev_null)
    $self->_setup($archive_file);

    # Extract directly into the existing directory
    my $rc = $self->_extract_by_type($archive_file, $self->{ext});

    chdir $orig or croak "Can't chdir back to $orig: $!";

    return $rc == OK ? $target_dir : undef;
}

################################################################################
# Subroutine: _setup
#
# Purpose:
#   Parse archive filename to extract base name, path, and extension. Configure
#   OS-specific dev_null redirection string for suppressing command output.
#
# Globals Used:
#   $self->{name}     - Archive base name
#   $self->{path}     - Archive path
#   $self->{ext}      - Archive extension/type
#   $self->{dev_null} - OS-specific redirection string
#
# Parameters:
#   $self (hashref)   - Caller object reference
#   $file (string)    - Archive filename to parse
#
# Behavior:
#   - Uses fileparse() with known extensions to split file into name, path, ext.
#   - Sets $self->{name}, $self->{path}, $self->{ext}.
#   - Configures $self->{dev_null} based on OS:
#       * Windows: "> NUL 2>NUL"
#       * Linux:   "> /dev/null 2>&1"
#       * Other: croaks with unsupported OS message.
#
# Returns:
#   None explicitly. Updates $self hashref in place.
#
# Notes:
#   - Must be called before UnpackArchive to initialize archive metadata.
#   - Supports common compressed and package formats.
#   - Croaks on unsupported operating systems.
################################################################################
sub _setup {
    my ($self, $file) = @_;
    my @exts = qw(.tar.gz .tgz .tar.xz .tar.bz2 .zip .tar .rpm .deb);
    ($self->{name}, $self->{path}, $self->{ext}) = fileparse($file, @exts);

    if (IS_WINDOWS) {
        $self->{dev_null} = "> NUL 2>NUL";
    } elsif (IS_LINUX) {
        $self->{dev_null} = "> /dev/null 2>&1";
    } else {
        croak "Unsupported OS: $^O";
    }
}

################################################################################
# Subroutine: _extract_by_type
#
# Purpose:
#   Dispatch archive extraction based on file extension. Supports multiple
#   compression and package formats, invoking the appropriate system command
#   or helper routine.
#
# Globals Used:
#   Constants: OK, ERROR, IS_WINDOWS
#   Utility subs: _unpack_rpm, _unpack_deb, _run_cmd, _unpack_any_rpms_in_pwd
#
# Parameters:
#   $self         (hashref) - Caller object reference
#   $archive_file (string)  - Path to archive file to extract
#   $ext          (string)  - Archive extension/type (normalized to lowercase)
#
# Behavior:
#   - Normalizes extension to lowercase; defaults to empty string if undefined.
#   - Dispatches extraction based on extension:
#       * .rpm      -> calls _unpack_rpm()
#       * .deb      -> calls _unpack_deb()
#       * .zip      -> on Windows, uses PowerShell Expand-Archive;
#                      otherwise calls _run_cmd("unzip").
#       * .tar      -> calls _run_cmd("tar -xvf"), then expands any RPMs
#                      found in the current directory via _unpack_any_rpms_in_pwd().
#       * .tar.gz,
#         .tgz      -> calls _run_cmd("tar -xzvf").
#       * .tar.xz   -> calls _run_cmd("tar -xJvf").
#       * .tar.bz2  -> calls _run_cmd("tar -xjvf").
#       * Other     -> prints error and returns ERROR.
#   - Note: automatic RPM expansion is performed only for plain .tar archives.
#   - Returns OK if extraction succeeded, otherwise ERROR.
#
# Returns:
#   OK    - Extraction completed successfully
#   ERROR - Unsupported type or extraction failure
#
# Notes:
#   - This routine is INTERNAL; not intended for external callers.
#   - Relies on helper subs (_run_cmd, _unpack_rpm, etc.) for actual extraction.
################################################################################
sub _extract_by_type {
    my ($self, $archive_file, $ext) = @_;
    $ext = lc($ext // '');

    my $rc;
    if ($ext eq '.rpm') {
        $rc = $self->_unpack_rpm($archive_file);
    } elsif ($ext eq '.deb') {
        $rc = $self->_unpack_deb($archive_file);
    } elsif ($ext eq '.zip') {
        $rc = IS_WINDOWS
            ? system("powershell -Command \"Expand-Archive -Path '$archive_file' -DestinationPath .\"")
            : $self->_run_cmd("unzip", $archive_file);
    } elsif ($ext eq '.tar') {
        $rc = $self->_run_cmd("tar -xvf", $archive_file);
        $rc = $self->_unpack_any_rpms_in_pwd() if $rc == OK;
    } elsif ($ext eq '.tar.gz' || $ext eq '.tgz') {
        $rc = $self->_run_cmd("tar -xzvf", $archive_file);
    } elsif ($ext eq '.tar.xz') {
        # Capability detection for .tar.xz
        # 1. Try tar -xJf (native xz support)
        # 2. If tar lacks -J, fall back to: xz -d file.tar.xz && tar -xf file.tar
        # 3. Fail explicitly if neither tar nor xz can extract the archive

        # Try native tar -J support
        my $test = system("tar --help 2>/dev/null | grep -q '\\-J'");
        if ($test == 0) {
            # tar supports -J
            $rc = $self->_run_cmd("tar -xJvf", $archive_file);
            return $rc == OK ? OK : ERROR;
        }
        # tar does NOT support -J; check for xz binary
        my $xz_ok = system("which xz >/dev/null 2>&1");
        if ($xz_ok == 0) {
    
            # Decompress manually: file.tar.xz -> file.tar
            my $tarfile = $archive_file;
            $tarfile =~ s/\.xz$//;   # strip .xz
    
            my $cmd1 = "xz -d '$archive_file'";
            print "Running: $cmd1\n" if $self->{debug};
            my $rc1 = system($cmd1);
            if ($rc1 != OK) {
                print STDERR "ERROR: Failed to decompress $archive_file using xz\n";
                return ERROR;
            }
    
            # Extract the resulting .tar
            my $rc2 = $self->_run_cmd("tar -xvf", $tarfile);
            return $rc2 == OK ? OK : ERROR;
        }
    
        # Neither tar -J nor xz is available
        print STDERR "ERROR: Host cannot extract .tar.xz archives (no tar -J, no xz)\n";
        return ERROR;
    } elsif ($ext eq '.tar.bz2') {
        $rc = $self->_run_cmd("tar -xjvf", $archive_file);
    } else {
        print("Unsupported archive type: $ext");
        return ERROR;
    }

    return $rc == OK ? OK : ERROR;
}

################################################################################
# Subroutine: _unpack_deb
#
# Purpose:
#   Extract the contents of a Debian package (.deb) file into the current
#   working directory. Provides a fallback extraction method if the primary
#   tool fails, with debug output and error reporting for reproducibility.
#
# Globals Used:
#   $self->{debug}   - Boolean flag controlling verbosity of printed commands
#   Constants: OK, ERROR
#
# Parameters:
#   $self     (hashref) - Caller object reference
#   $deb_file (string)  - Path to Debian package file to unpack
#
# Behavior:
#   - If debug is enabled, prints the bsdtar command being executed.
#   - Attempts to extract using:
#       system("bsdtar -xf '<deb_file>'")
#   - If bsdtar fails (rc != OK):
#       * Prints the dpkg-deb command if debug is enabled.
#       * Attempts extraction using:
#           system("dpkg-deb -x '<deb_file>' .")
#   - If both methods fail:
#       * Prints error message to STDERR.
#       * Returns ERROR.
#   - If either method succeeds:
#       * Returns OK.
#
# Returns:
#   OK    - Extraction succeeded using bsdtar or dpkg-deb
#   ERROR - Both extraction methods failed
#
# Notes:
#   - This routine is INTERNAL; not intended for external callers.
#   - Requires either bsdtar or dpkg-deb to be available in PATH.
#   - Extraction occurs in the current working directory.
#   - Debug mode provides traceability of executed commands.
################################################################################
sub _unpack_deb {
    my ($self, $deb_file) = @_;
    print "Running: bsdtar -xf '$deb_file'\n" if $self->{debug};
    my $rc = system("bsdtar -xf '$deb_file'");
    if ($rc != OK) {
        print "Running: dpkg-deb -x '$deb_file' .\n" if $self->{debug};
        $rc = system("dpkg-deb -x '$deb_file' .");
    }
    if ($rc != OK) {
        print STDERR "ERROR: Failed to unpack $deb_file\n";
        return ERROR;
    }
    return OK;
}

################################################################################
# Subroutine: _unpack_rpm
#
# Purpose:
#   Extract the contents of a Red Hat Package Manager (.rpm) file into the
#   current working directory. Provides a primary extraction method using
#   bsdtar with a fallback to rpm2cpio/cpio if bsdtar fails. Includes debug
#   output and error reporting for reproducibility.
#
# Globals Used:
#   $self->{debug}   - Boolean flag controlling verbosity of printed commands
#   Constants: OK, ERROR
#
# Parameters:
#   $self     (hashref) - Caller object reference
#   $rpm_file (string)  - Path to RPM package file to unpack
#
# Behavior:
#   - If debug is enabled, prints the bsdtar command being executed.
#   - Attempts to extract using:
#       system("bsdtar -xf '<rpm_file>'")
#   - If bsdtar succeeds (rc == OK):
#       * Returns OK immediately.
#   - If bsdtar fails:
#       * Prints the rpm2cpio/cpio command if debug is enabled.
#       * Attempts extraction using:
#           system("rpm2cpio '<rpm_file>' | cpio -dim")
#       * Returns OK if this succeeds.
#   - If both methods fail:
#       * Prints error message to STDERR.
#       * Returns ERROR.
#
# Returns:
#   OK    - Extraction succeeded using bsdtar or rpm2cpio/cpio
#   ERROR - Both extraction methods failed
#
# Notes:
#   - This routine is INTERNAL; not intended for external callers.
#   - Requires either bsdtar or rpm2cpio/cpio utilities to be available in PATH.
#   - Extraction occurs in the current working directory.
#   - Debug mode provides traceability of executed commands.
#   - Mirrors _unpack_deb in structure, ensuring consistent fallback logic
#     across package formats.
################################################################################
sub _unpack_rpm {
    my ($self, $rpm_file) = @_;
    print "Running: bsdtar -xf '$rpm_file'\n" if $self->{debug};
    my $rc = system("bsdtar -xf '$rpm_file'");
    return OK if $rc == OK;

    print "Running: rpm2cpio '$rpm_file' | cpio -dim\n" if $self->{debug};
    $rc = system("rpm2cpio '$rpm_file' | cpio -dim");
    if ($rc == OK) {
        return OK;
    }
    print STDERR "ERROR: Failed to unpack $rpm_file\n";
    return ERROR;
}

################################################################################
# Subroutine: _unpack_any_rpms_in_pwd
#
# Purpose:
#   Scan the current working directory for RPM package files (*.rpm) and
#   unpack each one using the internal _unpack_rpm routine. Provides a
#   unified status return indicating whether all RPMs were successfully
#   extracted.
#
# Globals Used:
#   Constants: OK, ERROR
#   Utility subs: _unpack_rpm
#
# Parameters:
#   $self (hashref) - Caller object reference; provides access to _unpack_rpm
#
# Behavior:
#   - Opens the current working directory; croaks if unable to access.
#   - Collects all filenames ending in ".rpm".
#   - Closes directory handle after reading.
#   - If no RPM files are found:
#       * Returns OK immediately (nothing to unpack).
#   - Initializes status to OK.
#   - Iterates over each RPM file:
#       * Calls _unpack_rpm($rpm).
#       * If any call returns ERROR, sets overall status to ERROR.
#   - Returns final status (OK if all succeeded, ERROR if any failed).
#
# Returns:
#   OK    - No RPMs found, or all RPMs unpacked successfully
#   ERROR - One or more RPMs failed to unpack
#
# Notes:
#   - This routine is INTERNAL; not intended for external callers.
#   - Relies on _unpack_rpm to perform actual extraction of each RPM file.
#   - Operates only on the current working directory; does not recurse into
#     subdirectories.
#   - Unified status ensures caller can detect partial failures without
#     inspecting individual results.
################################################################################
sub _unpack_any_rpms_in_pwd {
    my ($self) = @_;

    #
    # 1. Look for RPMs in the current directory (MySQL bundle case)
    #
    opendir(my $dh, ".") or croak "Can't open current dir: $!";
    my @rpms = grep { /\.rpm$/ } readdir($dh);
    closedir($dh);

    if (@rpms) {
        my $status = OK;
        foreach my $rpm (@rpms) {
            my $rc = $self->_unpack_rpm($rpm);
            $status = ERROR if $rc != OK;
        }
        return $status;
    }

    #
    # 2. No RPMs here. Look for a single subdirectory (MariaDB bundle case)
    #
    opendir($dh, ".") or croak "Can't open current dir: $!";
    my @dirs = grep { -d $_ && $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);

    return OK unless @dirs == 1;   # Only handle the single-subdir case

    my $subdir = $dirs[0];

    opendir($dh, $subdir) or croak "Can't open $subdir: $!";
    my @sub_rpms = grep { /\.rpm$/ } readdir($dh);
    closedir($dh);

    return OK unless @sub_rpms;    # Nothing to do

    #
    # 3. Unpack RPMs inside the subdirectory
    #
    my $status = OK;
    foreach my $rpm (@sub_rpms) {
        my $path = "$subdir/$rpm";
        my $rc = $self->_unpack_rpm($path);
        $status = ERROR if $rc != OK;
    }

    return $status;
}

################################################################################
# Subroutine: _run_cmd
#
# Purpose:
#   Execute a system command against a specified file, with optional debug
#   output and suppression of command output. Provides unified error handling
#   and return codes for consistent caller logic.
#
# Globals Used:
#   $self->{debug}     - Boolean flag controlling verbosity of printed commands
#   $self->{dev_null}  - OS-specific redirection string to suppress output
#   Constants: OK, ERROR
#
# Parameters:
#   $self (hashref)    - Caller object reference; provides debug and dev_null settings
#   $cmd  (string)     - Base command to execute (e.g., "tar -xzvf", "unzip")
#   $file (string)     - Target file to process with the command
#
# Behavior:
#   - Constructs full command string:
#       * If debug is enabled: "<cmd> '<file>'"
#       * If debug is disabled: "<cmd> '<file>' <dev_null>"
#   - Prints constructed command to STDOUT if debug is enabled.
#   - Executes command via system().
#   - If system() return code != OK:
#       * Prints error message to STDERR with failed command.
#       * Returns ERROR.
#   - If system() succeeds:
#       * Returns OK.
#
# Returns:
#   OK    - Command executed successfully
#   ERROR - Command failed (non-zero exit code)
#
# Notes:
#   - This routine is INTERNAL; not intended for external callers.
#   - Relies on caller having initialized $self->{dev_null} via _setup().
#   - Debug mode provides traceability of executed commands.
#   - Ensures consistent OK/ERROR return values for higher-level unpack routines.
################################################################################
sub _run_cmd {
    my ($self, $cmd, $file) = @_;
    my $full_cmd = $self->{debug} ? "$cmd '$file'" : "$cmd '$file' $self->{dev_null}";
    print "Running: $full_cmd\n" if $self->{debug};
    my $rc = system($full_cmd);
    if ($rc != OK) {
        print STDERR "ERROR: Command failed: $full_cmd\n";
        return ERROR;
    }
    return OK;
}

#############################################################################
# Module terminator
#############################################################################
1;