#!/usr/bin/env python3
#############################################################################
# perf_runner.py
#
# Created: Feb 2026
# Last Modified: March 2026
#
# Version: 1.0
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
#     Provide a standalone, deterministic wrapper around Linux perf for use
#     by the TAF profiling subsystem. This script executes perf in either
#     duration mode or continuous mode, manages stop-file semantics, and
#     generates optional report and flamegraph data. All behavior is driven
#     by explicit command line arguments supplied by the TAF Perl layer.
#
# ARCHITECTURAL ROLE:
#     - External helper invoked by profile_libs::perf.
#     - Performs all direct interaction with perf, including process
#       management, signal handling, and output file creation.
#     - Implements continuous mode semantics (stop-file polling and
#       stopped-file signaling).
#     - Provides a stable CLI contract for the Perl orchestration layer.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not discover python or perf; caller must ensure availability.
#     - Does not interpret TAF context structures.
#     - Does not modify environment variables or global system state.
#     - Does not manage iteration directories; caller provides all paths.
#     - Does not enforce TAF sequencing; it is a pure subprocess runner.
#
# CONTRACT:
#     - Caller must supply all required arguments:
#           --pid
#           (--duration or --continuous)
#     - Duration mode requires a positive integer duration.
#     - Continuous mode requires stop-file and stopped-file paths.
#     - Optional features (report, flamegraph, logfile) are enabled only
#       when explicitly requested.
#     - Script exits with nonzero status on any failure.
#
# GUARANTEES:
#     - No hidden side effects; no mutation of external state.
#     - All perf invocations are explicit and logged when verbose mode is
#       enabled.
#     - Continuous mode always writes the stopped-file on completion.
#     - All subprocess calls use check=True unless dry-run is active.
#     - All output files are created exactly where the caller specifies.
#
# NOTES:
#     - This script is intentionally minimal and avoids any dependency
#       beyond the Python standard library.
#     - TAF expects this script to reside in profile_libs/scripts/.
#     - All error messages are printed in plain ASCII for log safety.
#############################################################################
import argparse
import os
import subprocess
import time
import logging
import sys
from datetime import datetime
import pwd
import shlex
import signal


# ======================================================================
# check_perf_access_or_root()
#
# PURPOSE:
#     Validate that the current process has sufficient privileges to run
#     Linux perf. This routine enforces the kernel's perf_event_paranoid
#     policy and exits immediately when profiling is not permitted.
#
# BEHAVIOR:
#     - Reads /proc/sys/kernel/perf_event_paranoid.
#     - Converts the value to an integer.
#     - When the value is greater than -1 and the effective UID is not
#       root, the routine terminates the program with an error message.
#     - Any failure to read or parse the paranoid value results in an
#       immediate exit with an error message.
#
# RETURNS:
#     This routine does not return. It either completes silently when
#     access is permitted or terminates the program via sys.exit().
#
# SIDE EFFECTS:
#     - Terminates the process on failure.
#     - Performs no logging unless the caller has configured logging.
#     - Does not modify environment variables or global state.
#
# NOTES:
#     - This check mirrors the behavior expected by Linux perf and
#       ensures predictable failure modes when profiling is not allowed.
#     - Caller is not expected to catch the exit; failure is considered
#       a hard stop for profiling startup.
# ======================================================================
def check_perf_access_or_root():
    try:
        with open("/proc/sys/kernel/perf_event_paranoid", "r") as f:
            val = int(f.read().strip())
            if val > -1 and os.geteuid() != 0:
                sys.exit("Root privileges required unless perf_event_paranoid is set to -1")
    except Exception as e:
        sys.exit(f"Perf access check failed: {e}")


# ======================================================================
# validate_pid(pid)
#
# PURPOSE:
#     Determine whether a given PID refers to a valid, running, non-zombie
#     process on the local system. This routine performs lightweight checks
#     against the /proc filesystem to confirm liveness without invoking any
#     external commands.
#
# BEHAVIOR:
#     - Constructs /proc/<pid> and returns False immediately if the path
#       does not exist.
#     - Attempts to read /proc/<pid>/status.
#     - Scans for the "State:" line and returns False when the state
#       contains the character "Z", indicating a zombie process.
#     - If the status file cannot be read, falls back to the existence
#       check and treats the PID as valid.
#
# RETURNS:
#     True   - The PID exists and is not a zombie.
#     False  - The PID does not exist or is a zombie.
#
# SIDE EFFECTS:
#     None. This routine does not modify global state, environment
#     variables, or logging configuration.
#
# NOTES:
#     - This check is intentionally minimal and relies solely on /proc.
#     - Caller is responsible for handling invalid PIDs and terminating
#       profiling startup when necessary.
# ======================================================================
def validate_pid(pid):
    proc_path = f"/proc/{pid}"
    if not os.path.exists(proc_path):
        return False
    try:
        with open(os.path.join(proc_path, "status"), "r") as f:
            for line in f:
                if line.startswith("State:"):
                    # e.g. "State:\tS (sleeping)"
                    if "Z" in line:
                        return False
                    break
    except Exception:
        # If we can't read status, fall back to existence check
        pass
    return True


# ======================================================================
# timestamped_name(base, ext)
#
# PURPOSE:
#     Generate a deterministic, timestamped filename using the current
#     local time. This helper ensures that duration-mode profiling
#     produces unique output files for each invocation.
#
# BEHAVIOR:
#     - Obtains the current time using datetime.now().
#     - Formats the timestamp as YYYYMMDD_HHMMSS.
#     - Constructs a filename of the form:
#           <base>_<timestamp>.<ext>
#     - Performs no validation of the base or extension strings.
#
# RETURNS:
#     A string containing the timestamped filename.
#
# SIDE EFFECTS:
#     None. This routine does not modify global state, environment
#     variables, or logging configuration.
#
# NOTES:
#     - Used only in duration mode; continuous mode uses fixed filenames.
#     - Caller is responsible for providing valid base and extension
#       values and for ensuring the target directory exists.
# ======================================================================
def timestamped_name(base, ext):
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    return f"{base}_{ts}.{ext}"


# ======================================================================
# is_root()
#
# PURPOSE:
#     Determine whether the current process is running with effective
#     root privileges. This helper is used to decide whether ownership
#     adjustments are required after profiling completes.
#
# BEHAVIOR:
#     - Calls os.geteuid() to obtain the effective user ID.
#     - Compares the value to zero, the standard UID for root.
#
# RETURNS:
#     True   - The effective UID is zero.
#     False  - The effective UID is nonzero.
#
# SIDE EFFECTS:
#     None. This routine does not modify global state, environment
#     variables, or logging configuration.
#
# NOTES:
#     - Used by fix_ownership_multi() to determine whether ownership
#       correction is required after profiling.
#     - This check is lightweight and does not perform any additional
#       privilege validation.
# ======================================================================
def is_root():
    return os.geteuid() == 0


# ======================================================================
# fix_ownership(path, verbose=False)
#
# PURPOSE:
#     Adjust the ownership of a file created by perf so that it is owned
#     by the invoking user rather than root. This helper is used after
#     profiling completes when the script was executed with elevated
#     privileges.
#
# BEHAVIOR:
#     - Returns immediately if the target path does not exist.
#     - Determines the intended owner by checking the SUDO_USER
#       environment variable, falling back to USER when necessary.
#     - Looks up the UID and GID of the target user via pwd.getpwnam().
#     - Calls os.chown() to update ownership of the file.
#     - When verbose mode is enabled, logs a message on success.
#     - On any failure, logs a warning but does not raise an exception.
#
# RETURNS:
#     None. This routine performs its work for side effects only.
#
# SIDE EFFECTS:
#     - May change file ownership on disk.
#     - Emits log messages when verbose mode is enabled.
#     - Emits warnings on failure but does not terminate the program.
#
# NOTES:
#     - This helper is invoked only when the caller detects that the
#       script is running as root.
#     - Ownership correction is best-effort; profiling results remain
#       usable even if ownership cannot be changed.
# ======================================================================
def fix_ownership(path, verbose=False):
    if not os.path.exists(path):
        return
    target_user = os.environ.get("SUDO_USER", os.environ.get("USER"))
    if not target_user:
        return
    try:
        pw_record = pwd.getpwnam(target_user)
        uid = pw_record.pw_uid
        gid = pw_record.p_gid
        os.chown(path, uid, gid)
        if verbose:
            logging.info(f"Changed ownership of {path} to {target_user}")
    except Exception as e:
        logging.warning(f"Failed to change ownership of {path}: {e}")


# ======================================================================
# fix_ownership_multi(paths, verbose=False)
#
# PURPOSE:
#     Apply ownership correction to a list of profiling output files.
#     This helper iterates over all provided paths and delegates the
#     actual ownership change to fix_ownership(). It exists to keep the
#     call sites simple and contributor-proof.
#
# BEHAVIOR:
#     - Iterates over the supplied list of paths.
#     - Skips any entry that is None or empty.
#     - Invokes fix_ownership() for each valid path.
#     - Performs no additional validation or error handling.
#
# RETURNS:
#     None. This routine performs its work for side effects only.
#
# SIDE EFFECTS:
#     - May change file ownership on disk when running as root.
#     - Emits log messages when verbose mode is enabled.
#     - Does not raise exceptions; all errors are handled by
#       fix_ownership().
#
# NOTES:
#     - This helper is typically invoked after profiling completes to
#       ensure that generated files are owned by the invoking user.
#     - The list may contain None entries (for example, when flamegraph
#       output is not requested); these are ignored safely.
# ======================================================================
def fix_ownership_multi(paths, verbose=False):
    for p in paths:
        if p:
            fix_ownership(p, verbose)


# ======================================================================
# build_perf_cmd(pid, perf_opts, output_file, extra_args=None)
#
# PURPOSE:
#     Construct the base perf command used by both duration mode and
#     continuous mode. This helper centralizes argument assembly so that
#     all perf invocations remain consistent and contributor-proof.
#
# BEHAVIOR:
#     - Starts with ["perf", "record"].
#     - When perf_opts is provided, splits the option string using
#       shlex.split() and appends the resulting tokens.
#     - Appends "-p <pid>" to target the specified process.
#     - Appends "-o <output_file>" to control where perf writes data.
#     - When extra_args is provided, extends the command with those
#       arguments exactly as given.
#     - Performs no validation of pid, perf_opts, or file paths.
#
# RETURNS:
#     A list of strings representing the full perf command suitable for
#     passing directly to subprocess.run() or subprocess.Popen().
#
# SIDE EFFECTS:
#     None. This routine does not modify global state, environment
#     variables, or logging configuration.
#
# NOTES:
#     - Duration mode supplies extra_args=["--", "sleep", <duration>].
#     - Continuous mode supplies no extra_args.
#     - All quoting and tokenization are handled explicitly; no shell
#       interpretation is used.
# ======================================================================
def build_perf_cmd(pid, perf_opts, output_file, extra_args=None):
    cmd = ["perf", "record"]
    if perf_opts:
        cmd.extend(shlex.split(perf_opts))
    cmd.extend(["-p", str(pid), "-o", output_file])
    if extra_args:
        cmd.extend(extra_args)
    return cmd


# ======================================================================
# run_perf_duration(pid, duration, perf_opts, output_file, verbose, dry_run)
#
# PURPOSE:
#     Execute perf in duration mode by recording samples for a fixed
#     number of seconds. This routine constructs the full perf command,
#     logs it when requested, and runs it synchronously until completion.
#
# BEHAVIOR:
#     - Builds the perf command using build_perf_cmd(), supplying:
#           * the target PID
#           * perf options
#           * the output file
#           * extra arguments ["--", "sleep", <duration>] so perf records
#             while the sleep process runs.
#     - When verbose or dry_run is enabled, logs the full command.
#     - When dry_run is False, executes the command using subprocess.run()
#       with check=True to enforce failure propagation.
#     - Performs no validation of pid, duration, or file paths.
#
# RETURNS:
#     None. This routine blocks until perf completes or raises an
#     exception via subprocess.run() when check=True.
#
# SIDE EFFECTS:
#     - Runs perf as a subprocess.
#     - May create or overwrite the specified output file.
#     - May raise subprocess.CalledProcessError on failure unless dry_run
#       is active.
#
# NOTES:
#     - Duration mode is mutually exclusive with continuous mode.
#     - All timing behavior is controlled by the caller; this routine
#       performs no scheduling or delay logic beyond invoking sleep.
# ======================================================================
def run_perf_duration(pid, duration, perf_opts, output_file, verbose, dry_run):
    cmd = build_perf_cmd(pid, perf_opts, output_file, ["--", "sleep", str(duration)])
    if verbose or dry_run:
        logging.info(f"Running (duration mode): {' '.join(cmd)}")
    if not dry_run:
        subprocess.run(cmd, check=True)


# ======================================================================
# run_perf_continuous(pid, perf_opts, output_file, stop_file, stopped_file,
#                     poll_interval, verbose, dry_run, shutdown_timeout)
#
# PURPOSE:
#     Execute perf in continuous mode, running indefinitely until a
#     caller-created stop file appears. This routine manages the perf
#     subprocess, handles signal-based shutdown, and writes a stopped-file
#     to signal completion. It provides deterministic, contributor-proof
#     behavior for long-running profiling sessions.
#
# BEHAVIOR:
#     - Builds the perf command using build_perf_cmd() with no extra
#       arguments, causing perf to run until explicitly interrupted.
#     - Logs the command when verbose or dry_run is enabled.
#     - When dry_run is True:
#           * Logs a simulated wait loop.
#           * Returns immediately without running perf.
#     - When dry_run is False:
#           * Starts perf using subprocess.Popen().
#           * Enters a polling loop, sleeping poll_interval seconds
#             between checks, until the stop file appears.
#           * If perf exits before the stop file appears, raises a
#             RuntimeError.
#           * Sends SIGINT to perf when the stop file is detected.
#           * Waits up to shutdown_timeout seconds for perf to exit.
#           * If perf does not exit on SIGINT, sends SIGTERM.
#           * If perf still does not exit, sends SIGKILL as a last resort.
#           * Writes the stopped-file to indicate profiling completion.
#     - Ensures perf is not left running by killing it in the finally
#       block if necessary.
#
# RETURNS:
#     None. This routine blocks until perf exits or raises an exception
#     when unexpected behavior occurs.
#
# SIDE EFFECTS:
#     - Runs perf as a long-lived subprocess.
#     - Sends SIGINT, SIGTERM, or SIGKILL to the perf process.
#     - Creates or overwrites the stopped-file.
#     - May raise RuntimeError or subprocess exceptions unless dry_run
#       is active.
#
# NOTES:
#     - Continuous mode is mutually exclusive with duration mode.
#     - The caller is responsible for creating the stop file to end
#       profiling.
#     - All shutdown behavior is deterministic and follows a strict
#       escalation sequence: SIGINT -> SIGTERM -> SIGKILL.
# ======================================================================
def run_perf_continuous(pid, perf_opts, output_file, stop_file, stopped_file,
                        poll_interval, verbose, dry_run, shutdown_timeout):
    cmd = build_perf_cmd(pid, perf_opts, output_file)
    if verbose or dry_run:
        logging.info(f"Running (continuous mode): {' '.join(cmd)}")

    if dry_run:
        # Simulate wait for stop file
        logging.info("Dry-run: simulating continuous profiling wait loop.")
        return

    proc = subprocess.Popen(cmd, preexec_fn=os.setsid)

    try:
        # Wait for stop file
        logging.info(f"Waiting for stop file: {stop_file}")
        while not os.path.exists(stop_file):
            if proc.poll() is not None:
                raise RuntimeError("perf exited before stop file appeared")
            time.sleep(poll_interval)

        logging.info("Stop file detected, sending SIGINT to perf.")
        os.killpg(proc.pid, signal.SIGINT)

        try:
            proc.wait(timeout=shutdown_timeout)
        except subprocess.TimeoutExpired:
            logging.warning("perf did not exit on SIGINT, sending SIGTERM.")
            proc.terminate()
            try:
                proc.wait(timeout=shutdown_timeout)
            except subprocess.TimeoutExpired:
                logging.error("perf did not exit on SIGTERM, killing.")
                proc.kill()
                proc.wait()

        # Write stopped file to signal completion
        try:
            with open(stopped_file, "w") as f:
                f.write("profiling stopped\n")
            logging.info(f"Wrote stopped file: {stopped_file}")
        except Exception as e:
            logging.error(f"Failed to write stopped file {stopped_file}: {e}")

    finally:
        # Ensure process is not left running
        if proc.poll() is None:
            logging.warning("perf still running in finally block, killing.")
            proc.kill()
            proc.wait()


# ======================================================================
# generate_report(output_file, report_file, verbose, dry_run)
#
# PURPOSE:
#     Produce a human-readable perf report from a recorded perf.data file.
#     This routine invokes "perf report" in stdio mode and writes the
#     formatted output to the specified report file. It provides a stable,
#     deterministic reporting step for both duration and continuous modes.
#
# BEHAVIOR:
#     - Constructs the command:
#           perf report -i <output_file> --stdio -f
#     - Logs the command when verbose or dry_run is enabled.
#     - When dry_run is False:
#           * Opens the report_file for writing.
#           * Executes the command using subprocess.run() with stdout
#             redirected to the file.
#           * Uses check=True to propagate failures.
#     - When dry_run is True:
#           * Does not execute perf.
#           * Performs logging only.
#
# RETURNS:
#     None. This routine either completes successfully or raises
#     subprocess.CalledProcessError when perf fails (unless dry_run is
#     active).
#
# SIDE EFFECTS:
#     - Creates or overwrites the report_file.
#     - Runs perf as a subprocess unless dry_run is enabled.
#     - May raise exceptions from subprocess.run() when check=True.
#
# NOTES:
#     - This routine does not validate the existence or readability of
#       output_file; perf itself enforces correctness.
#     - Caller is responsible for ensuring that output_file was produced
#       by a prior profiling step.
# ======================================================================
def generate_report(output_file, report_file, verbose, dry_run):
    cmd = ["perf", "report", "-i", output_file, "--stdio", "-f"]
    if verbose or dry_run:
        logging.info(f"Generating report: {' '.join(cmd)}")
    if not dry_run:
        with open(report_file, "w") as f:
            subprocess.run(cmd, stdout=f, check=True)


# ======================================================================
# generate_flamegraph_data(output_file, flamegraph_file, verbose, dry_run)
#
# PURPOSE:
#     Produce perf script output suitable for downstream flamegraph
#     generation. This routine invokes "perf script" on the recorded
#     perf.data file and writes the raw stack trace stream to the
#     specified flamegraph file.
#
# BEHAVIOR:
#     - Constructs the command:
#           perf script -i <output_file>
#     - Attempts to inspect the ownership of output_file using os.stat().
#     - When the file is not owned by the current user or root, appends
#       "-f" to the command to force processing.
#     - If ownership inspection fails, logs a warning and appends "-f"
#       as a fallback.
#     - Logs the command when verbose or dry_run is enabled.
#     - When dry_run is False:
#           * Opens flamegraph_file for writing.
#           * Executes the command using subprocess.run() with stdout
#             redirected to the file.
#           * Uses check=True to propagate failures.
#     - When dry_run is True:
#           * Does not execute perf.
#           * Performs logging only.
#
# RETURNS:
#     None. This routine either completes successfully or raises
#     subprocess.CalledProcessError when perf fails (unless dry_run is
#     active).
#
# SIDE EFFECTS:
#     - Creates or overwrites the flamegraph_file.
#     - Runs perf as a subprocess unless dry_run is enabled.
#     - Emits warnings when ownership checks fail.
#
# NOTES:
#     - This routine does not generate a visual flamegraph; it produces
#       the raw stack trace data consumed by external flamegraph tools.
#     - Caller is responsible for ensuring that output_file exists and
#       was produced by a prior profiling step.
# ======================================================================
def generate_flamegraph_data(output_file, flamegraph_file, verbose, dry_run):
    cmd = ["perf", "script", "-i", output_file]

    try:
        stat_info = os.stat(output_file)
        current_uid = os.geteuid()
        current_gid = os.getegid()
        if stat_info.st_uid not in (current_uid, 0) or stat_info.st_gid not in (current_gid, 0):
            if verbose:
                logging.info(
                    f"Ownership mismatch: file owned by UID {stat_info.st_uid}, GID {stat_info.st_gid}, "
                    f"current UID {current_uid}, GID {current_gid}. Adding -f."
                )
            cmd.append("-f")
    except Exception as e:
        logging.warning(f"Ownership check failed: {e}. Proceeding with -f as fallback.")
        cmd.append("-f")

    if verbose or dry_run:
        logging.info(f"Generating flamegraph data: {' '.join(cmd)}")
    if not dry_run:
        with open(flamegraph_file, "w") as f:
            subprocess.run(cmd, stdout=f, check=True)


# ======================================================================
# generate_flamegraph_svg(flamegraph_file, verbose, dry_run)
#
# PURPOSE:
#     Convert raw perf script output into a folded stack file and an
#     interactive SVG flamegraph. This routine is the second stage of
#     flamegraph generation, following generate_flamegraph_data().
#
# FLAMEGRAPH TOOLKIT CREDIT:
#     This function uses two scripts from the FlameGraph project
#     created and maintained by Brendan Gregg:
#
#         stackcollapse-perf.pl
#         flamegraph.pl
#
#     The original project, documentation, and full toolkit are
#     available at:
#
#         https://github.com/brendangregg/FlameGraph
#
#     These scripts are included in TAF under their original license
#     (CDDL). See the accompanying README.txt for details.
#
# BEHAVIOR:
#     - Locates the FlameGraph scripts bundled with TAF.
#     - Produces:
#           <flamegraph_file>.folded
#           <flamegraph_file>.svg
#     - Logs commands when verbose or dry_run is enabled.
#     - Executes the collapse and SVG generation steps unless dry_run
#       is active.
#
# RETURNS:
#     None. Raises subprocess.CalledProcessError on failure unless
#     dry_run is active.
#
# SIDE EFFECTS:
#     - Creates or overwrites folded and SVG flamegraph outputs.
#     - Executes external Perl scripts unless dry_run is enabled.
#
# NOTES:
#     - This routine assumes flamegraph_file was produced by
#       generate_flamegraph_data().
#     - The FlameGraph scripts are stored in:
#           taf-perl/libs/profile_libs/scripts/flamegraph/
# ======================================================================
def generate_flamegraph_svg(flamegraph_file, verbose, dry_run):
    # Directory containing stackcollapse-perf.pl and flamegraph.pl
    flame_dir = os.path.join(
        os.path.dirname(os.path.dirname(__file__)),
        "scripts",
        "flamegraph"
    )

    stackcollapse = os.path.join(flame_dir, "stackcollapse-perf.pl")
    flamegraph   = os.path.join(flame_dir, "flamegraph.pl")

    folded_file = flamegraph_file + ".folded"
    svg_file    = flamegraph_file + ".svg"

    if verbose or dry_run:
        logging.info(f"Collapsing stacks: {stackcollapse} {flamegraph_file}")
        logging.info(f"Generating SVG: {flamegraph} {folded_file}")

    if not dry_run:
        # Collapse raw perf script output
        with open(folded_file, "w") as f_folded:
            subprocess.run(
                [stackcollapse, flamegraph_file],
                stdout=f_folded,
                check=True
            )

        # Generate SVG flamegraph
        with open(svg_file, "w") as f_svg:
            subprocess.run(
                [flamegraph, folded_file],
                stdout=f_svg,
                check=True
            )
# ======================================================================
# setup_logging(log_dir)
#
# PURPOSE:
#     Configure logging for the profiler runner so that all messages are
#     written exclusively to a timestamped log file. This routine removes
#     any existing handlers attached to the root logger and installs a
#     single FileHandler. No output is emitted to stdout or stderr.
#
# BEHAVIOR:
#     - Ensures that log_dir exists, creating it when necessary.
#     - Constructs a logfile path using the pattern:
#           profiler_runner_<YYYYMMDD>_<HHMMSS>.log
#     - Obtains the root logger and sets its level to INFO.
#     - Removes any pre-existing handlers to prevent duplicate or
#       unintended console output.
#     - Creates a FileHandler pointing to the logfile.
#     - Applies a formatter of the form:
#           "%(asctime)s [%(levelname)s] %(message)s"
#     - Attaches only the FileHandler to the logger.
#
# RETURNS:
#     The full path to the logfile created for this run.
#
# SIDE EFFECTS:
#     - Creates the log directory if it does not exist.
#     - Creates a new logfile and writes all subsequent log messages to
#       that file.
#     - Suppresses all console output by removing StreamHandlers.
#
# NOTES:
#     - This routine must be called before any logging occurs to ensure
#       that no messages leak to stdout.
#     - The caller is responsible for storing or passing the returned
#       logfile path if it needs to be referenced later.
# ======================================================================
def setup_logging(log_dir):
    os.makedirs(log_dir, exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    logfile = os.path.join(log_dir, f"profiler_runner_{timestamp}.log")

    logger = logging.getLogger()
    logger.setLevel(logging.INFO)

    # Remove any existing handlers (important if script is reloaded)
    for h in list(logger.handlers):
        logger.removeHandler(h)

    # File-only handler
    file_handler = logging.FileHandler(logfile)
    file_handler.setLevel(logging.INFO)
    file_handler.setFormatter(logging.Formatter(
        "%(asctime)s [%(levelname)s] %(message)s"
    ))

    logger.addHandler(file_handler)
    return logger, logfile


# ======================================================================
# main()
#
# PURPOSE:
#     Serve as the top-level entry point for the perf runner. This routine
#     parses all command line arguments, configures logging, validates
#     profiling mode, performs privilege and PID checks, selects output
#     filenames, and dispatches execution to either duration mode or
#     continuous mode. It also triggers optional report and flamegraph
#     generation and performs ownership correction when running as root.
#
# BEHAVIOR:
#     - Defines and parses all CLI arguments using argparse.
#     - Configures logging based on --verbose and --logfile.
#     - Validates perf access using check_perf_access_or_root().
#     - Validates the target PID using validate_pid().
#     - Enforces mutual exclusivity between --duration and --continuous.
#     - Applies start-delay when requested.
#     - Selects output filenames:
#           * Fixed names in continuous mode.
#           * Timestamped names in duration mode.
#     - Determines stop-file and stopped-file paths.
#     - Dispatches to run_perf_continuous() or run_perf_duration().
#     - Generates report and flamegraph data when requested.
#     - When running as root, corrects ownership of generated files.
#     - Exits with nonzero status on any failure.
#
# RETURNS:
#     None. This routine terminates the program via sys.exit() on error
#     or returns normally when profiling completes successfully.
#
# SIDE EFFECTS:
#     - Runs perf as one or more subprocesses.
#     - Creates or overwrites profiling output files.
#     - Writes report and flamegraph files when requested.
#     - Writes a stopped-file in continuous mode.
#     - May change file ownership when executed as root.
#
# NOTES:
#     - This routine is the only entry point expected to be invoked
#       directly by the TAF Perl layer.
#     - All operational logic is delegated to helper functions to keep
#       main() readable and contributor-proof.
# ======================================================================
def main():
    parser = argparse.ArgumentParser(description="Linux perf profiler runner for TAF")
    parser.add_argument("--pid", type=int, required=True, help="PID to profile")
    parser.add_argument("--duration", type=int, help="Duration in seconds (duration mode)")
    parser.add_argument("--start-delay", type=int, default=0, help="Delay before profiling starts")
    parser.add_argument("--perf-opts", default="-e cpu-clock:pp", help="Perf options string")

    parser.add_argument("--profile-output", help="Raw perf output file")
    parser.add_argument("--log-dir", help="Directory for profiler log")
    parser.add_argument("--report-file", help="Readable summary file")
    parser.add_argument("--report", action="store_true", help="Generate report after profiling")
    parser.add_argument("--flamegraph", action="store_true", help="Generate perf script output for flamegraph")
    parser.add_argument("--flamegraph-file", help="Output file for flamegraph data")

    parser.add_argument("--continuous", action="store_true",
                        help="Run until stop file appears instead of fixed duration")
    parser.add_argument("--stop-file", help="Path to stop file (default: profiling.stop in CWD)")
    parser.add_argument("--stopped-file", help="Path to stopped file (default: profiling.stopped in CWD)")
    parser.add_argument("--poll-interval", type=float, default=0.2,
                        help="Polling interval in seconds for stop file in continuous mode")
    parser.add_argument("--shutdown-timeout", type=float, default=10.0,
                        help="Timeout in seconds for perf to exit after SIGINT/SIGTERM")

    parser.add_argument("--dry-run", action="store_true", help="Simulate execution without running perf")
    parser.add_argument("--validate-only", action="store_true",
                        help="Run validation checks and exit")
    parser.add_argument("--verbose", action="store_true", help="Enable verbose output")
    parser.add_argument("--logfile", help="Optional log file")

    args = parser.parse_args()

    # If validate, we validate access and pid is active.
    if args.validate_only:
        try:
            check_perf_access_or_root()
            if not validate_pid(args.pid):
                sys.exit("Invalid or non-running PID")
            print("OK")
            return
        except SystemExit as e:
            print(str(e), file=sys.stderr)
            sys.exit(1)

    # Logging setup
    log_level = logging.INFO if args.verbose else logging.WARNING
    logger, log_path = setup_logging(args.log_dir)
    logger.info("Profiler runner starting")
    logger.info("Log file: %s", log_path)
    logger.info("Runner PID: %d", os.getpid())
    logger.info("Arguments:")
    for k, v in vars(args).items():
        logger.info("  %s = %r", k, v)

    logging.info("Starting perf_runner")

    check_perf_access_or_root()

    if not validate_pid(args.pid):
        sys.exit(f"PID {args.pid} is not valid, not running, or is a zombie.")

    if args.continuous and args.duration is not None:
        sys.exit("Cannot specify both --continuous and --duration.")

    if not args.continuous and args.duration is None:
        sys.exit("Either --duration (duration mode) or --continuous must be specified.")

    if args.start_delay > 0:
        logging.info(f"Waiting {args.start_delay} seconds before starting profiling...")
        if not args.dry_run:
            time.sleep(args.start_delay)

    # File naming: in TAF, the iteration subdir will be CWD, so fixed names are fine.
    output_file = args.profile_output or ("perf.data" if args.continuous else timestamped_name("perf", "data"))
    report_file = args.report_file or ("perf_report.txt" if args.continuous else timestamped_name("perf_report", "txt"))
    flamegraph_file = args.flamegraph_file

    stop_file = args.stop_file or os.path.join(os.getcwd(), "profiling.stop")
    stopped_file = args.stopped_file or os.path.join(os.getcwd(), "profiling.stopped")

    try:
        if args.continuous:
            run_perf_continuous(
                pid=args.pid,
                perf_opts=args.perf_opts,
                output_file=output_file,
                stop_file=stop_file,
                stopped_file=stopped_file,
                poll_interval=args.poll_interval,
                verbose=args.verbose,
                dry_run=args.dry_run,
                shutdown_timeout=args.shutdown_timeout,
            )
        else:
            run_perf_duration(
                pid=args.pid,
                duration=args.duration,
                perf_opts=args.perf_opts,
                output_file=output_file,
                verbose=args.verbose,
                dry_run=args.dry_run,
            )

        if args.report:
            generate_report(output_file, report_file, args.verbose, args.dry_run)
        if args.flamegraph and flamegraph_file:
            generate_flamegraph_data(output_file, flamegraph_file, args.verbose, args.dry_run)
            generate_flamegraph_svg(flamegraph_file, args.verbose, args.dry_run)

        if is_root():
            fix_ownership_multi([output_file, report_file, flamegraph_file, stopped_file], args.verbose)

    except subprocess.CalledProcessError as e:
        sys.exit(f"Perf execution failed: {e}")
    except Exception as e:
        logging.error(f"Unexpected error: {e}")
        sys.exit(1)

    logging.info("Profiling complete.")


if __name__ == "__main__":
    main()