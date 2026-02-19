package TAF::Run;
#############################################################################
# TAF::Run
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
#     Orchestrate the full lifecycle of a TAF test run. This module coordinates
#     test discovery, thread and iteration loops, warmup runs, setup, run,
#     post-processing, cleanup, reporting, and archiving using a unified
#     framework context ($ctx).
#
# ARCHITECTURAL ROLE:
#     - Acts as the central scheduler for test execution in TAF.
#     - Consumes suite-provided callbacks (PreTestSetup, TestSetup, TestRun,
#       TestPost, TestCleanup, TestSuiteCleanup, GetDefaultTests, GetThreads,
#       GetLegalTests, GetReadmeMeta, StrictTestValidation).
#     - Drives:
#           * test enumeration (MainGetTests)
#           * thread selection (MainGetThreads)
#           * per-test loops (RunTests)
#           * per-thread loops (RunThreads)
#           * per-iteration loops (RunIterations)
#           * warmup runs (RunWarmupIteration)
#     - Manages result directory creation and run-counting for each iteration.
#     - Owns the lifecycle of iteration readme.txt files (WriteReadmeStart/
#       WriteReadmeEnd).
#     - Integrates with:
#           * TAF::Reports for report generation
#           * TAF::Archive for result archival
#           * TAF::Logging for stage and lifecycle tracing
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not implement workload logic; all actual test work is done by
#       suite callbacks in main::.
#     - Does not interpret database semantics or manage database lifecycles.
#     - Does not decide which tests are "correct" beyond suite-provided
#       validation (GetLegalTests/StrictTestValidation).
#     - Does not generate or modify archive structures directly
#       (delegates to TAF::Archive).
#     - Does not implement reporting logic (delegates to TAF::Reports and
#       report plugins).
#
# CONTRACT:
#     - Caller must provide a fully populated context hashref ($ctx) with:
#           ctx->{options} : framework options (tests, threads, iterations,
#                            warmup, sleep, paths, flags, etc.)
#           ctx->{dirs}    : directory paths (results_root_dir, results, etc.)
#           ctx->{files}   : file paths (run_count, readme, etc.)
#           ctx->{flags}   : run-time flags (archive_completed, etc.)
#           ctx->{obj}{date}
#                         : date/time object providing timing utilities
#           ctx->{state}   : internal run state (first_time_in_tests_loop,
#                            warmup_run_done, setup flags, etc.)
#           ctx->{tests}   : arrayref of test names (may be pre-populated or
#                            filled by MainGetTests)
#           ctx->{threads} : arrayref of thread counts (may be pre-populated
#                            or filled by MainGetThreads)
#     - Test suites must implement the following callbacks in main:::
#           PreTestSetup()
#           TestSetup($test, $thread, $iter, $results_dir)
#           TestRun($test, $thread, $iter, $runType, $results_dir)
#           TestPost($test, $thread, $iter, $results_dir)
#           TestCleanup()
#           TestSuiteCleanup()
#           GetDefaultTests()
#           GetThreads()
#           GetLegalTests()
#           StrictTestValidation()
#           GetReadmeMeta()
#           GetTestSuiteVersion()
#           GetTestSuiteRevision()
#           GetTestClientVersion()
#     - TAF::Archive and TAF::Reports must be available and correctly
#       configured in the environment.
#     - All failures must be explicit; no silent skips or implicit success.
#
# GUARANTEES:
#     - Test execution follows a deterministic order:
#           1. PreTestSetup (once per suite)
#           2. For each test:
#                a. RunThreads (for each thread count)
#                b. RunIterations (for each iteration)
#                     - optional warmup run
#                     - TestSetup (when required by options/state)
#                     - TestRun
#                     - TestPost
#                c. MainTestCleanup
#           3. MainTestSuiteCleanup (once per suite)
#     - Results subdirectories are created per test/thread/iteration using a
#       stable naming scheme that includes host, suite, test, run count,
#       iteration, and thread.
#     - Readme metadata is written at iteration start and end, producing a
#       complete, traceable record of each run.
#     - Reporting and archiving are invoked after each test completes, with
#       explicit error propagation on failure.
#
# NOTES:
#     - This module is central to TAF behavior and must remain stable; test
#       suites, reports, and archives depend on its sequencing and contracts.
#     - Any change in loop structure (tests, threads, iterations, warmup),
#       callback expectations, or directory layout must be reflected in this
#       header and in the TAF manual.
#     - All logging uses TAF::Logging for contributor-proof traceability of
#       every major stage and decision.
#############################################################################
#===============================================================================
#                            Imports
#===============================================================================
use Exporter 'import';
use File::Spec;
use File::Basename;
use strict;
use warnings;
use List::Util qw(max all);

BEGIN {
    require File::Basename;
    require File::Spec;

    my $here      = File::Spec->rel2abs(__FILE__);
    my $taf_libs  = File::Spec->catdir(File::Basename::dirname($here), File::Spec->updir);
    my $libs_root = File::Spec->catdir($taf_libs, File::Spec->updir);
    unshift @INC, $libs_root;
    

    my $sql_libs   = File::Spec->catdir($libs_root, "sql_libs");
    my $tools_dir  = File::Spec->catdir($libs_root, "script_tools_lib");

    unshift @INC, $taf_libs  unless grep { $_ eq $taf_libs } @INC;
    unshift @INC, $sql_libs  unless grep { $_ eq $sql_libs } @INC;
    unshift @INC, $tools_dir unless grep { $_ eq $tools_dir } @INC;

}

use sql_libs::Executor;
Executor->import(':all');

use TAF::Logging qw(PrintError
                    PrintHeader
                    PrintLine
                    PrintWarning
                    PrintVerbose
                    StageStart
                    StageEnd
                    TAFMsg);

require toolsLib;
use TAF::Archive;

use constant TAF_RUN => 'TAF::Run::';
our $VERSION = '2.0';

#===============================================================================
#                            Exports
#===============================================================================
our @EXPORT = qw(
    RunTests
);

#===============================================================================
#                            Constants
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
#                            Run Functions
#===============================================================================
#
# Subroutines implementing Run logic for TAF runs.
# Each routine follows contributor proof headers with
# explicit Purpose, Behavior, Parameters, and Returns.
#===============================================================================

#===============================================================================
#                            Exported Subs
#===============================================================================

#-----------------------------------------------------------------------------
# RunTests
#
# Purpose:
#   Orchestrate the full execution of a test suite under TAF. Handles test
#   discovery, thread loops, iteration loops, setup, cleanup, reporting, and
#   archiving using the unified context object ($ctx).
#
# Parameters:
#   $ctx : Framework context object.
#
# Behavior:
#   - Initializes state flags.
#   - Loads tests and thread counts (user-specified or suite defaults).
#   - Calls suite PreTestSetup() once before all tests.
#   - For each test:
#       * Resets per-test flags.
#       * Delegates to RunThreads() for thread/iteration execution.
#       * Runs cleanup, reporting, and archiving.
#   - Calls suite-level cleanup after all tests complete.
#
# Returns:
#   OK    : All tests completed successfully.
#   ERROR : Any stage failed.
#-----------------------------------------------------------------------------
sub RunTests {
    my ($ctx) = @_;

    # Break out ctx
    my $options = $ctx->{options};
    my $flags   = $ctx->{flags};
    my $obj     = $ctx->{obj};

    PrintHeader("== STAGE: RUN TESTS ============================","=",71);

    my $rth = StageStart(TAF_RUN."RunTests");
    $ctx->{state}{first_time_in_tests_loop} = TRUE;

    PrintVerbose($rth."TestSuite = ".$options->{test_suite});

    # Load tests and threads
    return ERROR if MainGetTests($ctx)   != OK;
    return ERROR if MainGetThreads($ctx) != OK;

    # Pre-test suite setup
    PrintHeader("== STAGE: PRE TEST SETUP ==========================","=",71);
    PrintVerbose($rth."Calling test suite's main::PreTestSetup()");
    return ERROR if main::PreTestSetup($ctx) != OK;

    # Test loop
    foreach my $test (@{$ctx->{tests}}) {
        PrintHeader("== STAGE: TEST LOOP STARTING ======================","=",71);
        PrintVerbose($rth."Current Test: $test");

        $flags->{archive_completed}     = FALSE;
        $ctx->{state}{warmup_run_done}  = FALSE;

        my $testTime = $obj->{date}->GetStartTime();

        # Thread loop
        return ERROR if RunThreads($ctx, $test) != OK;

        # Log elapsed time
        $testTime = $obj->{date}->FigureElapsedTimeFormatted($testTime);
        PrintVerbose($rth."$test -> Completed in $testTime");

        # Cleanup, reporting, archiving
        return ERROR if MainTestCleanup($ctx)              != OK;
        return ERROR if TAF::Reports::GenerateReport($ctx) != OK;
        return ERROR if TAF::Archive::ArchiveResults($ctx,$test) != OK;
    }

    # Suite-level cleanup
    PrintHeader("== STAGE: TEST SUITE CLEANUP ======================","=",71);
    return ERROR if MainTestSuiteCleanup($ctx) != OK;

    StageEnd($rth);
    return OK;
}

#===============================================================================
#                          Internal Subs
#===============================================================================

#===============================================================================
# RunTests
#
# PURPOSE:
#     Orchestrate the full execution of a test suite under TAF. Coordinates test
#     discovery, thread loops, iteration loops, setup, cleanup, reporting, and
#     archiving using the unified framework context ($ctx).
#
# PARAMETERS:
#     $ctx
#         Framework context object containing options, flags, objects, tests,
#         thread counts, and state.
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Initialize per-run state flags.
#     - Load test list and thread counts via MainGetTests() and MainGetThreads().
#     - Invoke main::PreTestSetup() once before all tests.
#     - For each test in the suite:
#           * Reset per-test state flags.
#           * Record start time.
#           * Execute the thread/iteration loop via RunThreads().
#           * Log elapsed time for the test.
#           * Perform cleanup via MainTestCleanup().
#           * Generate reports via TAF::Reports::GenerateReport().
#           * Archive results via TAF::Archive::ArchiveResults().
#     - After all tests complete, invoke MainTestSuiteCleanup().
#     - End the lifecycle stage and return OK.
#
# RETURNS:
#     OK
#         All tests completed successfully.
#
#     ERROR
#         Any stage failed (test discovery, setup, execution, cleanup,
#         reporting, or archiving).
#
# NOTES:
#     - Provides the top-level orchestration for the entire test lifecycle.
#     - Ensures contributor-proof sequencing and deterministic execution order.
#     - All subordinate routines are expected to follow the same lifecycle
#       discipline (StageStart/StageEnd, OK/ERROR contracts).
#===============================================================================
sub RunThreads {
    my ($ctx, $test) = @_;

    # Break out ctx
    my $threads = $ctx->{threads};

    PrintHeader("== STAGE: THREADS LOOP STARTING ===================","=",71);
    my $rt = StageStart(TAF_RUN."RunThreads");

    foreach my $thread (@$threads) {
        PrintVerbose($rt."Starting $test with $thread thread(s)...");
        PrintVerbose($rt."Calling RunIterations");
        return ERROR if RunIterations($ctx, $test, $thread) != OK;
    }

    StageEnd($rt);
    return OK;
}

#===============================================================================
# RunIterations
#
# PURPOSE:
#     Execute all iterations for a given test/thread combination. Coordinates
#     setup, optional warmup, main run, and post‑processing for each iteration,
#     producing a deterministic and contributor‑proof iteration lifecycle.
#
# PARAMETERS:
#     $ctx
#         Framework context object.
#
#     $test
#         Name of the test case being executed.
#
#     $thread
#         Thread count for the current run.
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Loop from 1 to $ctx->{options}{iterations}.
#     - For each iteration:
#           * Emit iteration header and verbose logging.
#           * Create the iteration results directory via MakeResultsSubDir().
#           * Validate that the directory exists.
#           * Invoke CheckTestSetup() to run or skip setup.
#           * If warmup has not yet been performed and warmup_duration is set,
#             execute RunWarmupIteration().
#           * Execute the main iteration via MainTestRun().
#           * Execute post‑processing via MainTestPost().
#           * Emit an iteration‑complete header.
#     - End the lifecycle stage and return OK.
#
# RETURNS:
#     OK
#         All iterations completed successfully.
#
#     ERROR
#         Any iteration failed (setup, warmup, run, or post‑processing).
#
# NOTES:
#     - Warmup is executed only once per test/thread combination.
#     - Results directory for each iteration is stored in $ctx->{dirs}{results}.
#     - All subordinate routines must follow OK/ERROR contracts.
#===============================================================================
sub RunIterations {
    my ($ctx, $test, $thread) = @_;

    # Break out ctx
    my $options = $ctx->{options};
    my $dirs    = $ctx->{dirs};
    my $obj     = $ctx->{obj};

    PrintHeader("== STAGE: ITERATIONS LOOP STARTING ================","=",71);
    my $ri = StageStart(TAF_RUN."RunIterations");

    my $iterations = $options->{iterations};

    for (my $iter = 1; $iter <= $iterations; $iter++) {

        my $header = GetIterationHeader("$test -> ", $thread, $iter);
        PrintVerbose($header." Starting iteration $iter of $iterations");

        # Create results directory for this iteration
        $dirs->{results} = MakeResultsSubDir($ctx, $test, $thread, $iter);

        if (!defined $dirs->{results} || !-d $dirs->{results}) {
            PrintError($header."Failed to find results directory after MakeResultsSubDir call!");
            return ERROR;
        }

        # Setup phase
        return ERROR if CheckTestSetup($ctx, $test, $thread, $iter) != OK;

        # Optional warmup
        if (!$ctx->{state}{warmup_run_done}
            && defined $options->{warmup_duration}) {

            return ERROR if RunWarmupIteration($ctx, $test, $thread, $iter) != OK;
        }

        # Main run
        return ERROR if MainTestRun($ctx, $test, $thread, $iter, "RUN") != OK;

        # Post-processing
        return ERROR if MainTestPost($ctx, $test, $thread, $iter) != OK;

        PrintHeader("== ITERATION: $iter COMPLETE ========================", "=", 71);
    }

    StageEnd($ri);
    return OK;
}

#===============================================================================
# RunWarmupIteration
#
# PURPOSE:
#     Execute a single warmup iteration before the main test runs. Ensures the
#     warmup lifecycle is isolated, traceable, and performed only once per
#     test/thread combination.
#
# PARAMETERS:
#     $ctx
#         Framework context object.
#
#     $test
#         Name of the test case being executed.
#
#     $thread
#         Thread count for the current run.
#
#     $iter
#         Iteration number within the test loop.
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Invoke MainTestRun() with runType "WARMUP".
#     - On success, mark warmup as completed in $ctx->{state}{warmup_run_done}.
#     - Emit contributor‑proof logging for visibility.
#     - End the lifecycle stage and return OK.
#
# RETURNS:
#     OK
#         Warmup run completed successfully.
#
#     ERROR
#         Warmup run failed.
#
# NOTES:
#     - Warmup is executed only once per test/thread combination.
#     - Caller is responsible for ensuring warmup_duration is defined when
#       warmup behavior is desired.
#===============================================================================
sub RunWarmupIteration {
    my ($ctx, $test, $thread, $iter) = @_;

    # Break out ctx
    my $state = $ctx->{state};

    PrintHeader("== STAGE: WARMUP RUN =============================", "=", 71);
    my $rw = StageStart(TAF_RUN."RunWarmupIteration");

    # Execute warmup run
    my $rc = MainTestRun($ctx, $test, $thread, $iter, "WARMUP");

    if ($rc != OK) {
        PrintError($rw."Warmup run failed for $test (thread $thread, iter $iter)");
        return ERROR;
    }

    # Mark warmup as completed
    $state->{warmup_run_done} = TRUE;

    StageEnd($rw);
    return OK;
}

#===============================================================================
# CheckTestSetup
#
# PURPOSE:
#     Determine whether test setup should run for the current iteration. Ensures
#     setup is executed once per test loop unless explicitly overridden by
#     framework options.
#
# PARAMETERS:
#     $ctx
#         Framework context object.
#
#     $test
#         Test name.
#
#     $thread
#         Thread count for the current run.
#
#     $iter
#         Iteration number.
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Read skip_test_setup and do_test_setup_every_test options.
#     - When setup is not skipped:
#           * Run MainTestSetup() if:
#                 - This is the first time in the test loop AND setup has not
#                   yet been performed, OR
#                 - The user forces setup every iteration.
#           * Update state flags:
#                 first_time_in_tests_loop
#                 initial_test_setup_done
#     - When setup is skipped:
#           * Emit a warning only once per test loop.
#     - End the lifecycle stage and return OK.
#
# RETURNS:
#     OK
#         Setup executed or skipped successfully.
#
#     ERROR
#         MainTestSetup() failed.
#
# NOTES:
#     - Ensures contributor-proof, deterministic setup behavior.
#     - Caller is responsible for invoking this once per iteration.
#===============================================================================
sub CheckTestSetup {
    my ($ctx, $test, $thread, $iter) = @_;

    PrintHeader("== STAGE: CHECK TEST SETUP =======================", "=", 71);
    my $ct = StageStart(TAF_RUN."CheckTestSetup");

    # Break out ctx
    my $state   = $ctx->{state};
    my $options = $ctx->{options};

    my $skip        = $options->{skip_test_setup};
    my $setup_every = $options->{do_test_setup_every_test};

    if (!$skip) {

        # Run setup if:
        #   - first time in test loop AND setup not yet done
        #   - OR user forces setup every iteration
        if (($state->{first_time_in_tests_loop} && !$state->{initial_test_setup_done})
            || $setup_every) {

            $state->{first_time_in_tests_loop} = FALSE;

            PrintVerbose($ct."Calling MainTestSetup");
            return ERROR if MainTestSetup($ctx, $test, $thread, $iter) != OK;

            $state->{initial_test_setup_done} = TRUE;
        }
    }
    else {
        # Only warn once per test loop
        unless ($state->{skip_test_setup_warned}) {
            PrintWarning($ct."Skip TestSetup detected. TestSetup will be skipped.");
            $state->{skip_test_setup_warned} = TRUE;
        }
    }

    StageEnd($ct);
    return OK;
}

#===============================================================================
# MainTestSetup
#
# PURPOSE:
#     Execute the test suite's TestSetup() routine for the current
#     test/thread/iteration. Provides lifecycle logging, timing, and optional
#     post-setup sleep to ensure deterministic and contributor-proof behavior.
#
# PARAMETERS:
#     $ctx
#         Framework context object.
#
#     $test
#         Test name.
#
#     $thread
#         Thread count for the current run.
#
#     $iter
#         Iteration number.
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Break out context components (dirs, options, date utilities).
#     - Capture start time and formatted date/time.
#     - Delegate setup to the test suite via main::TestSetup().
#     - On success:
#           * Compute elapsed time.
#           * Log end timestamp and duration.
#           * Perform optional post-setup sleep if configured.
#     - End the lifecycle stage and return OK.
#
# RETURNS:
#     OK
#         TestSetup completed successfully.
#
#     ERROR
#         TestSetup returned ERROR.
#
# NOTES:
#     - Does not modify state flags; caller controls setup gating.
#     - Duration logging uses the date utility in $ctx->{obj}{date}.
#     - Results directory for the iteration must already be established.
#===============================================================================
sub MainTestSetup {
    my ($ctx, $test, $thread, $iter) = @_;

    PrintHeader("== STAGE: TEST SETUP ==============================", "=", 71);
    my $mts  = StageStart(TAF_RUN."MainTestSetup");
    my $mts2 = $mts."$test -> Thread(s): $thread -> Iter: $iter -> ";

    # Break out ctx
    my $dirs = $ctx->{dirs};
    my $opts = $ctx->{options};
    my $date = $ctx->{obj}{date};

    my $results_dir = $dirs->{results};
    
    # Check to see if SQL File to run
    return ERROR if MaybeExecuteSqlHook($ctx, "exec_sql_file_before_test_setup", $results_dir) != OK;

    # Capture start time
    my $startTime     = $date->GetStartTime();
    my $startDateTime = $date->GetDateTime();

    PrintVerbose("$mts2 Start date/time: $startDateTime");
    PrintVerbose("$mts2 Calling test suite's main::TestSetup");

    # Delegate to suite TestSetup
    my $rc = main::TestSetup($test, $thread, $iter, $results_dir);
    return ERROR if $rc != OK;

    # Compute elapsed time
    my $elapsed     = $date->FigureElapsedTimeSeconds($startTime);
    my $endDateTime = $date->GetDateTime();

    PrintVerbose("$mts2 End date/time:   $endDateTime");
    PrintVerbose("$mts2 Duration:        $elapsed seconds");

    # Optional post-setup sleep
    CheckDbRestOrSleep($ctx,$mts2."sleep_after_test_setup", $opts->{sleep_after_test_setup});

    # Check to see if SQL File to run
    return ERROR if MaybeExecuteSqlHook($ctx, "exec_sql_file_after_test_setup", $results_dir) != OK;

    StageEnd($mts);
    return OK;
}

#===============================================================================
# MainTestRun
#
# PURPOSE:
#     Execute a single test iteration (RUN or WARMUP). Handles readme metadata,
#     lifecycle logging, timing, pre/post run sleeps, and delegation to the
#     test suite's TestRun() routine.
#
# PARAMETERS:
#     $ctx
#         Framework context object.
#
#     $test
#         Test name.
#
#     $thread
#         Thread count for the current run.
#
#     $iter
#         Iteration number.
#
#     $runType
#         Either "RUN" or "WARMUP".
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - For non-warmup runs:
#           * Write initial readme metadata via WriteReadmeStart().
#           * Log run details (host, duration, results directory, timestamp).
#     - Capture start time for duration measurement.
#     - Emit a RUN stage header.
#     - Perform optional pre-run sleep (sleep_before_test_run).
#     - Delegate execution to main::TestRun().
#     - Compute elapsed run duration.
#     - For non-warmup runs:
#           * Finalize readme via WriteReadmeEnd().
#     - Perform optional post-run sleep (sleep_after_test_run).
#     - End the lifecycle stage and return OK.
#
# RETURNS:
#     OK
#         TestRun completed successfully.
#
#     ERROR
#         TestRun returned ERROR.
#
# NOTES:
#     - Warmup runs skip all readme generation.
#     - Results directory for the iteration must already be established.
#     - Duration logging uses the date utility in $ctx->{obj}{date}.
#===============================================================================
sub MainTestRun {
    my ($ctx, $test, $thread, $iter, $runType) = @_;

    # Break out ctx
    my $dirs    = $ctx->{dirs};
    my $obj     = $ctx->{obj};
    my $opts    = $ctx->{options};
    my $taf_vars = $ctx->{taf_var};   # kept for future-proofing; not used here

    my $resultsSubDir = $dirs->{results};

    PrintHeader("== STAGE: MAIN TEST RUN ==========================", "=", 71);
    my $mtr  = StageStart(TAF_RUN."MainTestRun");
    my $mtr2 = $mtr."$test -> Thread(s): $thread -> Iter: $iter -> ";

    # Non-warmup:
    if (uc($runType) ne 'WARMUP') {
        # write readme start metadata
        PrintVerbose($mtr2."Generating first part of runs readme.txt");
        WriteReadmeStart($ctx, $test, $thread, $iter);

        my $dateTime = $obj->{date}->GetDateTime();

        PrintVerbose($mtr2."Print Run details to log");
        PrintTestRunDetails($test,
                            $thread,
                            $iter,
                            $opts->{host},
                            $resultsSubDir,
                            $opts->{duration},
                            $dateTime);

        # Check to see if SQL File to run
        return ERROR if MaybeExecuteSqlHook($ctx, "exec_sql_file_before_run_iter", $resultsSubDir) != OK;
    }

    # Run stage
    my $startTime = $obj->{date}->GetStartTime();
    PrintHeader("== STAGE: RUN ====================================", "=", 71);

    SleepWithLog($mtr2."sleep_before_test_run", $opts->{sleep_before_test_run});

    PrintVerbose($mtr2."Calling test suite's main::TestRun");
    my $returnCode = main::TestRun($test, $thread, $iter, $runType, $resultsSubDir);

    my $runDuration = $obj->{date}->FigureElapsedTimeSeconds($startTime);
    PrintVerbose($mtr2."Iteration run time in seconds: ".$runDuration);

    # Non-warmup: finalize readme
    if (uc($runType) ne 'WARMUP') {
        # finalize readme
        PrintVerbose($mtr2."Generating last part of runs readme.txt");
        WriteReadmeEnd($ctx, $runDuration);

        # Check to see if SQL File to run
        return ERROR if MaybeExecuteSqlHook($ctx, "exec_sql_file_after_run_iter", $resultsSubDir) != OK;
    }

    # Check return
    if ($returnCode != OK) {
        PrintError($mtr2."TestRun failed");
        return ERROR;
    }

    # Check for break between
    CheckDbRestOrSleep($ctx,$mtr2."sleep_after_test_run", $opts->{sleep_after_test_run});

    StageEnd($mtr);
    return OK;
}

#===============================================================================
# MainTestPost
#
# PURPOSE:
#     Execute the post-processing stage for a single iteration. Allows the test
#     suite to finalize results or update artifacts, with contributor-proof
#     visibility into skip/run behavior.
#
# PARAMETERS:
#     $ctx
#         Framework context object.
#
#     $test
#         Test name.
#
#     $thread
#         Thread count for the current run.
#
#     $iter
#         Iteration number.
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Read skip_test_post from $ctx->{options}.
#     - When not skipped:
#           * Invoke main::TestPost() with iteration-specific arguments.
#           * Return ERROR if the suite reports failure.
#     - When skipped:
#           * Emit contributor-proof verbose logging.
#     - End the lifecycle stage and return OK.
#
# RETURNS:
#     OK
#         Post-processing completed or intentionally skipped.
#
#     ERROR
#         TestPost returned ERROR.
#
# NOTES:
#     - Results directory for the iteration is passed directly to TestPost().
#     - Caller is responsible for invoking this once per iteration.
#===============================================================================
sub MainTestPost {
    my ($ctx, $test, $thread, $iter) = @_;

    PrintHeader("== STAGE: TEST POST ==============================", "=", 71);
    my $mtp  = StageStart(TAF_RUN."MainTestPost");
    my $mtp2 = $mtp." $test -> Thread(s): $thread -> Iter: $iter -> ";

    # Break out ctx
    my $opts = $ctx->{options};
    my $dirs = $ctx->{dirs};

    # Run post-processing unless skipped
    if (!$opts->{skip_test_post}) {
        PrintVerbose($mtp2."Calling test suite's main::TestPost().");
        return ERROR if main::TestPost($test, $thread, $iter, $dirs->{results}) != OK;
    }
    else {
        PrintVerbose($mtp2."Skip Test Post detected. Test Post will be skipped.");
    }

    StageEnd($mtp);
    return OK;
}

#===============================================================================
# MainTestCleanup
#
# PURPOSE:
#     Execute cleanup for a single test after all iterations complete. Delegates
#     to the test suite's TestCleanup() routine unless explicitly skipped by
#     framework options.
#
# PARAMETERS:
#     $ctx
#         Framework context object.
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Read skip_test_cleanup from $ctx->{options}.
#     - When not skipped:
#           * Invoke main::TestCleanup().
#           * Return ERROR if the suite reports failure.
#     - When skipped:
#           * Emit contributor-proof verbose logging.
#     - End the lifecycle stage and return OK.
#
# RETURNS:
#     OK
#         Cleanup completed or intentionally skipped.
#
#     ERROR
#         TestCleanup returned ERROR.
#
# NOTES:
#     - Cleanup is executed once per test, after all iterations finish.
#     - Caller is responsible for invoking this at the correct point in the
#       lifecycle (typically after RunIterations).
#===============================================================================
sub MainTestCleanup {
    my ($ctx) = @_;

    PrintHeader("== STAGE: TEST CLEAN UP =========================", "=", 71);
    my $mtc = StageStart(TAF_RUN."MainTestCleanup");

    # Break out ctx
    my $opts = $ctx->{options};

    # Run cleanup unless skipped
    if (!$opts->{skip_test_cleanup}) {
        PrintVerbose($mtc."Calling test suite's main::TestCleanup().");
        return ERROR if main::TestCleanup() != OK;
    }
    else {
        PrintVerbose($mtc."Skip Test Cleanup detected. Test Cleanup will be skipped.");
    }

    StageEnd($mtc);
    return OK;
}

#===============================================================================
# MainTestSuiteCleanup
#
# PURPOSE:
#     Execute suite-level cleanup after all tests have finished. Delegates to the
#     test suite's TestSuiteCleanup() routine unless explicitly skipped by
#     framework options.
#
# PARAMETERS:
#     $ctx
#         Framework context object.
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Read skip_test_suite_cleanup from $ctx->{options}.
#     - When not skipped:
#           * Invoke main::TestSuiteCleanup().
#           * Return ERROR if the suite reports failure.
#     - When skipped:
#           * Emit contributor-proof verbose logging.
#     - End the lifecycle stage and return OK.
#
# RETURNS:
#     OK
#         Suite-level cleanup completed or intentionally skipped.
#
#     ERROR
#         TestSuiteCleanup returned ERROR.
#
# NOTES:
#     - Suite-level cleanup is executed once after all tests and iterations
#       have completed.
#     - Caller is responsible for invoking this at the correct point in the
#       overall test lifecycle.
#===============================================================================
sub MainTestSuiteCleanup {
    my ($ctx) = @_;

    PrintHeader("== STAGE: TEST SUITE CLEAN UP ===================", "=", 71);
    my $mtsc = StageStart(TAF_RUN."MainTestSuiteCleanup");

    # Break out ctx
    my $opts = $ctx->{options};

    # Run suite-level cleanup unless skipped
    if (!$opts->{skip_test_suite_cleanup}) {
        PrintVerbose($mtsc."Calling test suite's main::TestSuiteCleanup().");
        return ERROR if main::TestSuiteCleanup() != OK;
    }
    else {
        PrintVerbose($mtsc."Skip Test Suite Cleanup detected. Test Suite Cleanup will be skipped.");
    }

    StageEnd($mtsc);
    return OK;
}

#===============================================================================
# MainGetTests
#
# PURPOSE:
#     Populate ctx->{tests} with either user-specified tests or suite defaults.
#     Ensures the resulting list is valid, non-empty, and contributor-proof
#     before the test lifecycle proceeds.
#
# PARAMETERS:
#     $ctx
#         Framework context object.
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Break out ctx->{tests}.
#     - When user-specified tests are present:
#           * Validate them via CheckForLegalTests().
#     - When no tests are provided:
#           * Retrieve defaults via main::GetDefaultTests().
#           * Validate that the returned list is a non-empty arrayref.
#           * Append defaults into ctx->{tests}.
#     - Emit verbose logging for visibility.
#     - End the lifecycle stage and return OK.
#
# RETURNS:
#     OK
#         Tests loaded successfully.
#
#     ERROR
#         Validation failure or suite default retrieval failure.
#
# NOTES:
#     - Guarantees that ctx->{tests} is populated before thread and iteration
#       loops begin.
#     - All validation follows the OK/ERROR contract used throughout TAF.
#===============================================================================
sub MainGetTests {
    my ($ctx) = @_;

    PrintHeader("== STAGE: GET TESTS =============================", "=", 71);
    my $mgt = StageStart(TAF_RUN."MainGetTests");

    # Break out ctx
    my $tests = $ctx->{tests};

    # User-specified tests
    if (@$tests) {
        PrintVerbose($mgt."Using user-specified tests");
        return ERROR if CheckForLegalTests($ctx) != OK;
    }
    else {
        # Retrieve defaults from suite
        PrintWarning($mgt."No tests provided; retrieving defaults from suite");
        my $default = main::GetDefaultTests();

        unless (defined $default && ref($default) eq 'ARRAY' && @$default) {
            PrintError($mgt."Suite did not return a valid default test list");
            return ERROR;
        }

        push @$tests, @$default;
        PrintVerbose($mgt."Added default tests: ".join(", ", @$tests));
    }

    StageEnd($mgt);
    return OK;
}

#===============================================================================
# MainGetThreads
#
# PURPOSE:
#     Populate ctx->{threads} with either user-specified thread counts or suite
#     defaults. Ensures the resulting list is valid, numeric, and contributor-
#     proof before execution proceeds.
#
# PARAMETERS:
#     $ctx
#         Framework context object.
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Break out ctx->{threads}.
#     - When user-provided thread counts exist:
#           * Emit verbose logging.
#           * Validate that all values are defined and numeric.
#     - When no thread counts are provided:
#           * Emit a warning.
#           * Retrieve defaults via main::GetThreads().
#           * Validate that the returned list is a non-empty arrayref.
#           * Assign defaults into ctx->{threads}.
#     - End the lifecycle stage and return OK.
#
# RETURNS:
#     OK
#         Threads successfully populated and validated.
#
#     ERROR
#         Validation failure or suite default retrieval failure.
#
# NOTES:
#     - Guarantees that ctx->{threads} is populated before RunThreads() begins.
#     - All validation follows the OK/ERROR contract used throughout TAF.
#===============================================================================
sub MainGetThreads {
    my ($ctx) = @_;

    my $mgth = StageStart(TAF_RUN."MainGetThreads");

    # Break out ctx
    my $threads = $ctx->{threads};

    # User-provided threads
    if (@$threads) {
        PrintVerbose($mgth."Threads provided: ".join(", ", @$threads));

        # Validate numeric thread values
        return ERROR unless List::Util::all { defined $_ && $_ =~ /^\d+$/ } @$threads;
    }
    else {
        # Retrieve defaults from suite
        PrintWarning($mgth."No threads provided, calling test suite's main::GetThreads()");
        my $tmpGetThreads = main::GetThreads();

        if (defined $tmpGetThreads && ref($tmpGetThreads) eq 'ARRAY') {
            @$threads = @$tmpGetThreads;
            PrintVerbose($mgth."Added threads: ".join(", ", @$threads));
        }
        else {
            PrintError($mgth."Failed to retrieve threads from test suite.");
            return ERROR;
        }
    }

    StageEnd($mgth);
    return OK;
}

#===============================================================================
# GetIterationHeader
#
# PURPOSE:
#     Build a formatted header string for iteration logging. Provides clear,
#     contributor-proof context when printing iteration progress.
#
# PARAMETERS:
#     $prefix
#         String prefix to prepend (typically includes test name or context).
#
#     $thread
#         Thread count for the current run.
#
#     $iter
#         Iteration number within the test loop.
#
# BEHAVIOR:
#     - Concatenate prefix, thread count, and iteration number.
#     - Produce a string in the format:
#           "<prefix>Thread(s): <thread> -> Iter: <iter> -> "
#
# RETURNS:
#     String
#         Formatted iteration header.
#
# NOTES:
#     - Internal helper, not exported.
#     - Lightweight utility with no lifecycle logging.
#===============================================================================
sub GetIterationHeader {
    my ($prefix, $thread, $iter) = @_;
    return $prefix."Thread(s): ".$thread." -> Iter: ".$iter." -> ";
}

#===============================================================================
# SleepWithLog
#
# PURPOSE:
#     Pause execution for a specified number of seconds while emitting
#     contributor-proof logging of the action. Provides deterministic visibility
#     into intentional delays during test setup or run phases.
#
# PARAMETERS:
#     $prefix
#         String prefix used in log messages for context.
#
#     $seconds
#         Number of seconds to sleep (integer). Must be defined and >= ZERO.
#
# BEHAVIOR:
#     - When $seconds is defined and >= ZERO:
#           * Emit a verbose log entry indicating the sleep duration.
#           * Call Perl's sleep() for the specified number of seconds.
#     - Otherwise:
#           * Emit an error indicating that the sleep duration is invalid.
#
# RETURNS:
#     None
#         This routine does not return a value.
#
# NOTES:
#     - Internal helper, not exported.
#     - Uses the ZERO constant for contributor-proof clarity.
#     - Lightweight utility with no lifecycle stage management.
#===============================================================================
sub SleepWithLog {
    my ($prefix, $seconds) = @_;

    if (defined $seconds && $seconds >= ZERO) {
        PrintVerbose("$prefix Sleeping for $seconds seconds");
        sleep($seconds);
    }
    else {
        PrintError("SleepWithLog for $prefix seconds to sleep not defined or <= ZERO");
    }
}

#===============================================================================
# WriteReadmeStart
#
# PURPOSE:
#     Initialize and populate the iteration's README file with metadata about the
#     current test run, framework, host, and database environment. Establishes a
#     contributor-proof, structured record of run context before the iteration
#     begins.
#
# PARAMETERS:
#     $ctx
#         Framework context object.
#
#     $test
#         Name of the test being executed.
#
#     $thread
#         Number of threads used for the test.
#
#     $iter
#         Iteration number of the test run.
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Normalize the results directory path to ensure a trailing slash.
#     - Construct the readme.txt path and initialize the readme logger via
#       TAF::Logging::LoggerSetup().
#     - Log run timestamps (date and time).
#     - Log framework metadata (framework name, version, revision, commandline).
#     - Log test metadata (suite, version, revision, client version, name, type,
#       comments, duration, iteration, thread counts, warmup settings).
#     - Log host metadata (OS, kernel, CPU, cores, sockets, RAM, architecture).
#     - Log database metadata (maker, version, install dir, engine, port, socket,
#       users).
#     - Retrieve and log suite-specific metadata via main::GetReadmeMeta().
#     - End the lifecycle stage.
#
# RETURNS:
#     None
#         This routine does not return a value.
#
# NOTES:
#     - Internal helper, not exported.
#     - Relies on TAF::Logging::LoggerSetup to create the readme_writer object.
#     - Uses TAF::Utilities::EnsureTrailingPm to normalize suite file names.
#     - All formatting widths are computed dynamically for aligned output.
#===============================================================================
sub WriteReadmeStart {
    my ($ctx, $test, $thread, $iter) = @_;

    my $wrass = StageStart(TAF_RUN."WriteReadmeStart");

    # Break out ctx
    my $dirs    = $ctx->{dirs};
    my $files   = $ctx->{files};
    my $obj     = $ctx->{obj};
    my $opts    = $ctx->{options};
    my $taf_vars = $ctx->{taf_var};


    # Setup readme path + logger
    $dirs->{results}  = TAF::Utilities::TrailingSlash($dirs->{results});
    $files->{read_me} = $dirs->{results} . "readme.txt";
    $ctx->{readme}    = TAF::Logging::LoggerSetup($files->{read_me});

    PrintVerbose("$wrass Started gathering details information for iteration.");
    PrintVerbose("$wrass Location: $files->{read_me}");

    # Time information
    my $dateTime = $obj->{date}->GetDateTime();
    my $time     = $obj->{date}->GetTime();

    my @run_labels = (
        ["Date of Test", $dateTime],
        ["Time of Test", $time],
    );

    my $run_width = List::Util::max(map { length($_->[0]) } @run_labels);

    foreach my $pair (@run_labels) {
        my ($label, $val) = @$pair;
        $ctx->{readme}->LogMessage(sprintf("%-*s %s", $run_width+1, $label . ":", $val));
    }

    # Framework details
    my @fw_labels = (
        ["Framework",         $taf_vars->{framework}],
        ["Framework Version", $taf_vars->{framework_ver}],
        ["Framework Rev",     $taf_vars->{framework_rev}],
        ["TAF Commandline",   $taf_vars->{upd_cmdline}],
    );

    my $fw_width = List::Util::max(map { length($_->[0]) } @fw_labels);

    foreach my $pair (@fw_labels) {
        my ($label, $val) = @$pair;
        $ctx->{readme}->LogMessage(sprintf("%-*s %s", $fw_width+1, $label . ":", $val));
    }

    # Test details
    my @test_labels = (
        ["Test Suite",          $opts->{test_suite}],
        ["Test Suite PM File",  TAF::Utilities::EnsureTrailingPm($opts->{test_suite})],
        ["Test Suite Version",  main::GetTestSuiteVersion()],
        ["Test Suite Revision", main::GetTestSuiteRevision()],
        ["Test Client Version", main::GetTestClientVersion()],
        ["Test Name",           $test],
        ["Test Type",           $opts->{test_type}],
        ["Comments",            $opts->{comments}],
        ["Duration",            $opts->{duration}],
        ["Iteration",           $iter],
        ["Threads",             $thread],
        ["Warmup Threads",      $opts->{warmup_threads}],
        ["Warmup Duration",     $opts->{warmup_duration}],
    );

    my $test_width = List::Util::max(map { length($_->[0]) } @test_labels);

    foreach my $pair (@test_labels) {
        my ($label, $val) = @$pair;
        next unless defined $val && $val ne '';
        $ctx->{readme}->LogMessage(sprintf("%-*s %s", $test_width+1, $label . ":", $val));
    }

    # Host details
    my @host_labels = (
        ["Test Host",  $opts->{host}],
        ["OS",         toolsLib::GetSystemOSType()],
        ["OS Version", toolsLib::GetSystemOSVersion()],
        ["OS Arch",    toolsLib::GetSystemArch()],
        ["OS Kernel",  toolsLib::GetSystemKernel()],
        ["CPU",        toolsLib::GetSystemCpu()],
        ["CPU COUNT",  toolsLib::GetSystemCpuCount()],
        ["CORE COUNT", toolsLib::GetSystemCoreCount()],
        ["SOCKET COUNT", toolsLib::GetSystemSocketCount()],
        ["RAM",        toolsLib::GetSystemMemory()],
    );

    my $host_width = List::Util::max(map { length($_->[0]) } @host_labels);

    foreach my $pair (@host_labels) {
        my ($label, $val) = @$pair;
        $ctx->{readme}->LogMessage(sprintf("%-*s %s", $host_width+1, $label . ":", $val));
    }

    # Database details
    my @db_labels = (
        ["Database Maker",      $taf_vars->{db_maker}],
        ["Database Version",    sql_libs::Executor::DbGetVersion($ctx)],
        ["DB Install Dir",      $opts->{db_software_install_dir}],
        ["Database Under Test", $opts->{database}],
        ["Database Eng",        $opts->{db_engine}],
        ["Port",                $opts->{db_port}],
        ["Socket",              $opts->{db_socket}],
        ["DB Root User",        $opts->{db_root_user}],
        ["DB User",             $opts->{db_user}],
    );

    my $db_width = List::Util::max(map { length($_->[0]) } @db_labels);

   foreach my $pair (@db_labels) {
       my ($label, $val) = @$pair;

       if (defined $val) {
           $ctx->{readme}->LogMessage(
               sprintf("%-*s %s", $db_width+1, $label . ":", $val)
           );
           next;
       }
   }

    # Test suite metadata
    PrintVerbose("$wrass Calling test suite's main::GetReadmeMeta()");
    my $meta = eval { main::GetReadmeMeta() };
    if ($@) {
        PrintError("Test suite missing required sub GetReadmeMeta()");
        die $@;
    }

    my $meta_width = List::Util::max(map { length($_) } keys %$meta);

    foreach my $key (sort keys %$meta) {
        my $label = ucfirst($key) . ":";
        $ctx->{readme}->LogMessage(sprintf("%-*s %s", $meta_width+1, $label, $meta->{$key}));
    }

    StageEnd($wrass);
    return;
}

#===============================================================================
# WriteReadmeEnd
#
# PURPOSE:
#     Finalize the iteration's readme.txt by writing end-of-run metadata and
#     closing out the readme writer stored in $ctx->{readme}. Completes the
#     contributor-proof record of the iteration.
#
# PARAMETERS:
#     $ctx
#         Framework context object.
#
#     $duration
#         Total run duration in seconds for this iteration.
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Break out the readme writer and date utility from the context.
#     - When the readme writer is initialized:
#           * Log run duration and end timestamp.
#           * Emit a final "_EOF_" marker for completeness.
#     - When the readme writer is missing:
#           * Emit a warning indicating that no write will occur.
#     - End the lifecycle stage.
#
# RETURNS:
#     None
#         This routine does not return a value. Errors are logged but do not
#         throw exceptions.
#
# NOTES:
#     - Internal helper, not exported.
#     - Completes the readme.txt lifecycle started by WriteReadmeStart().
#     - All formatting widths are computed dynamically for aligned output.
#===============================================================================
sub WriteReadmeEnd {
    my ($ctx, $duration) = @_;

    my $wreass = StageStart(TAF_RUN."WriteReadmeEnd");

    # Break out ctx
    my $writer = $ctx->{readme};
    my $date   = $ctx->{obj}{date};

    PrintVerbose("$wreass Finishing up readme.txt");

    if (defined $writer) {
        my @end_labels = (
            ["Run Duration Seconds", $duration],
            ["Test End Date Time",   $date->GetDateTime()],
        );

        my $end_width = List::Util::max(map { length($_->[0]) } @end_labels);

        foreach my $pair (@end_labels) {
            my ($label, $val) = @$pair;
            $writer->LogMessage(sprintf("%-*s %s", $end_width+1, $label . ":", $val));
        }

        $writer->LogMessage(" _EOF_");
    }
    else {
        PrintWarning("$wreass readme_writer not initialized - skipping log write");
    }

    StageEnd($wreass);
    return;
}

#===============================================================================
# PrintTestRunDetails
#
# PURPOSE:
#     Display key details about the current test run in a formatted, contributor-
#     proof block. Provides clear visibility into run context for logs and
#     debugging.
#
# PARAMETERS:
#     $test
#         Name of the test being executed.
#
#     $thread
#         Number of threads used for the test.
#
#     $iter
#         Iteration number of the test run.
#
#     $host
#         Host name or identifier for the run.
#
#     $results_dir
#         Path to the results directory for this iteration.
#
#     $duration
#         Duration of the test run in seconds.
#
#     $dateTime
#         Timestamp string for when the run started.
#
# BEHAVIOR:
#     - Print separator lines before and after the details block.
#     - Emit a "TEST RUN DETAILS:" header.
#     - Log date/time, host, results directory, test name, thread count,
#       iteration number, and duration.
#     - Use "N/A" as a fallback for undefined values.
#
# RETURNS:
#     None
#         This routine does not return a value.
#
# NOTES:
#     - Internal helper, not exported.
#     - Relies on PrintLine() and PrintVerbose() for consistent contributor-
#       proof output.
#     - $dateTime is expected to come from the framework date utility.
#===============================================================================
sub PrintTestRunDetails {
    my ($test, $thread, $iter, $host, $results_dir,$duration, $dateTime) = @_;

    PrintLine("-", 60);
    PrintVerbose("TEST RUN DETAILS:");
    PrintLine("-", 60);

    PrintVerbose("DATE:                 " . ($dateTime    // "N/A"));
    PrintVerbose("HOST:                 " . ($host        // "N/A"));
    PrintVerbose("LOCAL RESULT DIR:     " . ($results_dir // "N/A"));
    PrintVerbose("TEST_NAME:            " . ($test        // "N/A"));
    PrintVerbose("THREADS:              " . ($thread      // "N/A"));
    PrintVerbose("TEST ITERATION:       " . ($iter        // "N/A"));
    PrintVerbose("DURATION:             " . ($duration    // "N/A"));

    PrintLine("-", 60);
}

#===============================================================================
# CheckForLegalTests
#
# PURPOSE:
#     Validate each test in ctx->{tests} against the suite's list of legal tests.
#     Enforces contributor-proof discipline by honoring strict or non-strict
#     validation modes defined by the test suite.
#
# PARAMETERS:
#     $ctx
#         Framework context object (contains tests array and suite context).
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Retrieve legal tests via main::GetLegalTests().
#     - Normalize legal test names to lowercase for comparison.
#     - For each test in ctx->{tests}:
#           * If found in the legal list:
#                 - Emit verbose confirmation.
#           * If not found and StrictTestValidation() is FALSE:
#                 - Emit verbose confirmation of non-strict mode.
#                 - Emit a warning and allow the unknown test.
#           * If not found and StrictTestValidation() is TRUE:
#                 - Emit an error.
#                 - Emit the list of legal tests.
#                 - Return ERROR.
#     - End the lifecycle stage and return OK.
#
# RETURNS:
#     OK
#         All tests are valid or allowed under non-strict validation mode.
#
#     ERROR
#         Any test is invalid and strict validation is enabled.
#
# NOTES:
#     - Internal helper, not exported.
#     - Uses ctx->{tests} as the canonical source of test names.
#     - Contributor-proof discipline: explicit errors, no silent skips.
#===============================================================================
sub CheckForLegalTests {
     my ($ctx) = @_;
     my $cflt = StageStart(TAF_RUN."CheckForLegalTests");

    PrintVerbose($cflt . "Calling test suite's main::GetLegalTests()");
    my $legal_tests_ref = main::GetLegalTests();
    my %legal_tests = map { lc($_) => 1 } @$legal_tests_ref;

    foreach my $testIn (@{$ctx->{tests}}) {
        my $test_lc = lc($testIn);
        PrintVerbose($cflt . "Checking if '$testIn' is a legal test");

        if (exists $legal_tests{$test_lc}) {
            PrintVerbose($cflt . "'$testIn' found");
            next;
        }

        # Warnings
        PrintVerbose($cflt . "Calling test suites main::StrictTestValidation()");
        if (!main::StrictTestValidation()) {
            PrintVerbose($cflt . "Strict Test Validation = FALSE");
            PrintWarning($cflt . "Test '$testIn' unknown, proceeding anyway");
            next;
        }

        # Invalid test and strict validation is enabled
        PrintError($cflt . "'$testIn' NOT FOUND!!");
        PrintVerbose($cflt . "Legal tests for suite: ");
        PrintVerbose($_) for @$legal_tests_ref;
        return ERROR;
    }

    StageEnd($cflt);
    return OK;
}

#===============================================================================
# MakeResultsSubDir
#
# PURPOSE:
#     Construct and create a results subdirectory for a given
#     test/thread/iteration. Produces a deterministic, contributor-proof
#     directory name incorporating host, suite, test, run count, iteration, and
#     thread.
#
# PARAMETERS:
#     $ctx
#         Framework context object.
#
#     $test
#         Test name.
#
#     $thread
#         Thread count.
#
#     $iter
#         Iteration identifier.
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Break out options, dirs, and files from the context.
#     - Validate required options:
#           * results_root_dir
#           * test_suite
#     - Retrieve host name (fallback to "UNKNOWN_SERVER").
#     - Retrieve run count via GetRunCount().
#     - Construct the leaf directory name using:
#           host, test_suite, test, runCount, iter, thread
#     - Build the full directory path under results_root_dir.
#     - Attempt to create the directory; return undef on failure.
#     - Normalize the final path to include a trailing slash.
#     - End the lifecycle stage and return the directory path.
#
# RETURNS:
#     String
#         Path of the created results directory (with trailing slash).
#
#     undef
#         Validation failure or directory creation failure.
#
# NOTES:
#     - Caller is responsible for assigning the returned path into
#       ctx->{dirs}{results} before invoking any run-stage routines.
#     - Directory naming is intentionally explicit to ensure contributor-proof
#       traceability across hosts and runs.
#===============================================================================
sub MakeResultsSubDir {
    my ($ctx, $test, $thread, $iter) = @_;

    my $mrsd = StageStart(TAF_RUN."MakeResultsSubDir");

    my $options = $ctx->{options};
    my $dirs    = $ctx->{dirs};
    my $files   = $ctx->{files};

    my $results_root_dir = $options->{results_root_dir};
    my $test_suite       = $options->{test_suite};
    my $host             = TAF::Utilities::GetHostName($options->{host});

    # Normalize host
    $host = "UNKNOWN_SERVER" unless defined $host && $host ne '';

    # Validate required options explicitly
    unless (defined $results_root_dir && $results_root_dir ne '') {
        PrintError("Missing required option: results_root_dir");
        return undef;
    }
    unless (defined $test_suite && $test_suite ne '') {
        PrintError("Missing required option: test_suite");
        return undef;
    }

    # Run count via ctx->{files}
    my $runCount = GetRunCount($files);
    if (!defined $runCount || $runCount eq '') {
        PrintError("GetRunCount failed or returned invalid value");
        return undef;
    }

    # Build results directory path
    my $leaf = join('_', $host, $test_suite, $test, $runCount, $iter, $thread);
    my $dir_path = File::Spec->catdir($results_root_dir, $leaf);
    PrintVerbose($mrsd."Attempting to create results dir:");
    PrintVerbose($mrsd." ".$dir_path);

    unless (TAF::Utilities::EnsureDirectory($dir_path)) {
        PrintError("Failed to create results dir: $dir_path");
        return undef;
    }

    $dir_path = TAF::Utilities::TrailingSlash($dir_path);

    StageEnd($mrsd);
    return $dir_path;
}

#===============================================================================
# GetRunCount
#
# PURPOSE:
#     Maintain and increment the framework's persistent run counter. Used to
#     generate deterministic, contributor-proof results directory names across
#     executions.
#
# PARAMETERS:
#     $files_ref
#         Hash reference containing framework file paths, including the
#         run_count file location.
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Validate that files_ref->{run_count} is defined.
#     - When the run_count file exists:
#           * Read the file.
#           * Strip non-digit characters.
#           * Extract the current run count.
#     - When the file does not exist:
#           * Emit a warning indicating a new installation or missing file.
#           * Initialize run count to 1.
#     - Increment the run count when a valid value was read.
#     - Write the updated run count back to the run_count file.
#     - End the lifecycle stage and return the new run count.
#
# RETURNS:
#     Integer
#         The updated run count.
#
#     UNDEF
#         File read/write failure or missing run_count path.
#
# NOTES:
#     - Contributor-proof discipline: explicit validation, explicit errors,
#       no silent fallbacks.
#     - The run_count file is always overwritten with the new value.
#     - Callers rely on this value for deterministic results directory naming.
#===============================================================================
sub GetRunCount {
    my ($files_ref) = @_;

    # Setup
    my $grc = StageStart(TAF_RUN."GetRunCount");
    my $runCount;
    my $run_count_file = $files_ref ? $files_ref->{run_count} : UNDEF;

    # Make sure we have something to work with.
    if (!defined $run_count_file || $run_count_file eq '') {
        PrintError($grc . "files_ref->{run_count} is not defined");
        return UNDEF;
    }

    # See if there is an exsting .run_count.txt file
    if (-e $run_count_file) {
        PrintVerbose($grc . "$run_count_file exists");

        # Open and get current run count
        open(my $fh, '<', $run_count_file) or do {
            PrintError($grc . "Failed to read $run_count_file: $!");
            return UNDEF;
        };

        while (<$fh>) {
            chomp;
            s/\D//g;   # strip non-digits
            $runCount = $_;
        }
        close($fh);
    # File did not exist, and we tell user
    } else {
        PrintWarning($grc . "Run count file not found");
        PrintVerbose($grc . "Assuming new install, will create file");
    }

    # If count is defined, we increase it by 1 Else we start with 1
    if (defined $runCount && $runCount ne '') {
        PrintVerbose($grc . "Current run count: $runCount");
        $runCount++;
    } else {
        $runCount = 1;
        PrintVerbose($grc . "New installation detected, count = $runCount");
    }

    # Create/Update run count file.
    PrintVerbose($grc . "Writing run count to $run_count_file");
    open(my $fh, '>', $run_count_file) or do {
        PrintError($grc . "Failed to write to $run_count_file: $!");
        return UNDEF;
    };
    print $fh $runCount;
    close($fh);

    PrintVerbose($grc . "Run count $runCount written to $run_count_file");

    StageEnd($grc);
    return $runCount;
}

#===============================================================================
# WatchDbProcessForRest
#
# PURPOSE:
#     Centralized TAF orchestration routine for CPU-based rest detection of the
#     database process. This routine retrieves the runtime PID from TAF state,
#     loads all CPU-monitoring thresholds from the active options set, and
#     invokes WatchDbCpuUsage() in testtoolsLib. It provides a single, stable
#     call point for all phases of Run.pm that require CPU-based readiness
#     detection.
#
# PARAMETERS:
#     $ctx
#         Framework context hashref containing:
#             obj      -> plugin objects (including db_plugin)
#             taf_var  -> TAF runtime state (including db_pid)
#             options  -> active TAF options and rest-watch tunables
#
# BEHAVIOR:
#     - Short-circuits immediately when db_process_rest_enable is false.
#     - Validates that a runtime PID is available in taf_var->{db_pid}.
#     - Constructs a complete argument set for WatchDbCpuUsage().
#     - Invokes the CPU monitor and interprets its OK/ERROR result.
#     - Emits contributor-safe diagnostics for all failure modes.
#     - Returns OK only when the database process reaches a stable rest state.
#
# RETURNS:
#     OK
#         Database process reached rest state or feature disabled.
#
#     ERROR
#         Any of the following:
#             - CPU monitoring enabled but PID missing or invalid.
#             - CPU monitor returned ERROR (process disappeared, thresholds
#               not met, or unexpected backend failure).
#
# NOTES:
#     - This routine isolates all CPU-monitoring logic in one place, ensuring
#       consistent behavior across setup, iteration, and teardown phases.
#     - All thresholds and tunables must be provided via TAF options; no hidden
#       defaults or global lookups occur here.
#     - WatchDbCpuUsage() normalizes backend return codes to OK/ERROR.
#===============================================================================
sub WatchDbProcessForRest {
    my ($ctx) = @_;

    my $taf_var_ref = $ctx->{taf_var};
    my $opt         = $ctx->{options};

    # Feature disabled
    return OK unless $opt->{db_process_rest_enable};

    my $wdbp = StageStart(TAF_RUN."WatchDbProcessForRest");
    my $pid = $taf_var_ref->{db_pid};
    unless (defined $pid && $pid =~ /^\d+$/) {
        PrintError("WatchDbProcessForRest: invalid or missing PID");
        return ERROR;
    }

    my $rc = toolsLib::WatchDbCpuUsage(pid          => $pid,
                                       low          => $opt->{db_process_rest_low},
                                       high         => $opt->{db_process_rest_high},
                                       consecutive  => $opt->{db_process_rest_consecutive},
                                       max_attempts => $opt->{db_process_rest_max_attempts},
                                       interval     => $opt->{db_process_rest_interval},
                                       verbose      => $opt->{tools_debug},);

    if ($rc == OK) {
        PrintVerbose("DB process reached rest state.");
        StageEnd($wdbp);
        return OK;
    }

    PrintError("DB process did not reach rest state (or disappeared) during monitoring.");
    return ERROR;
}

#===============================================================================
# CheckDbRestOrSleep
#
# PURPOSE:
#     Centralized decision point for handling intentional delays during the
#     test lifecycle. When CPU-based rest detection is enabled, this routine
#     invokes WatchDbProcessForRest() to wait for the database process to reach
#     a stable rest state. When disabled, it falls back to SleepWithLog() using
#     the caller-provided sleep duration. This ensures consistent behavior
#     across Run.pm without scattering conditional logic.
#
# PARAMETERS:
#     $ctx
#         Framework context object containing taf_var and options.
#
#     $prefix
#         String prefix used for logging when falling back to SleepWithLog().
#
#     $seconds
#         Number of seconds to sleep when CPU-based rest detection is disabled.
#
# BEHAVIOR:
#     - If db_process_rest_enable is false:
#           * Call SleepWithLog($prefix, $seconds).
#           * Return OK.
#     - If db_process_rest_enable is true:
#           * Validate that taf_var->{db_pid} contains a valid PID.
#           * Invoke WatchDbProcessForRest($ctx).
#           * Return OK on success, ERROR on failure.
#
# RETURNS:
#     OK
#         Delay completed successfully (either via sleep or CPU rest detection).
#
#     ERROR
#         CPU rest detection was enabled but failed (PID missing, process
#         disappeared, or rest state not reached).
#
# NOTES:
#     - This routine does not modify lifecycle flags.
#     - Callers should use this instead of SleepWithLog() when the delay is
#       intended to ensure database idleness.
#     - SleepWithLog() remains available for unconditional sleeps.
#===============================================================================
sub CheckDbRestOrSleep {
    my ($ctx, $prefix, $seconds) = @_;

    my $taf_var = $ctx->{taf_var};
    my $opt     = $ctx->{options};

    # CPU rest detection disabled -> normal sleep
    unless ($opt->{db_process_rest_enable}) {
        SleepWithLog($prefix, $seconds);
        return OK;
    }

    # CPU rest detection enabled -> need PID
    my $pid = $taf_var->{db_pid};
    unless (defined $pid && $pid =~ /^\d+$/) {
        PrintError("CheckDbRestOrSleep: CPU rest enabled but PID missing");
        return ERROR;
    }

    # Call the Run.pm orchestration wrapper
    my $rc = WatchDbProcessForRest($ctx);

    return ($rc == OK) ? OK : ERROR;
}

#===============================================================================
#  MaybeExecuteSqlHook
#
#  PURPOSE:
#      Execute a SQL hook file at a defined point in the test lifecycle.
#      This routine centralizes SQL hook execution so Run.pm does not need
#      to repeat option checks, path handling, or output redirection logic.
#
#  PARAMETERS:
#      $ctx
#          Framework context object containing taf_var, options, and dirs.
#
#      $hook_name
#          Name of the TAF option that specifies the SQL file to execute.
#          If the option is undefined, the hook is skipped.
#
#      $output_path
#          Directory where the SQL client output file should be written.
#          The output filename is derived from the hook name.
#
#  BEHAVIOR:
#      - Look up the SQL file path from options->{$hook_name}.
#      - If no file is defined, return OK immediately.
#      - Construct an output filename using the hook name.
#      - Invoke DbExecuteSqlFile() to run the SQL file through the client.
#      - Return OK on success, ERROR on failure.
#
#  RETURNS:
#      OK
#          Hook was skipped or SQL file executed successfully.
#
#      ERROR
#          SQL execution failed (client error, missing file, or non-zero exit).
#
#  NOTES:
#      - This routine does not validate SQL syntax or file contents.
#      - All stdout/stderr from the client is redirected to the hook-specific
#        output file inside the provided output directory.
#      - Callers should invoke this at well-defined lifecycle points such as
#        before/after setup, before/after test run, and before/after iterations.
#===============================================================================
sub MaybeExecuteSqlHook {
    my ($ctx, $hook_name, $output_path) = @_;
    my $sql_file = $ctx->{options}{$hook_name};
    return OK unless defined $sql_file;

    my $sep = ($output_path =~ m{/$}) ? "" : "/";
    my $output_file = $output_path . $sep . $hook_name . "_sql_output.txt";

    PrintVerbose("Executing SQL hook: $hook_name ($sql_file)");

    return sql_libs::Executor::DbExecuteSqlFile($ctx, $sql_file, $output_file);
}

#############################################################################
# Module terminator
#############################################################################
1;