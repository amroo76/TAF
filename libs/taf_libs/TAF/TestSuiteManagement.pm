package TAF::TestSuiteManagement;
#############################################################################
# TAF::TestSuiteManagement
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
#     Provide all logic required to discover, load, validate, and unload
#     test suites used by TAF. This module defines the lifecycle for
#     test suite modules, enforces required capabilities, and exposes
#     helper routines for listing suites, listing tests, and extracting
#     metadata from test run artifacts.
#
# ARCHITECTURAL ROLE:
#     - Acts as the authoritative interface between TAF and all test suites.
#     - Loads test suite modules dynamically into the main:: namespace.
#     - Validates that each suite implements the required capability subs.
#     - Provides lifecycle operations:
#           * LoadTestSuite
#           * UnloadTestSuite
#           * ValidateTestType
#           * CheckTestSuiteCapabilities
#     - Provides discovery operations:
#           * ListSuites
#           * ListSuitesHelp
#           * ListSuitesTests
#           * ListTestTypes
#           * GetTestSuiteList
#     - Provides metadata extraction for readme.txt files.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not execute test workloads.
#     - Does not perform database operations.
#     - Does not validate test suite semantics beyond required subs.
#     - Does not modify suite code or rewrite suite behavior.
#     - Does not manage iteration-level execution (handled by Run.pm).
#
# CONTRACT:
#     - Test suites must be located in ctx->{dirs}{test_suites}.
#     - Test suite filenames must be lowercase and end in .pm.
#     - Test suites must implement all required capability subs listed in
#       @test_suite_required_subs.
#     - Test suites must provide a TSParseProperties() routine for
#       initialization.
#     - LoadTestSuite() loads the suite into main:: and sets
#       ctx->{flags}{test_suite_loaded} = TRUE.
#     - UnloadTestSuite() removes the suite from %INC and resets flags.
#
# GLOBAL STATE OWNED BY THIS MODULE:
#     @keys_of_interest          - metadata keys extracted from readme.txt
#     %testTypes                 - valid test types and descriptions
#     @test_suite_required_subs  - required suite capability subs
#
# NOTES:
#     - This module must remain stable; test suite authors depend on its
#       behavior and validation rules.
#     - All suite loading is done into main:: to simplify suite code and
#       avoid namespace collisions.
#     - Unloading a suite does not purge symbols already imported into
#       main::; it only resets lifecycle state and %INC entries.
#############################################################################
#===============================================================================
#                            Imports
#===============================================================================
use Exporter 'import';
use File::Spec;
use File::Basename;
use strict;
use warnings;

BEGIN {
    use File::Basename;
    use File::Spec;
    my $here   = File::Basename::dirname(__FILE__);
    my $parent = File::Spec->catdir($here, File::Spec->updir);
    unshift @INC, $parent unless grep { $_ eq $parent } @INC;
}

use TAF::Logging qw(PrintError
                    PrintWarning
                    PrintVerbose
                    StageStart
                    StageEnd
                    TAFMsg);

our $VERSION = '2.0';

#===============================================================================
#                 Keys of interest from readme.txt
#===============================================================================
our @keys_of_interest = (
        'Date of test',
        'Time of test',
        'Test Name',
        'Test Type',
        'Comments',
        'Duration',
        'Iteration',
        'Threads',
        'Warmup Threads',
        'Warmup Duration',
        'Test Host',
        'OS',
        'OS Version',
        'OS Arch',
        'OS Kernel',
        'CPU',
        'RAM',
        'Database Maker',
        'DB Install Dir',
        'Database Eng',
        'Port',
        'Socket',
        'DB Root User',
        'DB User',
        'Run Duration Seconds',
        'Test end Date-time',
);

#===============================================================================
#                    TAF test types
#===============================================================================
our %testTypes =
(
    "adhoc"         => "All misc runs",
    "investigation" => "investigation runs",
    "production"    => "regular runs",
    "rerun"         => "regression verification runs",
    "release"       => "release testing"
);

#===============================================================================
#                TAF test suites requires sub functions
#===============================================================================
my @test_suite_required_subs = qw(
    BuildClient
    GetConnectorType
    GetDefaultTests
    GetLegalTests
    GetReadmeMeta
    GetTestClientVersion
    GetTestDuration
    GetTestSuiteRevision
    GetTestSuiteType
    GetTestSuiteVersion
    GetThreads
    Help
    InstancesEnabled
    MultiThreadEnabled
    PreTestSetup
    RequestEnabled
    StrictTestValidation
    TestCleanup
    TestPost
    TestRun
    TestSetup
    ValidateTargetWithSuite
);

#===============================================================================
#                              Exports
#===============================================================================
our @EXPORT = qw(
    LoadTestSuite
    ListSuites
    ListSuitesHelp
    ListTestTypes
    UnloadTestSuite
    ValidateTestType
    ParseTestSuiteMetadata
    CheckForLegalTests
    CheckTestSuiteCapabilities
);

#===============================================================================
#                               Constants
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
#                        TestSuiteManagement Functions
#===============================================================================
#
# Subroutines implementing TestSuiteManagement logic for TAF.
# Each routine follows contributor proof headers with
# explicit Purpose, Behavior, Parameters, and Returns.
#===============================================================================

#===============================================================================
# PrintTestSuiteHelp
#
# PURPOSE:
#     Load the test suite associated with the current context, invoke its
#     built-in Help() routine, and then unload the suite. Provides a clean,
#     contributor-proof lifecycle around suite-level help display.
#
# PARAMETERS:
#     $ctx
#         Framework context object.
#
#     $test_suite
#         Name of the test suite being referenced for logging purposes.
#
# BEHAVIOR:
#     - Load the test suite via LoadTestSuite($ctx).
#           * If loading fails, emit an error and return ERROR.
#     - Invoke main::Help() inside an eval block.
#           * If Help() is missing or throws, emit an error, unload the suite,
#             and return ERROR.
#     - Attempt to unload the suite via UnloadTestSuite().
#           * Emit an error if unloading fails (non-fatal).
#     - Return OK when help was displayed and cleanup completed.
#
# RETURNS:
#     OK
#         Help displayed successfully; unload succeeded or failure was non-fatal.
#
#     ERROR
#         Suite failed to load or Help() was missing/errored.
#
# NOTES:
#     - Internal helper, not exported.
#     - Uses the ctx-driven LoadTestSuite() contract rather than loading by
#       filename.
#     - Unload failures are logged but do not abort the help path.
#===============================================================================
sub PrintTestSuiteHelp {
    my ($ctx,$test_suite) = @_;
    my $dirs_ref = $ctx->{dirs};
    my $files_ref = $ctx->{files};
    my $flags_ref = $ctx->{flags};
 
    # Need to load TS before we can call its help
    my $res = LoadTestSuite($ctx);
    if ($res != OK) {
        TAF::Logging::Print("ERROR Failed to load test suite: ".$test_suite);
        return ERROR;
    }

    # Call Test Suite's Help
   eval { main::Help() };
   if ($@) {
        TAF::Logging::Print("ERROR Test suite missing required sub Help()");
        UnloadTestSuite($test_suite,$flags_ref);
        return ERROR;
   }

    
    unless (UnloadTestSuite($test_suite,$flags_ref) == OK) {
        TAF::Logging::Print("ERROR Failed to unload test suite: ".$test_suite);
        # Not fatal unless you want strict enforcement
    }

    return OK;
}

#===============================================================================
# LoadTestSuite
#
# PURPOSE:
#     Load the test suite specified in ctx->{options}{test_suite} into the
#     main:: namespace. Enforces naming rules, resolves the suite file path,
#     performs the require(), validates required suite capabilities, and
#     initializes suite state from user properties.
#
# PARAMETERS:
#     $ctx
#         Framework context hashref containing:
#             - options.test_suite
#             - dirs.test_suites
#             - files.user_properties
#             - flags.test_suite_loaded
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Extract the suite name from ctx->{options}{test_suite}.
#     - Validate that the suite name is defined and fully lowercase.
#     - Normalize the suite filename via EnsureTrailingPm() and construct the
#       full path under dirs.test_suites.
#     - Require the suite file into main:: (with redefine warnings suppressed).
#     - Mark flags.test_suite_loaded = TRUE on success.
#     - Verify that all required suite subroutines exist in main::.
#     - Initialize suite state by calling main::TSParseProperties() with the
#       user properties file.
#     - End the lifecycle stage and return OK.
#
# RETURNS:
#     OK
#         Suite successfully loaded, validated, and initialized.
#
#     ERROR
#         Missing suite name, invalid naming, file not found, missing required
#         subs, or property initialization failure.
#
# NOTES:
#     - Loads the suite directly into main:: to support the framework's
#       delegation model.
#     - Contributor-proof discipline: explicit validation, explicit errors,
#       no silent fallbacks.
#     - Required suite capabilities are defined in @test_suite_required_subs.
#===============================================================================
sub LoadTestSuite {
    my ($ctx) = @_;

    my $lts = StageStart(TAFMsg("TSM::LoadTestSuite -> "));

    # Break out context components
    my $options   = $ctx->{options};
    my $dirs_ref  = $ctx->{dirs};
    my $files_ref = $ctx->{files};
    my $flags_ref = $ctx->{flags};

    # Extract suite name from options
    my $suiteName = $options->{test_suite};

    # Validate suite name defined
    unless (defined $suiteName) {
        PrintError("options{test_suite} not defined");
        return ERROR;
    }

    # Enforce lowercase suite names
    if ($suiteName ne lc($suiteName)) {
        PrintError($lts."Test suite file names must be lowercase. '$suiteName' is invalid.");
        PrintVerbose($lts."Suite needing change: $suiteName");
        return ERROR;
    }

    # Normalize and build full path
    my $testLib         = lc(TAF::Utilities::EnsureTrailingPm($suiteName));
    my $testLibFullPath = $dirs_ref->{test_suites} . $testLib;

    PrintVerbose($lts."Attempting to load: $suiteName");
    PrintVerbose($lts."Test suite path   : $testLibFullPath ");
    # Attempt to load
    if (-e $testLibFullPath) {
        {
            package main;
            no warnings 'redefine';
            require $testLib;   # load suite into main::
        }
        $flags_ref->{test_suite_loaded} = TRUE;
    }
    else {
        PrintError($lts."Path $testLibFullPath not found, check args");
        return ERROR;
    }

    # Verify required subs exist in main::
    foreach my $sub (@test_suite_required_subs) {
        unless (UNIVERSAL::can('main', $sub)) {
            PrintError($lts." main::$sub not defined");
            PrintVerbose($lts."Test suite $suiteName is missing required capability");
            return ERROR;
        }
    }

    PrintVerbose($lts."Test suite has completed loading.");

    # Initialize suite state from user properties
    my $result = main::TSParseProperties($files_ref->{user_properties});
    if (!defined $result || $result != OK) {
        PrintError($lts."TSParseProperties Failed!");
        return ERROR;
    }

    StageEnd($lts);
    return OK;
}

#===============================================================================
# UnloadTestSuite
#
# PURPOSE:
#     Remove a previously loaded test suite module from %INC and reset
#     suite-related framework flags. Provides a lightweight cleanup step for
#     contributor-proof lifecycle traceability.
#
# PARAMETERS:
#     $module
#         Name of the module file (e.g., "mysuite.pm") as stored in %INC.
#
#     $flags_ref
#         Framework flags hashref. test_suite_loaded is cleared on unload.
#
# BEHAVIOR:
#     - If the module name is defined:
#           * Delete the entry from %INC, allowing the suite to be required
#             again in a future load cycle.
#     - Reset suite-related flags (test_suite_loaded = FALSE).
#     - Return OK unconditionally.
#
# RETURNS:
#     OK
#         Always returns OK after performing the unload actions.
#
# NOTES:
#     - This does not purge symbols already imported into main::; Perl does not
#       support full namespace rollback without explicit symbol table surgery.
#     - Intended for lifecycle traceability and state reset, not strict
#       enforcement or isolation.
#     - Caller is responsible for ensuring that no suite routines are invoked
#       after unload.
#===============================================================================
sub UnloadTestSuite {
    my ($module, $flags_ref) = @_;

    # Remove the module from %INC so it can be required again if needed
    delete $INC{$module} if defined $module;

    # Reset suite-related flags
    $flags_ref->{test_suite_loaded} = FALSE;

    return OK;
}

#===============================================================================
# ValidateTestType
#
# PURPOSE:
#     Ensure that ctx->{options}{test_type} is defined, normalized, and valid
#     according to the framework's known %testTypes. Provides contributor-proof
#     diagnostics and terminates via UsageError() on failure.
#
# PARAMETERS:
#     $ctx
#         Framework context object (options, const, etc.).
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - When test_type is defined:
#           * Normalize to lowercase.
#           * Validate against %testTypes.
#           * On invalid value:
#                 - Emit an explicit error.
#                 - Call ListTestTypes() to display valid options.
#                 - Terminate via UsageError().
#     - When test_type is undefined:
#           * Emit an explicit error.
#           * Call ListTestTypes().
#           * Terminate via UsageError().
#     - End the lifecycle stage on success.
#
# RETURNS:
#     None
#         This routine does not return a value. Invalid or missing test_type
#         results in termination via UsageError().
#
# NOTES:
#     - Caller must ensure ctx->{options}{test_type} is set before validation.
#     - Uses ListTestTypes() and UsageError() for contributor-proof diagnostics.
#     - Validation is strict: no silent fallbacks, no defaulting behavior.
#===============================================================================
sub ValidateTestType {
    my ($ctx) = @_;
    my $vtt = StageStart(TAFMsg("ValidateTestType ->"));

    if (defined $ctx->{options}{test_type}) {
        # normalize to lowercase
        my $type = $ctx->{options}{test_type} = lc($ctx->{options}{test_type});

        # validate against known test types
        unless (exists $testTypes{ $type }) {
            my $msg = "Invalid test_type: '$type' is not recognized.";
            PrintError($msg);
            ListTestTypes();
        }
    } else {
        my $msg = "--test-type=<type> is undefined but required.";
        PrintError($msg);
        ListTestTypes();
    }

    StageEnd($vtt);
}

#===============================================================================
# ParseTestSuiteMetadata
#
# PURPOSE:
#     Read a test iteration's readme.txt file and extract all key:value metadata
#     pairs into a normalized lowercase hash. Performs no filtering and preserves
#     all metadata for downstream normalization, reporting, and diagnostics.
#
# PARAMETERS:
#     $readmePath
#         Full path to the readme.txt file for a test iteration.
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#     - Attempt to open the readme file; on failure:
#           * Emit an error.
#           * Return an empty hashref.
#     - Read the file line-by-line.
#     - For any line matching "key : value":
#           * Normalize the key via _normalize_key().
#           * Clean the value (strip CR, collapse whitespace, remove quotes).
#           * Store the pair in the metadata hash.
#     - Ignore non-matching lines silently.
#     - Close the file.
#     - End the lifecycle stage and return the metadata hashref.
#
# RETURNS:
#     Hashref
#         A hashref containing all normalized metadata keys and values.
#         Returns an empty hashref if the file cannot be opened.
#
# NOTES:
#     - Internal helper, not exported.
#     - Does not restrict parsing to any specific block; all key:value pairs
#       anywhere in the file are captured.
#     - Logs malformed lines or block transitions only when verbose/debug is
#       enabled.
#     - Essential-key diagnostics are handled downstream.
#===============================================================================
sub ParseTestSuiteMetadata {
    my ($readmePath) = @_;
    my %metadata;
    my $psm = StageStart(TAFMsg("ParseTestSuiteMetadata -> "));

    open my $fh, '<', $readmePath or do {
        PrintError("$psm Cannot open $readmePath: $!");
        StageEnd($psm);
        return \%metadata;
    };

    my $line_no = 0;

    while (my $line = <$fh>) {
        $line_no++;
        chomp $line;

        # key:value
        if ($line =~ /^\s*([^:]+?)\s*:\s*(.*)$/) {
            my ($raw_key, $value) = ($1, $2);

            my $key = _normalize_key($raw_key);   # lowercase normalized
            next if $key eq '';

            # clean value
            $value =~ s/\r//g;
            $value =~ s/\n/ /g;
            $value =~ s/\t/ /g;
            $value =~ s/\s+/ /g;
            $value =~ s/^"(.*)"$/$1/;
            $value =~ s/^'(.*)'$/$1/;
            $value =~ s/^\s+|\s+$//g;

            $metadata{$key} = $value;
            next;
        }
    }

    close $fh;

    StageEnd($psm);
    return \%metadata;
}

#===============================================================================
# CheckTestSuiteCapabilities
#
# PURPOSE:
#     Validate whether the loaded test suite supports the capabilities required
#     by the current run: multi-instance execution and multi-thread execution.
#     Enforces contributor-proof discipline with explicit validation and no
#     silent fallbacks.
#
# PARAMETERS:
#     $ctx
#         Framework context object (options, flags, const, etc.).
#
# BEHAVIOR:
#     - Start a lifecycle stage for traceability.
#
#     - Instance support:
#           * When ctx->{options}{instances} is set:
#                 - Emit verbose logging.
#                 - Call InstancesEnabled().
#                 - On FALSE, emit an error and return ERROR.
#
#     - Threading support:
#           * Emit verbose logging.
#           * Verify that main::MultiThreadEnabled exists.
#                 - If missing, emit an error and return ERROR.
#           * If MultiThreadEnabled() returns FALSE:
#                 - Require ctx->{options}{threads} == "1".
#                 - If threads > 1, emit an error and return ERROR.
#
#     - End the lifecycle stage and return OK.
#
# RETURNS:
#     OK
#         All required capabilities are supported by the test suite.
#
#     ERROR
#         Any required capability is unsupported or cannot be validated.
#
# NOTES:
#     - Internal helper, not exported.
#     - Contributor-proof discipline: explicit errors, no silent skips.
#     - Threading validation is strict: if the suite cannot confirm threading
#       support, multi-thread execution is not allowed.
#===============================================================================
sub CheckTestSuiteCapabilities {
    my ($ctx) = @_;
    my $ctsc = StageStart(TAFMsg("CheckTestSuiteCapabilities ->"
       . ($ctx->{options}{test_suite} // UNDEF)));

    # Instance support
    if ($ctx->{options}{instances}) {
        PrintVerbose($ctsc . "Checking if Instances Enabled");
        unless (InstancesEnabled()) {
            PrintError($ctsc . " does not support multiple instances.");
            StageEnd($ctsc);
            return ERROR;
        }
    }

    # Threading support
    PrintVerbose($ctsc . "Checking Threading Support");
    unless (UNIVERSAL::can('main', 'MultiThreadEnabled')) {
        PrintError($ctsc . " main::MultiThreadEnabled not defined cannot validate threading support");
        StageEnd($ctsc);
        return ERROR;
    }

    unless (MultiThreadEnabled()) {
        if (defined $ctx->{options}{threads} && $ctx->{options}{threads} ne "1") {
            PrintError($ctsc . "Does not support threading");
            PrintVerbose($ctsc . "Please set threads = 1");
            StageEnd($ctsc);
            return ERROR;
        }
    }

    StageEnd($ctsc);
    return OK;
}

#===============================================================================
# ListSuites
#
# PURPOSE:
#     Enumerate all installed test suites available in the framework. Provides a
#     directory-level listing only; no loading, validation, or capability checks
#     are performed.
#
# PARAMETERS:
#     $ctx
#         Framework context hash containing directory paths, including
#         dirs.test_suites.
#
# BEHAVIOR:
#     - Retrieve the test_suites directory from the context.
#     - Call GetTestSuiteList() to enumerate all *.pm files.
#     - Extract suite names by stripping the ".pm" suffix.
#     - Print a formatted list of installed suites.
#     - Terminate immediately via main::QuickExit() after printing results.
#
# RETURNS:
#     None
#         This routine does not return; it always terminates via QuickExit().
#
# NOTES:
#     - Internal helper, not exported.
#     - Does not load, validate, or inspect any suite; this is a pure filesystem
#       enumeration.
#     - Contributor-proof discipline: explicit, predictable output format.
#===============================================================================
sub ListSuites {
    my($ctx) = @_;

    my $test_suite_dir = $ctx->{dirs}{test_suites};
    my @testSuiteList = GetTestSuiteList($test_suite_dir);

     TAF::Logging::Print("\n\tSuites currently installed");
     TAF::Logging::Print("\t---------------------------------");

    foreach my $suite (@testSuiteList) {
        my ($tmpSuite) = $suite =~ /(.*)\.pm$/;
         TAF::Logging::Print("\t$tmpSuite");

    }
    TAF::Logging::Print("");

    main::QuickExit();
}

#===============================================================================
# ListSuitesTests
#
# PURPOSE:
#     Enumerate the test cases provided by installed test suites. Operates in
#     two modes depending on whether a specific suite was requested on the
#     command line. Provides contributor-proof visibility into default and legal
#     test cases without executing any suite logic beyond metadata routines.
#
# PARAMETERS:
#     $ctx
#         Framework context hash containing dirs, files, flags, and options.
#
# BEHAVIOR:
#     - Retrieve the list of installed suites from the test_suites directory.
#
#     - When no test_suite option is provided:
#           * Print a list of all installed suites.
#           * For each suite:
#                 - Load the suite via LoadTestSuite().
#                 - Print its default test cases (if any).
#                 - Print its legal test cases (if any).
#                 - Unload the suite to restore a clean namespace.
#           * Any LoadTestSuite failure triggers immediate QuickExit().
#
#     - When a specific test_suite option is provided:
#           * Load only that suite.
#           * Print its default test cases (if any).
#           * Print its legal test cases (if any).
#           * Any LoadTestSuite failure triggers immediate QuickExit().
#
#     - After printing results in either mode, terminate via main::QuickExit().
#
# RETURNS:
#     None
#         This routine does not return; it always terminates via QuickExit().
#
# NOTES:
#     - Directory-level enumeration only; suites are loaded solely for metadata
#       routines (GetDefaultTests, GetLegalTests).
#     - UnloadTestSuite() is used to maintain a clean main:: namespace between
#       iterations.
#     - Contributor-proof discipline: explicit errors, deterministic output,
#       no silent fallbacks.
#===============================================================================
sub ListSuitesTests {
    my($ctx) = @_;

    my $test_suite_dir = $ctx->{dirs}{test_suites};
    my $dirs_ref = $ctx->{dirs};
    my $files_ref = $ctx->{files};
    my $flags_ref = $ctx->{flags};
    my @testSuiteList = GetTestSuiteList($test_suite_dir);

    
    if (!defined $ctx->{options}->{test_suite}) {
        TAF::Logging::Print("\n\tSuites currently installed");
        TAF::Logging::Print("\t---------------------------------/n");
     
         foreach my $suite (@testSuiteList) {
             my ($tmpSuite) = $suite =~ /(.*)\.pm$/;
              TAF::Logging::Print("\tTest Suite: $tmpSuite");
              TAF::Logging::Print("\t---------------------------------");
     
             my $res = LoadTestSuite($suite,$dirs_ref,$files_ref,$flags_ref);
             if($res == ERROR){
                  main::QuickExit("Loading test suite returned ERROR, please investigate!");
             }
     
             my $defaultTests = main::GetDefaultTests();
             if (@$defaultTests) {
                  TAF::Logging::Print("\tDefault Test Cases");
                  TAF::Logging::Print("\t---------------------------------");
                 foreach my $test (@$defaultTests) {
                      TAF::Logging::Print("\t$test");
                 }
             }
     
             my $legalTests = main::GetLegalTests();
             if (@$legalTests) {
                  TAF::Logging::Print("\t---------------------------------");
                  TAF::Logging::Print("\tLegal Test Cases");
                  TAF::Logging::Print("\t---------------------------------");
                 foreach my $test (@$legalTests) {
                      TAF::Logging::Print("\t$test");
                 }
             }
             UnloadTestSuite($suite,$flags_ref);
             TAF::Logging::Print("\n\n");
         }
    } else {
             my $suite2 = $ctx->{options}->{test_suite};
             my $res = LoadTestSuite($suite2,
                                     $dirs_ref,$files_ref,$flags_ref);
             if($res == ERROR){
                  main::QuickExit("Loading test suite returned ERROR, please investigate!");
             }
     
             my $defaultTests = main::GetDefaultTests();
             if (@$defaultTests) {
                  TAF::Logging::Print("\n\t$suite2 Default Tests");
                  TAF::Logging::Print("\t--------------------------------------");
                 foreach my $test (@$defaultTests) {
                      TAF::Logging::Print("\t$test");
                 }
             }
     
             my $legalTests = main::GetLegalTests();
             if (@$legalTests) {
                  TAF::Logging::Print("\t---------------------------------");
                  TAF::Logging::Print("\t$suite2 Legal Tests");
                  TAF::Logging::Print("\t---------------------------------");
                 foreach my $test (@$legalTests) {
                      TAF::Logging::Print("\t$test");
                 }
             }
             TAF::Logging::Print("\n\n");
    }
    main::QuickExit();
}

#===============================================================================
# ListSuitesHelp
#
# PURPOSE:
#     Display detailed help information for test suites.
#
# BEHAVIOR:
#     - If no test_suite option is provided:
#           Prints help for all installed suites.
#
#     - If a test_suite option is provided:
#           Canonicalizes the name to a .pm filename using EnsureTrailingPm,
#           searches the installed suite list, and prints help for the matching
#           suite.
#
#     - If the requested suite is not found:
#           Prints an error message, displays the list of installed suites,
#           and exits.
#
#     - Always terminates via QuickExit() after processing.
#
# RETURNS:
#     None
#         This routine does not return; it always terminates via QuickExit().
#
# NOTES:
#     - Directory-level enumeration only; suites are loaded solely to obtain
#       help output.
#     - UnloadTestSuite() is used to maintain a clean main:: namespace between
#       iterations.
#     - Contributor-proof discipline: explicit errors, deterministic output,
#       no silent fallbacks.
#===============================================================================
sub ListSuitesHelp {
    my($ctx) = @_;
    my $test_suites_dir = $ctx->{dirs}{test_suites};
    my $suite = $ctx->{options}->{test_suite};
  
    my @testSuiteList = GetTestSuiteList($test_suites_dir);

    # No defined suite, so we list all of the suites help
    if (!defined $suite) {
         TAF::Logging::Print("No test_suite specified, printing help for all suites");
        foreach my $suite (@testSuiteList) {
            local $ctx->{options}{test_suite} = $suite;
            PrintTestSuiteHelp($ctx, $suite);
        }
    } else {
        my $_found = FALSE;
        my $suiteWithPm = TAF::Utilities::EnsureTrailingPm($suite);
        foreach (@testSuiteList) {
            if (lc($suiteWithPm) eq lc($_)) {
                PrintTestSuiteHelp($ctx,$_);
                $_found = TRUE;
            }
        }

        if (!$_found) {
            TAF::Logging::Print("\n\tERROR: Test Suite ".$suite." not found");
            ListSuites($ctx);
        }
    }

    main::QuickExit();
}

#===============================================================================
# ListTestTypes
#
# PURPOSE:
#     Display all defined test types and their descriptions.
#
# BEHAVIOR:
#     - Prints header and separator.
#     - If no test types are defined, prints message and exits.
#     - Otherwise, lists each test type and its description.
#     - Prints note clarifying that test types are metadata only.
#     - Exits immediately via QuickExit.
#
# RETURNS:
#     None
#         This routine does not return; it always terminates via QuickExit.
#
# NOTES:
#     - Test types are metadata only and do not affect test execution.
#     - Contributor-proof discipline: explicit, deterministic output.
#===============================================================================
sub ListTestTypes {
    TAF::Logging::Print("\n\tTAF requires --test-type=<type>");
    TAF::Logging::Print("\tThe following types available.");
    TAF::Logging::Print("\t-----------------------------");

    if (!%testTypes) {
        TAF::Logging::Print("\tNo test types are currently defined.");
        main::QuickExit("ERROR!");
    }

    foreach my $key (sort keys %testTypes) {
        my $line = sprintf("        %-20s used for %s", "\"$key\"", $testTypes{$key});
        TAF::Logging::Print($line);
    }

    my $m = "\nNote: This information is only used by a results database";
    $m .= " and has no effect on actual test execution.\n";
    TAF::Logging::Print($m);

    main::QuickExit();
}

#===============================================================================
# GetTestSuiteList
#
# PURPOSE:
#     Return a list of available test suite modules (.pm files).
#
# BEHAVIOR:
#     - Reads the test_suites directory.
#     - Validates that the directory exists and can be opened.
#     - Filters out "." and "..".
#     - Collects only .pm files (case-insensitive).
#     - Returns a sorted list of filenames.
#     - Lifecycle discipline applied with StageStart/StageEnd.
#
# RETURNS:
#     Array
#         A sorted list of test suite filenames.
#
# NOTES:
#     - Internal helper, not exported.
#     - Contributor-proof discipline: explicit, deterministic enumeration.
#===============================================================================
sub GetTestSuiteList {
    my ($test_suite_dir) = @_;
    my @list = ();

    unless (-d $test_suite_dir) {
        TAF::Logging::Print("ERROR: Directory not found: ".$test_suite_dir);
    }

    opendir(my $dh, $test_suite_dir) or do {
        TAF::Logging::Print("ERROR: Failed to open directory: ".$test_suite_dir." ($!)");
    };

    while (my $file = readdir($dh)) {
        next if $file =~ /^\.\.?$/;     # Skip . and ..
        next unless $file =~ /\.pm$/i;  # Match .pm files (case-insensitive)
        push @list, $file;
    }
    closedir($dh);

    @list = sort @list;
    #TAF::Logging::Print("\n\tGetTestSuiteList found ".scalar(@list)." test suite(s)");

    return @list;
}

#===============================================================================
# _normalize_key
#
# PURPOSE:
#     Normalize metadata keys by:
#         - converting whitespace to underscores
#         - removing non-alphanumeric and non-underscore characters
#         - collapsing multiple underscores
#         - trimming leading and trailing underscores
#
# PARAMETERS:
#     $k
#         Raw key string from metadata file.
#
# BEHAVIOR:
#     - Lowercase the key.
#     - Replace any run of non-alphanumeric characters with a single underscore.
#     - Collapse multiple underscores.
#     - Strip leading and trailing underscores.
#
# RETURNS:
#     String
#         Normalized key string safe for hash usage.
#
# NOTES:
#     - Defined at file scope so it is not redefined on every call to
#       ParseTestSuiteMetadata.
#     - Contributor-proof discipline: deterministic, ASCII-only normalization.
#===============================================================================
sub _normalize_key {
    my ($key) = @_;
    return '' unless defined $key;

    # Lowercase
    $key = lc $key;

    # Replace any run of non-alphanumeric characters with a single underscore
    $key =~ s/[^a-z0-9]+/_/g;

    # Collapse multiple underscores
    $key =~ s/_+/_/g;

    # Strip leading/trailing underscores
    $key =~ s/^_//;
    $key =~ s/_$//;

    return $key;
}

#############################################################################
# Module terminator
#############################################################################
1;