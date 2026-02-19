package toolsLib;
#############################################################################
# toolsLib
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
#     Provide a unified, contributor-proof interface to the collection of
#     utility modules that make up the TAF tools library. This module acts as
#     the central aggregation point for file operations, system information,
#     archiving, extraction, secure copy, logging, validation, and supporting
#     helpers. It exposes a stable, onboarding-safe API for use by scripts,
#     test harnesses, and higher-level framework components.
#
# ARCHITECTURAL ROLE:
#     - Serves as the top-level facade for all toolsLib functionality.
#     - Re-exports selected routines from underlying modules to provide a
#       simplified, consistent interface.
#     - Ensures uniform error handling, debug behavior, and naming conventions.
#     - Provides stable abstractions over:
#           * File operations (copy, move, delete, list)
#           * Directory and path normalization
#           * Archive extraction and creation
#           * Secure copy (SCP) transfers
#           * System and host information
#           * Logging utilities
#           * Numeric and IP validation
#           * String trimming and normalization
#     - Normalizes cross-platform behavior across Windows, Linux, and Cygwin.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not implement the underlying logic of the tools; it delegates to
#       the individual modules responsible for each domain.
#     - Does not perform deep validation or schema enforcement.
#     - Does not guess caller intent or silently modify inputs.
#     - Does not die(); underlying modules return OK/ERROR or undef as needed.
#
# CONTRACT:
#     - Must load and expose the correct set of toolsLib modules.
#     - Must export only the stable, documented API intended for callers.
#     - Must not alter the semantics of underlying modules.
#     - Must maintain backward compatibility for exported routines.
#     - Must ensure that all exported functions behave consistently across
#       platforms and environments.
#
# GUARANTEES:
#     - Provides a single, predictable entry point for toolsLib functionality.
#     - Ensures contributor-proof behavior through explicit exports.
#     - Maintains stable naming and error-handling conventions.
#     - Debug output is controlled by underlying modules and remains consistent.
#
# NOTES:
#     - This module is intentionally thin; its purpose is aggregation and API
#       stability, not implementation.
#     - Any change to exported routines or module composition must be reflected
#       in this header and in the TAF manual.
#############################################################################
use strict;
use warnings;
use FindBin qw($Bin);
use lib 'lib', "$Bin";
use lib "$Bin/libs/script_tools_lib/";
use Exporter 'import';
use Data::Dumper;

# Tool modules
use DateTime;
use FileCount;
use IsNumeric;
use Logger;
use Paths;
use SystemInfo;
use Trim;
use Extractor;
use FileOps;
use CpuMonitor;

# Required modules (non-importing)
require Archiver;
require GetHostName;
require RemoveDir;
require SecureCopy;
require ClientCmakeBuild;

# Constants and globals
our $VERSION = '2.0';
our @EXPORT = (
    #--- Build / Client ---
    qw(
        BuildClient
    ),

    #--- FileOps (copy/move/delete/list) ---
    qw(
        CopyContents
        CopyRecursive
        CopyRecursiveFromCurrent
        DeleteFilesWExt
        MV
        MVSubs
        GetListOfFilesWithExt
    ),

    #--- FileCounter (count files/dirs) ---
    qw(
        FileCounter
        FileCounterWithExt
        DirCounter
    ),

    #--- Paths (directory validation/normalization) ---
    qw(
        EnsureDirectoryExists
        EnsureTrailingSlash
        RemoveTrailingSlash
        DoesDirectoryExist
    ),

    #--- Extractor (archive unpacking) ---
    qw(
        ExtractArchive
    ),

    #--- Host Info (system + hostname) ---
    qw(
        GetCurrentHostName
        GetHostNameByIP
        GetSystemCpu
        GetSystemMemory
        GetSystemLocale
        GetSystemEncoding
        GetSystemOSType
        GetSystemSocketCount
        GetSystemCoreCount
        GetSystemOSVersion
        GetSystemArch
        GetSystemKernel
        GetSystemTimezone
        GetSystemInfoHash
    ),

    #--- Logger ---
    qw(
        GetLogger
    ),

    #---- DB Process Watch for Rest ---
    qw(
        WatchDbProcessForRest
    ),

    #--- Validation (numeric/IP checks) ---
    qw(
        IsANumber
        IsThisAnIpAddress
    ),

    #--- Archiver (zip/no-compress) ---
    qw(
        Zipper
        ZipRelative
        NoCompressArchiveAbsolute
        NoCompressArchiveRelative
    ),

    #--- RemoveDir (cleanup/purge) ---
    qw(
        RemoveSubTree
        RemoveTree
        PurgeDirectory
    ),

    #--- SecureCopy (SCP transfers) ---
    qw(
        SCopyFrom
        SCopyTo
        SCopyToRecursive
    ),

    #--- Trim (string normalization) ---
    qw(
        Trim
        TrimLite
    ),
);

our $DEBUG = 0;
use constant {
    TRUE   => 1,
    FALSE  => 0,
    OK     => 0,
    ERROR  => 1,
    KILLED => 2,
    ZERO   => 0,
    UNDEF  => undef,
};

sub DebugPrint($){
    print "$_[0]\n" if $DEBUG;
}

################################################################################
# Section: Host Info
#
# Purpose:
#   Provide accessor methods for retrieving system information collected by
#   the SystemInfo object. Centralizes access to CPU model, logical CPU count,
#   physical core count, socket count, memory, locale, encoding, OS type and
#   version, architecture, kernel, timezone, and the full system-info hash.
#
# Globals Used:
#   $_sysinfo_obj - Cached singleton instance of SystemInfo
#
# Subroutine: _get_sysinfo_obj
#   - Lazily instantiates a SystemInfo object if not already created.
#   - Returns the cached SystemInfo instance.
#
# Accessor Subroutines:
#   GetSystemCpu         -> Returns CPU identifier/description
#   GetSystemCpuCount    -> Returns logical CPU count
#   GetSystemCoreCount   -> Returns physical core count
#   GetSystemSocketCount -> Returns physical CPU socket count
#   GetSystemMemory      -> Returns memory size/descriptor
#   GetSystemLocale      -> Returns locale string
#   GetSystemEncoding    -> Returns character encoding
#   GetSystemOSType      -> Returns operating system type
#   GetSystemOSVersion   -> Returns operating system version
#   GetSystemArch        -> Returns system architecture
#   GetSystemKernel      -> Returns kernel version string
#   GetSystemTimezone    -> Returns timezone identifier
#   GetSystemInfoHash    -> Returns full system-info hash from SystemInfo
#
# Behavior:
#   - All accessor routines delegate to the cached SystemInfo object.
#   - Ensures consistent retrieval of host information without re-instantiating
#     SystemInfo multiple times.
#   - Provides a stable, contributor-proof interface for all host-info queries.
#
# Returns:
#   Scalars for individual accessors, or a hashref for GetSystemInfoHash.
#
# Notes:
#   - Intended as public interface routines.
#   - Relies on the SystemInfo module to populate and maintain system data.
#   - Provides a unified, deterministic API for host information across all
#     supported platforms.
################################################################################
my $_sysinfo_obj;

sub _get_sysinfo_obj {
    $_sysinfo_obj ||= SystemInfo->new();
    return $_sysinfo_obj;
}

sub GetSystemCpu         { return _get_sysinfo_obj()->GetCpu(); }
sub GetSystemCpuCount    { return _get_sysinfo_obj()->GetCpuCount(); }
sub GetSystemMemory      { return _get_sysinfo_obj()->GetMemory(); }
sub GetSystemLocale      { return _get_sysinfo_obj()->GetLocale(); }
sub GetSystemEncoding    { return _get_sysinfo_obj()->GetEncoding(); }
sub GetSystemOSType      { return _get_sysinfo_obj()->GetOSType(); }
sub GetSystemOSVersion   { return _get_sysinfo_obj()->GetOSVersion(); }
sub GetSystemArch        { return _get_sysinfo_obj()->GetArch(); }
sub GetSystemKernel      { return _get_sysinfo_obj()->GetKernel(); }
sub GetSystemTimezone    { return _get_sysinfo_obj()->GetTimezone(); }
sub GetSystemSocketCount { return _get_sysinfo_obj()->GetSocketCount(); }
sub GetSystemCoreCount   { return _get_sysinfo_obj()->GetCoreCount(); }

sub GetSystemInfoHash {
    return _get_sysinfo_obj()->GetSystemInfo();
}

################################################################################
# Subroutine: BuildClient
#
# Purpose:
#   Provide a wrapper interface to ClientCmakeBuild->Build for constructing
#   client binaries using CMake. Simplifies invocation by exposing a single
#   entry point with explicit parameters and optional debug output.
#
# Globals Used:
#   None explicitly.
#
# Parameters:
#   install_dir (string) - Target installation directory for built artifacts
#   source_dir  (string) - Source directory containing CMake project files
#   cmake_args  (string) - Additional arguments/options passed to CMake
#   build_log   (string) - Path to log file capturing build output
#   debug       (bool)   - Optional flag enabling verbose debug output
#
# Behavior:
#   - Prints all parameter values if debug flag is set.
#   - Dynamically loads ClientCmakeBuild module.
#   - Instantiates a ClientCmakeBuild object.
#   - Calls its Build() method with provided arguments.
#
# Returns:
#   Result of ClientCmakeBuild->Build (implementation dependent; typically
#   success/failure code or object reference).
#
# Notes:
#   - Intended as a public interface routine.
#   - Provides contributor-friendly abstraction over ClientCmakeBuild internals.
#   - Debug mode aids troubleshooting by echoing parameter values.
################################################################################
sub BuildClient {
        my $install_dir = $_[0];
        my $source_dir  = $_[1];
        my $cmake_args = $_[2];
        my $build_log = $_[3];
        my $debug = $_[4];	


    if ($debug) {
        print "BuildClient called with:\n";
        print "  install_dir  = $install_dir\n";
        print "  source_dir   = $source_dir\n";
        print "  cmake_args   = $cmake_args\n";
        print "  build_log    = $build_log\n";
        print "  debug        = $debug\n";
    }

    require ClientCmakeBuild;
    my $builder = ClientCmakeBuild->new();

    return $builder->Build(
        install_dir => $install_dir,
        cmake_dir   => $source_dir,
        cmake_args  => $cmake_args,
        build_log   => $build_log,
        debug       => $debug
    );
}

################################################################################
# Test sub function (can ignore) 
################################################################################
sub here{
    print "here tools\n";
}

################################################################################
# Section: Interface for tools_lib::Archiver.pm
#
# Purpose:
#   Provide wrapper functions around the Archiver module for creating compressed
#   or uncompressed archives. Centralizes archive operations behind a stable,
#   contributor-proof API with optional debug output for traceability.
#
# Globals Used:
#   $DEBUG       - Global debug flag controlling verbosity
#   DirIsvalid() - Validates that a directory path exists and is a directory
#
# Public Subroutines:
#   Zipper
#       -> Calls Archiver->Archive()
#
#   ZipRelative
#       -> Calls Archiver->ArchiveRelative()
#
#   NoCompressArchiveRelative
#       -> Calls Archiver->ArchiveRelativeNoCompression()
#
#   NoCompressArchiveAbsolute
#       -> Calls Archiver->ArchiveNoCompression()
#
# Internal Subroutine:
#   _run_archiver($method, $targetDir, $myFile, $debugWanted)
#       - Prints method name and parameters when debug is enabled.
#       - Validates targetDir via DirIsvalid().
#       - Instantiates an Archiver object and invokes the requested method.
#       - Returns the result of the Archiver method call.
#       - Returns ERROR if targetDir is invalid.
#
# Parameters:
#   method      (string) - Archiver method name to invoke
#   targetDir   (string) - Directory to archive
#   myFile      (string) - Archive file name
#   debugWanted (bool)   - Optional flag enabling verbose debug output
#
# Returns:
#   Result of Archiver method call on success
#   ERROR (1) if directory validation fails
#
# Notes:
#   - Public wrappers hide Archiver internals and enforce consistent behavior.
#   - DirIsvalid() ensures only valid directories are passed to Archiver.
#   - Debug output is explicit and deterministic.
################################################################################
sub Zipper {
    return _run_archiver('Archive', @_);
}

#---------------------------------------------
sub ZipRelative {
    return _run_archiver('ArchiveRelative', @_);
}

#---------------------------------------------
sub NoCompressArchiveRelative {
    return _run_archiver('ArchiveRelativeNoCompression', @_);
}

#---------------------------------------------
sub NoCompressArchiveAbsolute {
    return _run_archiver('ArchiveNoCompression', @_);
}

#---------------------------------------------
sub _run_archiver {
    my ($method, $targetDir, $myFile, $debugWanted) = @_;

    if ($DEBUG || $debugWanted) {
        print "$method\n";
        print "target  = " . (defined $targetDir   ? $targetDir   : 'undef') . "\n";
        print "archive = " . (defined $myFile      ? $myFile      : 'undef') . "\n";
        print "debug   = " . (defined $debugWanted ? 'TRUE'       : 'undef') . "\n";
    }

    unless (DirIsvalid($targetDir)) {
        my $zipper = Archiver->new();
        return $zipper->$method($targetDir, $myFile, $debugWanted);
    }

    print "the dir $targetDir is a bad dir!!\n" if $DEBUG || $debugWanted;
    return ERROR;
}

################################################################################
# Subroutine: GetDateObject
#
# Purpose:
#   Provide a wrapper interface to the DateTime module, returning a new
#   DateTime object instance. Simplifies external calls by exposing a single
#   entry point for creating date/time objects.
#
# Globals Used:
#   None explicitly.
#
# Parameters:
#   None explicitly; operates without arguments.
#
# Behavior:
#   - Instantiates a new DateTime object via DateTime->new().
#   - Returns the object to the caller.
#
# Returns:
#   DateTime object - A fresh instance ready for use with date/time methods.
#
# Notes:
#   - Intended as a public accessor routine.
#   - Provides contributor-friendly abstraction over direct DateTime->new()
#     calls, ensuring consistency across the framework.
################################################################################
sub GetDateObject {
    return DateTime->new();
}

################################################################################
# Subroutine: DirIsvalid
#
# Purpose:
#   Validate that a given directory path is defined, exists, and is a directory.
#   Provides defensive checks to prevent invalid paths from being passed into
#   file or archive operations.
#
# Globals Used:
#   Utility sub: DebugPrint (prints diagnostic messages if $DEBUG enabled)
#
# Parameters:
#   dir (string) - Path to directory to validate
#
# Behavior:
#   - Prints debug message showing directory being checked.
#   - If dir is undefined:
#       * Prints error message.
#       * Returns FALSE  (indicating "bad" directory).
#   - If dir does not exist:
#       * Prints error message.
#       * Returns FALSE .
#   - If dir exists but is not a directory:
#       * Prints error message.
#       * Returns FALSE .
#   - If all checks pass:
#       * Returns TRUE (indicating directory is valid).
#
# Returns:
#   0 - Directory is valid
#   1 - Directory is invalid (undefined, non-existent, or not a directory)
#
# Notes:
#   - INTERNAL helper; not intended for external callers.
#   - Used by archive, copy, and remove routines to ensure safe directory
#     operations.
#   - Error messages are printed directly to STDOUT for visibility.
################################################################################
sub DirIsvalid {
    my ($dir) = @_;

    DebugPrint("DirIsvalid: Checking directory = $dir");

    unless (defined $dir) {
        print "DirIsvalid Error: No directory provided. Please check your parameters.\n";
        return FALSE;
    }

    unless (-e $dir) {
        print "DirIsvalid Error: '$dir' does not exist. Please check your parameters.\n";
        return FALSE;
    }

    unless (-d $dir) {
        print "DirIsvalid Error: '$dir' is not a directory. Please check your parameters.\n";
        return FALSE;
    }

    return TRUE;
}

################################################################################
# Section: Interface for tools_lib::FileCounter
#
# Purpose:
#   Provide wrapper functions around the FileCount module for counting files
#   and directories. Simplifies external calls by exposing a contributor-friendly
#   API for file system statistics.
#
# Globals Used:
#   None explicitly.
#
# Public Subroutines:
#   FileCounter($target)
#     - Instantiates FileCount object.
#     - Returns number of files in target directory.
#
#   FileCounterWithExt($target, $ext)
#     - Instantiates FileCount object.
#     - Returns number of files in target directory matching given extension.
#
#   DirCounter($target)
#     - Instantiates FileCount object.
#     - Returns number of subdirectories in target directory.
#
# Parameters:
#   target (string) - Path to directory to inspect
#   ext    (string) - File extension filter (FileCounterWithExt only)
#
# Returns:
#   Integer - Count of files or directories, depending on routine.
#
# Notes:
#   - Intended as public interface routines.
#   - Relies on FileCount module for actual counting logic.
#   - Provides contributor-friendly wrappers for common file system queries.
################################################################################
sub FileCounter{
    my ($target)= @_;
    my $counter = FileCount->new();
    return($counter->CountFiles($target));
}

sub FileCounterWithExt{
    my ($target,$ext)= @_;
    my $counter = FileCount->new();
    return($counter->CountFilesWExtensions($target,$ext));
}

#---------------------------------------------
sub DirCounter{
    my ($target)= @_;
    my $counter = FileCount->new();
    return($counter->CountDirs($target));
}

################################################################################
# Subroutine: ExtractArchive
#
# Purpose:
#   Provide a stable wrapper around the Extractor module for unpacking archives
#   into a target directory. Exposes a single, contributor-proof entry point
#   with optional debug output for traceability.
#
# Globals Used:
#   DirIsvalid() - Validates that the target directory exists and is a directory
#   DebugPrint() - Emits diagnostic messages when $DEBUG is enabled
#
# Parameters:
#   target_dir   (string) - Destination directory where archive contents
#                           will be unpacked
#   archive_file (string) - Path to the archive file to extract
#   debug        (bool)   - Optional flag enabling verbose debug output
#   mode         (string) - Extraction mode: 'base' (default) or 'layer'
#
# Behavior:
#   - Validates target_dir using DirIsvalid(); returns undef if invalid.
#   - Instantiates an Extractor object and applies the debug flag.
#   - For mode 'base', calls Extractor->UnpackArchive().
#   - For mode 'layer', calls Extractor->LayerInto().
#   - Emits a debug message and returns undef for unknown modes.
#
# Returns:
#   - Directory path or status code returned by Extractor methods on success
#   - undef on invalid directory or unknown mode
#
# Notes:
#   - Intended as a public interface routine.
#   - Provides a deterministic, onboarding-safe abstraction over Extractor
#     internals.
#   - Debug output is explicit and controlled by caller-provided flags.
################################################################################
sub ExtractArchive {
    my ($target_dir, $archive_file, $debug, $mode) = @_;
    $mode ||= 'base';

   return undef unless DirIsvalid($target_dir);

    my $extractor = Extractor->new();
    $extractor->{debug} = $debug // 0;

    if ($mode eq 'base') {
        return $extractor->UnpackArchive($target_dir, $archive_file, $debug);
    }
    elsif ($mode eq 'layer') {
        return $extractor->LayerInto($target_dir, $archive_file);
    }
    else {
        DebugPrint("ExtractArchive: unknown mode: $mode");
        return undef;
    }
}

################################################################################
# Section: Interface for tools_lib::FileOps
#
# Purpose:
#   Provide wrapper functions around the FileOps module for cross-platform
#   file and directory operations. Simplifies external calls by exposing a
#   contributor-friendly API with optional debug output for traceability.
#
# Globals Used:
#   $DEBUG - Global debug flag controlling verbosity
#   Utility sub: DebugPrint (prints diagnostic messages when $DEBUG enabled)
#
# Public Subroutines:
#   MV($base, $target, $debug)
#     - Moves a directory from base to target.
#     - Delegates to FileOps->Move().
#
#   MVSubs($base, $target, $debug)
#     - Moves all entries (files/subdirectories) from base into target.
#     - Delegates to FileOps->MoveSubs().
#
#   CopyContents($base, $target, $debug)
#     - Copies all contents of base into target.
#     - Delegates to FileOps->CopyContentsRecursive().
#
#   CopyRecursive($base, $target, $debug)
#     - Recursively copies base directory into target.
#     - Delegates to FileOps->CopyR().
#
#   CopyRecursiveFromCurrent($target, $debug)
#     - Recursively copies current working directory into target.
#     - Delegates to FileOps->CopyRfromCurrent().
#
#   DeleteFilesWExt($dir, $ext, $debug)
#     - Deletes files in dir matching extension ext.
#     - Delegates to FileOps->DeleteFilesWExtension().
#
#   GetListOfFilesWithExt($dir, $ext, $debug)
#     - Lists files in dir matching extension ext.
#     - Delegates to FileOps->ListFilesWithExtension().
#
# Parameters:
#   base/dir (string)   - Source directory path
#   target   (string)   - Destination directory path
#   ext      (string)   - File extension filter (for delete/list routines)
#   debug    (bool/int) - Optional flag enabling verbose debug output
#
# Returns:
#   Result codes or lists depending on delegated FileOps routine.
#
# Notes:
#   - Intended as public interface routines.
#   - Provides cross-platform handling via FileOps internals.
#   - Debug mode aids troubleshooting by echoing parameters and operations.
################################################################################
sub MV {
    my ($base, $target, $debug) = @_;

    DebugPrint("toolsLib::MV: base = $base, target = $target");

    return FileOps::Move($base, $target, $debug);
}

sub MVSubs {
    my ($base, $target, $debug) = @_;

    DebugPrint("toolsLib::MVSubs: base = $base, target = $target");
    return FileOps::MoveSubs($base, $target, $debug);
}

sub CopyContents {
    my ($base, $target, $debug) = @_;

    DebugPrint("toolsLib::CopyContentsRecursive: base = $base, target = $target");
    return FileOps::CopyContentsRecursive($base, $target, $debug);
}

sub CopyRecursive {
    my ($base, $target, $debug) = @_;

    DebugPrint("toolsLib::CopyRecursive: base = $base, target = $target");
    return FileOps::CopyR($base, $target, $debug);
}

sub CopyRecursiveFromCurrent {
    my ($target, $debug) = @_;

    DebugPrint("toolsLib::CopyRecursiveFromCurrent: target = $target");
    return FileOps::CopyRfromCurrent($target, $debug);
}

sub DeleteFilesWExt {
    my ($dir, $ext, $debug) = @_;

    DebugPrint("toolsLib::DeleteFilesWExt: dir = $dir, ext = $ext");
    return FileOps::DeleteFilesWExtension($dir, $ext, $debug);
}

sub GetListOfFilesWithExt {
    my ($dir, $ext, $debug) = @_;

    DebugPrint("toolsLib::GetListOfFilesWithExt: dir = $dir, ext = $ext");
    return FileOps::ListFilesWithExtension($dir, $ext, $debug);
}

################################################################################
# Section: Interface for tools_lib::GetHostName
#
# Purpose:
#   Provide wrapper functions around the GetHostName module for resolving
#   hostnames. Simplifies external calls by exposing a contributor-friendly API
#   for retrieving the current host name or resolving a host name from an IP.
#
# Globals Used:
#   None explicitly.
#
# Public Subroutines:
#   GetCurrentHostName()
#     - Instantiates GetHostName object.
#     - Returns the system's current host name via GetName().
#
#   GetHostNameByIP($ip)
#     - Instantiates GetHostName object.
#     - Resolves and returns host name associated with provided IP address
#       via GetByIP().
#
# Parameters:
#   ip (string) - IP address to resolve (GetHostNameByIP only)
#
# Returns:
#   String - Host name of current system or resolved host name for given IP.
#
# Notes:
#   - Intended as public interface routines.
#   - Provides contributor-friendly abstraction over GetHostName internals.
#   - Useful for logging, auditing, or network operations requiring host
#     identification.
################################################################################
sub GetCurrentHostName {
    my $hostname = GetHostName->new;
    return $hostname->GetName;
}

sub GetHostNameByIP {
    my ($ip) = @_;
    my $hostname = GetHostName->new;
    return $hostname->GetByIP($ip);
}

################################################################################
# Section: Interface for tools_lib::IsNumeric
#
# Purpose:
#   Provide wrapper functions around the IsNumeric module for validating
#   numeric values and IP addresses. Simplifies external calls by exposing
#   a contributor-friendly API for common validation checks.
#
# Globals Used:
#   None explicitly.
#
# Public Subroutines:
#   IsANumber($value)
#     - Delegates to IsNumeric->IsThisANumber().
#     - Returns true/false depending on whether $value is numeric.
#
#   IsThisAnIpAddress($value)
#     - Delegates to IsNumeric->IsThisAnIP().
#     - Returns true/false depending on whether $value is a valid IP address.
#
# Parameters:
#   value (string) - Input string to validate
#
# Returns:
#   Boolean/Scalar - Result of validation (implementation dependent; typically
#   1 for valid, 0 for invalid).
#
# Notes:
#   - Intended as public interface routines.
#   - Provides contributor-friendly abstraction over IsNumeric internals.
#   - Useful for input validation in scripts requiring numeric or IP checks.
################################################################################
sub IsANumber {
    my ($value) = @_;
    return IsNumeric->IsThisANumber($value);
}

sub IsThisAnIpAddress {
    my ($value) = @_;
    return IsNumeric->IsThisAnIP($value);
}

################################################################################
# Subroutine: GetLogger
#
# Purpose:
#   Provide a wrapper interface to the Logger module, returning a new Logger
#   object bound to a specified log file. Simplifies external calls by exposing
#   a single entry point for logging functionality.
#
# Globals Used:
#   None explicitly.
#
# Parameters:
#   logfile (string) - Path to the log file where messages will be written
#
# Behavior:
#   - Instantiates a new Logger object via Logger->new().
#   - Passes the provided logfile path as the 'file' parameter.
#   - Returns the Logger object to the caller.
#
# Returns:
#   Logger object - Instance configured to write to the specified logfile.
#
# Notes:
#   - Intended as a public interface routine.
#   - Provides contributor-friendly abstraction over Logger internals.
#   - Useful for consistent logging across framework modules.
################################################################################
sub GetLogger($) {
    my ($logfile) = @_;
    return Logger->new( file => $logfile );
}

################################################################################
# Section: Interface for tools_lib::Paths
#
# Purpose:
#   Provide wrapper functions around the Paths module for common directory
#   and path validation tasks. Simplifies external calls by exposing a
#   contributor-friendly API for ensuring or removing trailing slashes and
#   verifying directory existence.
#
# Globals Used:
#   None explicitly.
#
# Public Subroutines:
#   EnsureTrailingSlash($path)
#     - Delegates to Paths::EnsureSlashTrailing().
#     - Ensures the given path ends with a directory separator.
#
#   RemoveTrailingSlash($path)
#     - Delegates to Paths::RemoveSlashTrailing().
#     - Removes any trailing directory separator from the given path.
#
#   EnsureDirectoryExists($path)
#     - Delegates to Paths::EnsureDirectory().
#     - Creates the directory if it does not already exist.
#
#   DoesDirectoryExist($path)
#     - Delegates to Paths::DirExists().
#     - Returns true/false depending on whether the directory exists.
#
# Parameters:
#   path (string) - Directory path to validate or adjust
#
# Returns:
#   String or Boolean depending on routine:
#     - Modified path string (EnsureTrailingSlash, RemoveTrailingSlash)
#     - Boolean success/failure (EnsureDirectoryExists, DoesDirectoryExist)
#
# Notes:
#   - Intended as public interface routines.
#   - Provides contributor-friendly abstraction over Paths internals.
#   - Useful for normalizing directory paths and ensuring safe file operations.
################################################################################
sub EnsureTrailingSlash{
    return(Paths::EnsureSlashTrailing($_[0]));
}

#---------------------------------------------
sub RemoveTrailingSlash{
    return(Paths::RemoveSlashTrailing($_[0]));
}

#---------------------------------------------
sub EnsureDirectoryExists{
    return(Paths::EnsureDirectory($_[0]));
}

#---------------------------------------------
sub DoesDirectoryExist{
    return(Paths::DirExists($_[0]));
}

################################################################################
# Section: Interface for tools_lib::RemoveDir
#
# Purpose:
#   Provide wrapper functions around the RemoveDir module for directory
#   management tasks. Exposes a contributor-proof API for removing subdirectories,
#   deleting entire directory trees, or purging old files and subdirectories.
#
# Globals Used:
#   $DEBUG       - Global debug flag controlling verbosity
#   DirIsvalid() - Validates that a directory path exists and is a directory
#
# Public Subroutines:
#   RemoveSubTree($targetDir, $maxLoops)
#       - Removes only subdirectories within targetDir.
#       - Delegates to RemoveDir->RemoveSub().
#
#   RemoveTree($targetDir, $maxLoops, $debugWanted)
#       - Removes targetDir and all its contents.
#       - Delegates to RemoveDir->RemoveDirectory().
#
#   PurgeDirectory($purgeDir, $daysToKeep, $debugWanted)
#       - Removes files and subdirectories in purgeDir older than daysToKeep.
#       - Delegates to RemoveDir->PurgeDir().
#
# Parameters:
#   targetDir/purgeDir (string) - Directory path to operate on
#   maxLoops           (int)    - Safety limit for recursive removal loops
#   daysToKeep         (int)    - Age threshold in days for purge operations
#   debug/debugWanted  (bool)   - Optional flag enabling verbose debug output
#
# Returns:
#   OK     (0) on success
#   ERROR  (1) if directory invalid or operation fails
#
# Notes:
#   - DirIsvalid() enforces defensive directory validation.
#   - All routines avoid silent failure and provide explicit debug output.
################################################################################
# ------------------------------
sub RemoveSubTree {
    my ($targetDir, $maxLoops) = @_;

    if ($DEBUG) {
        print "RemoveSubTree\n";
        print "targetDir = " . (defined $targetDir ? $targetDir : 'undef') . "\n";
        print "maxLoops  = " . (defined $maxLoops  ? $maxLoops  : 'undef') . "\n";
    }

    unless (DirIsvalid($targetDir)) {
        print "RemoveSubTree: invalid directory '$targetDir'\n" if $DEBUG;
        return ERROR;
    }

    my $remover = RemoveDir->new();
    return $remover->RemoveSub($targetDir, $maxLoops);
}

# ------------------------------
sub RemoveTree {
    my ($targetDir, $maxLoops, $debugWanted) = @_;

    $maxLoops = 10 unless defined $maxLoops;

    if ($debugWanted) {
        print "RemoveTree\n";
        print "targetDir = " . (defined $targetDir ? $targetDir : 'undef') . "\n";
        print "maxLoops  = $maxLoops\n";
    }

    unless (DirIsvalid($targetDir)) {
        print "RemoveTree: invalid directory '$targetDir'\n" if $debugWanted;
        return ERROR;
    }

    my $remover = RemoveDir->new();
    return $remover->RemoveDirectory($targetDir, $maxLoops, $debugWanted);
}

# Removes files and subdirectories in purgeDir older than daysToKeep
sub PurgeDirectory {
    my ($purgeDir, $daysToKeep, $debugWanted) = @_;

    if ($debugWanted) {
        print "PurgeDirectory\n";
        print "Target Directory = $purgeDir\n";
        print "Days to keep     = $daysToKeep\n";
    }

    unless (DirIsvalid($purgeDir)) {
        print "PurgeDirectory: invalid directory '$purgeDir'\n" if $debugWanted;
        return ERROR;
    }

    my $purger = RemoveDir->new();
    return $purger->PurgeDir($purgeDir, $daysToKeep, $debugWanted);
}

################################################################################
# Section: Interface for tools_lib::SecureCopy
#
# Purpose:
#   Provide wrapper functions around the SecureCopy module for performing
#   secure file transfer operations (SCP). Simplifies external calls by
#   exposing a contributor-friendly API for copying files or directories
#   to and from remote hosts with optional debug output.
#
# Globals Used:
#   Constants: ERROR (returned on validation failure)
#
# Public Subroutines:
#   SCopyTo($targetFile, $user, $targetHost, $targetPath, $pass, $debug)
#     - Validates that targetFile exists.
#     - Instantiates SecureCopy object.
#     - Delegates to SecureCopy->SCPTO() to copy file to remote host.
#     - Returns ERROR if file does not exist.
#
#   SCopyToRecursive($baseDir, $user, $targetHost, $targetPath, $pass, $debug)
#     - Validates that baseDir exists and is a directory.
#     - Instantiates SecureCopy object.
#     - Delegates to SecureCopy->ScpToRecursive() to copy directory tree.
#     - Returns ERROR if directory invalid.
#
#   SCopyFrom($targetFile, $user, $targetHost, $targetPath, $pass, $localPath, $debug)
#     - Validates that localPath is defined.
#     - Instantiates SecureCopy object.
#     - Delegates to SecureCopy->SCPFROM() to copy file from remote host.
#     - Returns ERROR if localPath missing.
#
# Parameters:
#   targetFile (string) - File path to copy (SCopyTo, SCopyFrom)
#   baseDir    (string) - Directory path to copy recursively (SCopyToRecursive)
#   user       (string) - Remote user name
#   targetHost (string) - Remote host name or IP
#   targetPath (string) - Remote destination path
#   pass       (string) - Password or credential for authentication
#   localPath  (string) - Local destination path (SCopyFrom only)
#   debug      (bool)   - Optional flag enabling verbose debug output
#
# Returns:
#   Result of SecureCopy method call (implementation dependent).
#   ERROR constant if validation fails.
#
# Notes:
#   - Intended as public interface routines.
#   - Provides contributor-friendly abstraction over SecureCopy internals.
#   - Validation ensures safe file/directory operations before invoking SCP.
#   - Debug mode aids troubleshooting by echoing parameters and operations.
################################################################################
sub SCopyTo {
    my ($targetFile, $user, $targetHost, $targetPath, $pass, $debug) = @_;

    unless (-e $targetFile) {
        print "SCopyTo Error: File '$targetFile' does not exist\n";
        return ERROR;
    }

    my $scp = SecureCopy->new;
    return $scp->SCPTO($targetFile, $user, $targetHost, $targetPath, $pass, $debug);
}

sub SCopyToRecursive {
    my ($baseDir, $user, $targetHost, $targetPath, $pass, $debug) = @_;

    unless (-e $baseDir && -d $baseDir) {
        print "SCopyToRecursive Error: Directory '$baseDir' does not exist or is not a directory\n";
        return ERROR;
    }

    my $scp = SecureCopy->new;
    return $scp->ScpToRecursive($baseDir, $user, $targetHost, $targetPath, $pass, $debug);
}

sub SCopyFrom {
    my ($targetFile, $user, $targetHost, $targetPath, $pass, $localPath, $debug) = @_;

    unless (defined $localPath) {
        print "SCopyFrom Error: Missing local path\n";
        return ERROR;
    }

    my $scp = SecureCopy->new;
    return $scp->SCPFROM($targetFile, $user, $targetHost, $targetPath, $pass, $localPath, $debug);
}

###############################################################################
# WatchDbCpuUsage
# WatchDbProcessForRest
#
# PURPOSE:
#     Front-end TAF interface for CPU-based rest detection. This routine
#     constructs a CpuMonitor object using explicit caller-provided parameters
#     and drives the wait_for_rest() state machine. It provides a clean,
#     contributor-safe bridge between TAF and the backend CPU monitor.
#
# BEHAVIOR:
#     - Validates required inputs (PID).
#     - Constructs a CpuMonitor object with all thresholds and tunables.
#     - Invokes wait_for_rest() and returns its status code directly.
#
# CONTRACT:
#     - All parameters must be passed explicitly by the caller.
#     - PID must be a valid integer.
#     - No global state, no property lookups, no hidden defaults.
#
# RETURNS:
#     Whatever CpuMonitor->wait_for_rest() returns:
#         REST
#         NOT_REST
#         NO_SUCH_PROC
#         ERROR_UNKNOWN
###############################################################################
sub WatchDbCpuUsage {
    my (%args) = @_;

    my $pid = $args{pid};
    return ERROR unless defined $pid && $pid =~ /^\d+$/;

    my $monitor = CpuMonitor->new(
        pid                => $pid,
        rest_low           => $args{low},
        rest_high          => $args{high},
        consecutive_needed => $args{consecutive},
        max_attempts       => $args{max_attempts},
        interval           => $args{interval},
        verbose            => $args{verbose},
    );

    my $rc = $monitor->wait_for_rest();

    return OK    if $rc == CpuMonitor::REST;
    return ERROR;   # NOT_REST, NO_SUCH_PROC, ERROR_UNKNOWN all treated as ERROR
}

################################################################################
# Section: Interface for tools_lib::Trim
#
# Purpose:
#   Provide wrapper functions around the Trim module for string normalization.
#   Simplifies external calls by exposing a contributor-friendly API for
#   removing whitespace from strings.
#
# Globals Used:
#   None explicitly.
#
# Public Subroutines:
#   Trim($string)
#     - Delegates to Trim->trim().
#     - Removes leading and trailing whitespace from the input string.
#     - Preserves internal spacing.
#
#   TrimLite($string)
#     - Delegates to Trim->trimLite().
#     - Provides a lighter variant of trimming, typically removing only
#       leading/trailing whitespace while preserving internal spacing.
#
# Parameters:
#   string (string) - Input string to normalize
#
# Returns:
#   String - Input value with whitespace normalized according to routine
#
# Notes:
#   - Intended as public interface routines.
#   - Provides contributor-friendly abstraction over Trim internals.
#   - Useful for sanitizing user input, configuration values, or file paths.
################################################################################
sub Trim {
    my ($string) = @_;
    return Trim->trim($string);
}

sub TrimLite {
    my ($string) = @_;
    return Trim->trimLite($string);
}

#############################################################################
# Module terminator
#############################################################################
1;