package TAF::Client;
#############################################################################
# TAF::Client
#
# Created: December 2025
# Last Modified: January 2026
#
# This file is part of the Test Automation Framework (TAF).
# Copyright (c) 2025-2026 MariaDB Foundation
#
# Licensed under the GNU General Public License, version 2 or later (GPLv2+).
# See https://www.gnu.org/licenses/ for details.
#
# PURPOSE:
#     Provide contributor-proof routines for preparing the client-side
#     environment required by test suites. This module validates client
#     source directories, configures build paths, and optionally compiles
#     client binaries used during test execution.
#
# ARCHITECTURAL ROLE:
#     - Acts as the single interface for client build preparation.
#     - Validates client source and installation directories.
#     - Configures the CMake environment via SetCMakePath().
#     - Invokes the test suitea  (TM)s BuildClient() implementation.
#     - Logs all actions and timing information through TAF::Logging.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not manage LD_LIBRARY_PATH or runtime environment variables
#       (handled by DatabaseSoftwareInstalls).
#     - Does not interpret test suite behavior or execution semantics.
#     - Does not manage database installation directories beyond validation.
#     - Does not guess missing paths or silently skip build failures.
#
# CONTRACT:
#     - Caller must provide:
#           * client source directory
#           * database software installation directory
#           * optional CMake path override
#           * skip_client_builds flag
#           * directory for build logs
#           * ctx->{obj}{date} object for timing
#     - Test suites must implement main::BuildClient($installDir, $logFile).
#     - All directory validation must succeed before builds are attempted.
#     - All failures must be explicit; no silent fallbacks are permitted.
#
# GUARANTEES:
#     - All client setup stages are logged with timestamps.
#     - Build logs are written deterministically using timestamped filenames.
#     - Skipped builds are explicitly logged.
#     - Build failures return ERROR immediately.
#
# NOTES:
#     - This module is intentionally narrow in scope to ensure reliability.
#     - Client builds are optional and controlled by skip_client_builds.
#     - Any expansion of client preparation responsibilities must be reflected
#       in this header and documented in the TAF manual.
#############################################################################

#-------------------------------------------------------------------------------
#                                Imports
#-------------------------------------------------------------------------------
use Exporter 'import';
use File::Spec;
use File::Basename;
use strict;
use warnings;

BEGIN {
    my $here      = File::Basename::dirname(__FILE__);
    my $taf_libs  = File::Spec->catdir($here, File::Spec->updir);
    my $libs_root = File::Spec->catdir($taf_libs, File::Spec->updir);
    my $tools_dir = File::Spec->catdir($libs_root, "script_tools_lib");

    # Keep ability to find TAF::Logging (and other TAF::*)
    unshift @INC, $taf_libs  unless grep { $_ eq $taf_libs }  @INC;

    # Add ability to find toolsLib.pm
    unshift @INC, $tools_dir unless grep { $_ eq $tools_dir } @INC;
}

use TAF::Logging qw(PrintError
                    PrintVerbose
                    PrintWarning
                    PrintPrompt
                    PrintHeader
                    StageStart
                    StageEnd
                    TAFMsg);

use TAF::Utilities;
require toolsLib;

our $VERSION = '2.0';

#===============================================================================
#                                Exports
#===============================================================================
our @EXPORT_OK = qw(
    ClientSetup
);

#===============================================================================
#                                Constants
#===============================================================================
use constant {
    TRUE   => 1,
    FALSE  => 0,
    OK     => 0,
    ERROR  => 1,
    KILLED => 2,
    ZERO   => 0,
    UNDEF  => undef,
};

#===============================================================================
#                              Client Functions
#===============================================================================
#
# All client related routines for TAF are defined below.
# Each subroutine follows contributor proof headers with
# explicit Purpose, Behavior, Parameters, and Returns.
#
#===============================================================================

#===============================================================================
#                            Exported Subs
#===============================================================================

#===============================================================================
# ClientSetup
#
# PURPOSE:
#     Prepare the client-side environment for a test suite run by validating
#     required directories, configuring build paths, and optionally compiling
#     client source code. This routine does not manage LD_LIBRARY_PATH; all
#     runtime environment setup is handled by DatabaseSoftwareInstalls.
#
# PARAMETERS:
#     $source       - Path to the client source directory.
#     $install_dir  - Path to the database software installation directory.
#     $cmake_path   - Path to the CMake executable (or override).
#     $skip         - Boolean flag; TRUE skips client builds.
#     $logDir       - Directory where client build logs should be written.
#     $obj          - Framework object registry (must contain a date object).
#
# BEHAVIOR:
#     - Print stage header and initialize timing for the setup stage.
#     - If skip_client_builds is TRUE:
#           * Log that client builds are being skipped.
#     - If skip_client_builds is FALSE:
#           * Validate that the client source directory exists.
#           * Validate that db_software_install_dir is defined and is a directory.
#           * Call SetCMakePath() to configure the CMake environment.
#           * Invoke ClientBuild() to compile client source code.
#           * On build failure, log elapsed time and return ERROR.
#     - Log total elapsed time for the setup stage.
#
# RETURNS:
#     OK    - Client setup completed successfully.
#     ERROR - Directory validation, path setup, or client build failed.
#
# SIDE EFFECTS:
#     - May write build logs into the specified log directory.
#
# NOTES:
#     Caller must ensure that the framework object registry contains a valid
#     date object for timing operations.
#===============================================================================
sub ClientSetup {
    my ($source, $install_dir, $cmake_path, $skip, $logDir, $obj) = @_;

    PrintHeader("== STAGE: CLIENT SETUP ==========================", "=", 71);
    my $cs = TAFMsg("ClientSetup");
    $obj->{date}->SetStartTime();
    my $startTime = $obj->{date}->GetStartTime();
    my $dateTime  = $obj->{date}->GetFileDateStamp();

    if ($skip) {
        PrintWarning($cs."'skip_client_builds' option = TRUE");
        PrintVerbose($cs."Skipping client builds");
    } else {
        PrintVerbose($cs."Starting client builds...");

        unless (toolsLib::DoesDirectoryExist($source)) {
            TAF::Utilities::UsageError($cs."Directory check failed: ".$source);
        }

        unless (defined $install_dir && -d $install_dir) {
            PrintError("Option 'taf.db_software_install_dir' missing or invalid");
            return ERROR;
        }

        my $res = SetCMakePath($cmake_path);
        return ERROR if $res != OK;

        if (ClientBuild($install_dir, $logDir, $dateTime) != OK) {
            my $elapsed = $obj->{date}->FigureElapsedTimeFormatted($startTime);
            PrintError($cs."ClientBuild Failed!");
            PrintVerbose($cs."Elapsed time: $elapsed");
            return ERROR;
        }
    }

    my $setupElapsed = $obj->{date}->FigureElapsedTimeFormatted($startTime);
    PrintVerbose($cs."Completed in: $setupElapsed");
    return OK;
}

#===============================================================================
#                          Internal Subs
#===============================================================================

#===============================================================================
# ClientBuild
#
# PURPOSE:
#     Compile the test suite's client-side source code and write build output
#     to a timestamped log file. This routine constructs the build log path,
#     invokes the client build dispatcher, and reports success or failure.
#
# PARAMETERS:
#     $install    - Path to the database software installation directory.
#     $logDir     - Directory where the client build log file will be written.
#     $dateTime   - Timestamp string used to uniquely name the build log file.
#
# BEHAVIOR:
#     - Print the stage header for the client build phase.
#     - Construct a build log file path using the provided log directory and
#       timestamp.
#     - Invoke main::BuildClient() with:
#           * $install    (database software installation directory)
#           * $buildLog   (full path to the build log file)
#     - Return ERROR immediately if BuildClient() reports failure.
#     - Call StageEnd() to mark the end of the build stage.
#
# RETURNS:
#     OK    - Client build completed successfully.
#     ERROR - BuildClient() reported failure.
#
# SIDE EFFECTS:
#     - Writes a timestamped build log file into the specified log directory.
#
# NOTES:
#     Caller must ensure that the log directory exists and is writable.
#===============================================================================
sub ClientBuild {
    my ($install, $logDir, $dateTime) = @_;
    my $cb = TAFMsg("ClientBuild");

    my $buildLog = $logDir . "client-build_" . $dateTime . ".log";

    PrintHeader("== STAGE: CLIENT SOURCE BUILDING =================", "=", 71);

    # Call in to load test suite's BuildClient 
    my $res = main::BuildClient($install, $buildLog);
    return ERROR if $res != OK;

    StageEnd($cb);
    return OK;
}

#===============================================================================
# SetCMakePath
#
# PURPOSE:
#     Validate and set the CMAKE_PATH environment variable. This routine checks
#     that the provided path is defined, non-empty, and executable before
#     assigning it to the environment.
#
# PARAMETERS:
#     $cmake_path  - Path to the CMake executable.
#
# BEHAVIOR:
#     - Start the SetCMakePath stage for traceability.
#     - If a non-empty path is provided:
#           * Verify that the path points to an executable file.
#           * Set the CMAKE_PATH environment variable on success.
#           * Log a warning and return ERROR if the file is missing or not
#             executable.
#     - If no path is provided, log that no CMAKE_PATH override is defined.
#
# RETURNS:
#     OK    - CMAKE_PATH set successfully or no override provided.
#     ERROR - Validation failed for the provided CMake path.
#
# SIDE EFFECTS:
#     - May modify the CMAKE_PATH environment variable.
#
# NOTES:
#     Caller must ensure that the provided path is correct for the target
#     platform.
#===============================================================================
sub SetCMakePath {
    my ($cmake_path) = @_;

    my $its = StageStart(TAFMsg("SetCMakePath"));

    if (defined $cmake_path && $cmake_path ne '') {
        if (-x $cmake_path) {
            $ENV{CMAKE_PATH} = $cmake_path;
            PrintVerbose($its . " CMAKE_PATH set to $cmake_path");
        } else {
            PrintWarning($its . " CMAKE_PATH defined but not found or not executable: $cmake_path");
            StageEnd($its);
            return ERROR;
        }
    } else {
        PrintVerbose($its . " No CMAKE_PATH defined.");
    }

    StageEnd($its);
    return OK;
}

#############################################################################
# Module terminator
#############################################################################
1;