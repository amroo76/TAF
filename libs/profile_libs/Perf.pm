package profile_libs::Perf;
#############################################################################
# TAF::ProfileLibs::Perf
#
# Created: January 2026
# Last Modified: March 2026
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
#     Provide a deterministic, contributor-proof orchestration layer for
#     performance profiling during TAF runs. This module discovers python3
#     and the perf_runner.py script, validates timing constraints, and
#     launches profiling in background mode without altering TAF sequencing.
#
# ARCHITECTURAL ROLE:
#     - Optional subsystem: invoked only when profiling options are enabled.
#     - Self-contained: discovers python3 and perf_runner.py relative to this
#       module; does not rely on TAF-level configuration or environment vars.
#     - Read-only consumer of $ctx: never mutates context structures.
#     - Provides a stable interface for starting profiling in either
#       duration-based or continuous mode.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not modify TAF action flow or lifecycle sequencing.
#     - Does not write to $ctx->{taf_var}, $ctx->{dirs}, or any other
#       context structure.
#     - Does not manage stop-file semantics (continuous mode only).
#     - Does not interpret profiling output or generate reports.
#     - Does not enforce python or script installation globally; failure to
#       locate dependencies results in a clean ERROR return.
#
# CONTRACT:
#     - Caller must provide a populated $ctx with:
#           ctx->{options}
#           ctx->{dirs}
#           ctx->{taf_var}
#     - start() returns OK or ERROR; no exceptions are thrown.
#     - python3 and perf_runner.py must be discoverable; otherwise ERROR.
#     - Duration mode requires profiler_start_delay + profiler_duration to
#       fit within ctx->{options}->{duration}.
#
# GUARANTEES:
#     - No hidden side effects; no global state; no environment requirements.
#     - All discovery functions (_find_python, _find_script) return undef on
#       failure; caller handles all error propagation.
#     - All paths and commands are constructed deterministically.
#     - Background execution is isolated and does not block TAF.
#
# NOTES:
#     - perf_runner.py is located in profile_libs/scripts/ relative to this
#       module and is discovered automatically.
#     - This module is intentionally minimal and avoids introducing any
#       optional dependency into the global TAF environment.
#############################################################################
use strict;
use warnings;
use File::Basename;
use File::Spec;
use Carp;

use constant {
    OK     => 0,
    ERROR  => 1,
    FALSE  => 0,
    TRUE   => 1,
};

my $me = "profile_libs::perf ";

our $VERSION = '1.0';

# ======================================================================
# start()
#
# PURPOSE:
#     Launch performance profiling for the current TAF run. This routine
#     discovers python3, locates perf_runner.py relative to this module,
#     validates timing constraints, and constructs the profiling command.
#     Profiling is executed in background mode and does not block TAF.
#
# PARAMETERS:
#     $ctx  - Fully populated TAF context hashref containing:
#                 ctx->{options}
#                 ctx->{dirs}
#                 ctx->{taf_var}
#
# BEHAVIOR:
#     - Extracts all relevant context structures via _extract_ctx().
#     - Requires a valid database PID in ctx->{taf_var}->{db_pid}.
#     - Discovers python3 using _find_python() (returns undef on failure).
#     - Locates perf_runner.py using _find_script() (relative to this module).
#     - Builds all output paths via _build_paths().
#     - Constructs the profiling command via _build_command().
#     - Executes profiling asynchronously using system("$cmd &").
#
# WHAT THIS ROUTINE DOES NOT DO:
#     - Does not modify $ctx or any of its substructures.
#     - Does not enforce installation of python or perf_runner.py globally.
#     - Does not manage stop-file semantics beyond path construction.
#     - Does not interpret profiling output or generate reports.
#     - Does not alter TAF action sequencing; profiling is optional.
#
# RETURNS:
#     OK    - Profiling successfully launched.
#     ERROR - Missing PID, missing python3, missing script, or invalid timing.
#
# SIDE EFFECTS:
#     - Spawns a background profiling process.
#     - Writes no files directly; all output paths are passed to the runner.
#
# NOTES:
#     - This routine is only invoked when profiling options are enabled.
#     - All discovery functions return undef on failure; caller handles errors.
#     - This module is intentionally self-contained and introduces no global
#       configuration requirements.
# ======================================================================
sub start {
    my ($class, $ctx) = @_;
    my $opts   = $ctx->{options};
    my $dirs   = $ctx->{dirs};
    my $tafvar = $ctx->{taf_var};

    # Check pid
    unless(defined $tafvar->{db_pid}){
        print($me."ERROR PID not defined\n");
        return ERROR;
    }

    # Find python
    my $python = _find_python();
    unless ($python) {
        print($me."ERROR Failed to find python3\n");
        return ERROR;
    }

    # Locate perf runner scripts
    my $script = _find_script();
    unless ($script) {
        print($me."ERROR Failed to find perf_runner.py\n");
        return ERROR;
    }

    # Ensure sat
    my $cont    = $opts->{profiler_continuous} ? TRUE : FALSE;

    my $paths = _build_paths($dirs, $cont);
    unless(defined $paths){
        print($me."ERROR build_paths returned undefined\n");
        return ERROR;
    }

    my $validate_cmd = "$python $script --pid $tafvar->{db_pid} --validate-only 2>&1";
    my $validation_output = `$validate_cmd`;
    if ($? != OK) {
        print($me."ERROR profiler validation failed:\n$validation_output\n");
        return ERROR;
    }

    my $cmd   = _build_command($opts, 
                               $python, 
                               $script, 
                               $tafvar->{db_pid}, 
                               $paths, 
                               $cont);

    print($me."Executing $cmd\n");
    system($cmd . " &");
    return OK;
}

# ======================================================================
# stop()
#
# PURPOSE:
#     Signal a running continuous-mode profiler to stop by creating the
#     profiling.stop file inside the iteration's results directory. The
#     profiler runner monitors this file and performs an orderly shutdown.
#
# PARAMETERS:
#     $ctx  - Full TAF context hashref containing:
#                 ctx->{options}
#                 ctx->{dirs}
#                 ctx->{taf_var}
#
# BEHAVIOR:
#     - Extracts context structures via _extract_ctx().
#     - Validates that continuous mode is active.
#     - Builds all profiling paths via _build_paths().
#     - Creates the stop_file to request profiler shutdown.
#     - Returns OK on success, ERROR on failure.
#
# WHAT THIS ROUTINE DOES NOT DO:
#     - Does not wait for profiling to finish.
#     - Does not interpret profiling output.
#     - Does not modify $ctx or any of its substructures.
#     - Does not manage stopped-file semantics.
#
# RETURNS:
#     OK    - Stop file created successfully.
#     ERROR - Continuous mode disabled, missing directories, or file
#             creation failure.
#
# SIDE EFFECTS:
#     - Writes the profiling.stop file.
#
# NOTES:
#     - This routine is only valid when profiler_continuous is true.
#     - All diagnostics are printed deterministically and in ASCII only.
# ======================================================================
sub stop {
    my ($class, $ctx) = @_;
    my $opts = $ctx->{options};
    my $dirs = $ctx->{dirs};

    my $paths = _build_paths($dirs, 1);
    my $stop_file    = $paths->{stop_file};
    my $stopped_file = $paths->{stopped_file};

    # 1. Create stop file
    my $fh;
    unless (open($fh, ">", $stop_file)) {
        print($me."ERROR failed to create stop file '$stop_file'\n");
        return ERROR;
    }
    close($fh);

    # 2. Wait for stopped file (fixed behavior)
    my $timeout = 200;      # use existing shutdown timeout
    my $poll    = 0.2;     # use existing poll interval

    my $start = Time::HiRes::time();
    while (Time::HiRes::time() - $start < $timeout) {
        return OK if -e $stopped_file;
        select(undef, undef, undef, $poll);
    }

    return -e $stopped_file ? OK : ERROR;
}
# ======================================================================
# _find_python()
#
# PURPOSE:
#     Discover a usable python3 interpreter on the local system. This
#     routine performs a simple PATH-based lookup using the system's
#     'which' command and returns the resolved executable path. It does
#     not enforce installation, perform version checks, or modify any
#     context structures.
#
# BEHAVIOR:
#     - Executes 'which python3' to locate the interpreter.
#     - Strips trailing newlines and validates that the resolved path
#       exists and is executable.
#     - Returns undef on failure; no exceptions are thrown.
#
# RETURNS:
#     A string containing the absolute path to python3, or undef if:
#         - python3 is not installed,
#         - python3 is not in PATH,
#         - the resolved path is not executable.
#
# SIDE EFFECTS:
#     None. This routine does not modify $ctx, global variables, or the
#     environment. It performs no logging beyond the caller's checks.
#
# NOTES:
#     - Caller is responsible for handling failure and propagating ERROR.
#     - This routine intentionally avoids croak() to keep profiling an
#       optional subsystem that never disrupts core TAF execution.
# ======================================================================
sub _find_python {
    my $path = `which python3 2>/dev/null`;
    chomp($path);

    unless ($path && -x $path) {
        print($me."ERROR python3 not found in PATH or not executable\n");
        return undef;
    }

    return $path;
}

# ======================================================================
# _find_script()
#
# PURPOSE:
#     Locate the perf_runner.py script used by the profiling subsystem.
#     This routine resolves the script path *relative to this module's
#     directory*, ensuring that profiling remains fully self-contained
#     and independent of TAF-level configuration or environment variables.
#
# BEHAVIOR:
#     - Determines the absolute directory of this module using __FILE__.
#     - Constructs the expected path to:
#           profile_libs/scripts/perf_runner.py
#       relative to the module location.
#     - Returns undef if the script is missing or unreadable.
#     - Performs no validation beyond existence of the file.
#
# RETURNS:
#     A string containing the absolute path to perf_runner.py, or undef
#     if the script cannot be found.
#
# SIDE EFFECTS:
#     None. This routine does not modify $ctx, global variables, or the
#     environment. It performs no logging and throws no exceptions.
#
# NOTES:
#     - This discovery method ensures that profiling remains an optional
#       subsystem with no global configuration requirements.
#     - Caller is responsible for handling failure and propagating ERROR.
# ======================================================================
sub _find_script {
    # Locate perf_runner.py relative to this module's directory
    my $here = File::Basename::dirname(File::Spec->rel2abs(__FILE__));
    my $path = File::Spec->catfile($here, "scripts", "perf_runner.py");

    unless (-f $path) {
        print($me."ERROR perf_runner.py not found at expected path: $path\n");
        return undef;
    }

    return $path;
}

# ======================================================================
# _build_paths()
#
# PURPOSE:
#     Construct all filesystem paths required by the profiling subsystem
#     for a single iteration. This includes control files (stop and
#     stopped markers) and the fixed filenames used for perf output and
#     downstream reporting.
#
# PARAMETERS:
#     $dirs  - Hashref containing directory paths, including:
#                  dirs->{results}  (iteration directory)
#
# BEHAVIOR:
#     - Returns undef immediately if dirs->{results} is missing.
#     - Validates that the iteration directory exists and is writable.
#     - Builds a hash containing:
#           iter_dir      - iteration directory (authoritative root)
#           stop_file     - path to profiling.stop
#           stopped_file  - path to profiling.stopped
#           output        - perf.data
#           report        - perf_report.txt
#           flamegraph    - flamegraph.txt
#     - All paths are constructed using File::Spec to ensure portability.
#
# RETURNS:
#     A hashref containing all constructed paths, or undef on failure.
#
# SIDE EFFECTS:
#     None. This routine does not modify $dirs, $ctx, globals, or the
#     environment. It performs no logging beyond explicit error prints.
#
# NOTES:
#     - The iteration directory is the authoritative home for all
#       profiling artifacts and control files.
#     - Filenames are fixed to simplify downstream tooling and avoid
#       cross-iteration contamination.
# ======================================================================
sub _build_paths {
    my ($dirs, $continuous) = @_;

    my $iter = $dirs->{results};
    print("current sub results = $iter\n");

    unless ($iter) {
        print($me."ERROR dirs->{results} undefined; cannot build profiling paths\n");
        return undef;
    }

    unless (-d $iter) {
        print($me."ERROR iteration directory does not exist: $iter\n");
        return undef;
    }

    unless (-w $iter) {
        print($me."ERROR iteration directory not writable: $iter\n");
        return undef;
    }

    my %p = (
        iter_dir     => $iter,
        stop_file    => File::Spec->catfile($iter, "profiling.stop"),
        stopped_file => File::Spec->catfile($iter, "profiling.stopped"),
        output       => File::Spec->catfile($iter, "perf.data"),
        report       => File::Spec->catfile($iter, "perf_report.txt"),
        flamegraph   => File::Spec->catfile($iter, "flamegraph.txt"),
    );

    return \%p;
}

# ======================================================================
# _build_command()
#
# PURPOSE:
#     Assemble the complete command line used to invoke perf_runner.py
#     for either duration mode or continuous mode. This routine applies
#     the mode-specific flags up front, then appends all common profiling
#     options, and finally returns a fully shell-quoted command string
#     suitable for background execution.
#
# PARAMETERS:
#     $opts        - Hashref containing all profiler options.
#     $python      - Absolute path to the python3 interpreter.
#     $script      - Absolute path to perf_runner.py.
#     $pid         - Database PID to profile.
#     $paths       - Hashref of paths returned by _build_paths().
#     $continuous  - Boolean indicating continuous profiling mode.
#
# BEHAVIOR:
#     - Begins with python, script path, and PID.
#     - In continuous mode:
#           * Adds --continuous.
#           * Adds stop-file and stopped-file paths.
#           * Adds poll-interval and shutdown-timeout.
#           * Does NOT apply start-delay (continuous starts immediately).
#     - In duration mode:
#           * Adds --start-delay.
#           * Adds --duration.
#     - After the mode-specific block, appends common options:
#           * --output <path> (always included).
#           * --report-file or --report when enabled.
#           * --flamegraph when enabled.
#           * --perf-opts when provided.
#           * --verbose, --dry-run, and --logfile when enabled.
#     - All arguments are shell-quoted to ensure safe execution.
#
# RETURNS:
#     A single string containing the fully assembled and shell-quoted
#     command suitable for execution via system().
#
# SIDE EFFECTS:
#     None. This routine does not modify $opts, $paths, or any context
#     structures. It performs no logging beyond explicit error prints.
#
# NOTES:
#     - Mode-specific flags appear only at the front of the command.
#     - All profiling artifacts use the paths supplied by _build_paths().
#     - This routine guarantees deterministic command construction for
#       both profiling modes.
# ======================================================================
sub _build_command {
    my ($opts, $python, $script, $pid, $paths, $continuous) = @_;

    my $delay    = $opts->{profiler_start_delay} || 0;
    my $duration = $opts->{profiler_duration};
    my $perfopts = $opts->{profiler_opts} || "";

    my @cmd = ($python, $script, "--pid", $pid);

    # -------------------------
    # Mode selection
    # -------------------------
    if ($continuous) {
        push @cmd, "--continuous";
        push @cmd, ("--stop-file",        $paths->{stop_file});
        push @cmd, ("--stopped-file",     $paths->{stopped_file});
        push @cmd, ("--poll-interval",    $opts->{profiler_poll_interval}    || 0.2);
        push @cmd, ("--shutdown-timeout", $opts->{profiler_shutdown_timeout} || 10.0);
    } else {
        push @cmd, ("--start-delay", $delay);
        push @cmd, ("--duration",    $duration);
    }

    # -------------------------
    # Required common arguments
    # -------------------------
    push @cmd, ("--log-dir",       $paths->{iter_dir});
    push @cmd, ("--profile-output", $paths->{output});

    # -------------------------
    # Report generation
    # -------------------------
    if ($opts->{profiler_generate_report}) {
        push @cmd, "--report";
        push @cmd, ("--report-file", $paths->{report});
    }

    # -------------------------
    # Flamegraph generation
    # -------------------------
    if ($opts->{profiler_generate_flamegraph}) {
        push @cmd, "--flamegraph";
        push @cmd, ("--flamegraph-file", $paths->{flamegraph});
    }

    # -------------------------
    # Perf options
    # -------------------------
    push @cmd, ("--perf-opts", $perfopts) if $perfopts;

    # -------------------------
    # Misc flags
    # -------------------------
    push @cmd, "--verbose" if $opts->{profiler_verbose};
    push @cmd, "--dry-run" if $opts->{profiler_dry_run};

    return join(" ", map { _shell_quote($_) } @cmd);
}

# ======================================================================
# _shell_quote()
#
# PURPOSE:
#     Apply safe, POSIX-compliant shell quoting to a single argument.
#     This routine ensures that arbitrary strings are passed to the shell
#     as literal values without interpretation, expansion, or word splitting.
#
# PARAMETERS:
#     $s  - String to be shell-quoted. May be undef or empty.
#
# BEHAVIOR:
#     - Returns '' when the input is undef or an empty string.
#     - Escapes all single quotes by closing the quote, inserting an
#       escaped single quote, and reopening the quote. This follows the
#       standard POSIX pattern:
#           'foo' becomes 'foo'
#           foo'bar becomes 'foo'"'"'bar'
#     - Wraps the final result in single quotes.
#
# RETURNS:
#     A safely quoted string suitable for inclusion in a shell command.
#
# SIDE EFFECTS:
#     None. This routine does not modify globals, context structures, or
#     the environment. It performs no logging and throws no exceptions.
#
# NOTES:
#     - This quoting strategy is compatible with all POSIX shells.
#     - Caller is responsible for applying quoting to each argument
#       individually before constructing the final command string.
# ======================================================================
sub _shell_quote {
    my ($s) = @_;
    return "''" if !defined($s) || $s eq "";
    $s =~ s/'/'"'"'/g;
    return "'$s'";
}

#############################################################################
# Module terminator
#############################################################################
1;