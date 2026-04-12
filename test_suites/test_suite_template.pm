###############################################################################
# test_suite_template.pm - Template Test Suite Module for TAF
#
# Created: August 2025
# Last Modified: August 2025
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
#     Provide a contributor-proof template for creating new TAF test suite
#     modules. This file defines the standard metadata layout, lifecycle
#     structure, and documentation conventions required for all TAF test
#     suites. It serves as the starting point for implementing suite-specific
#     logic, configuration handling, and execution flow.
#
# ARCHITECTURAL ROLE:
#     - Acts as the canonical reference for building new test suite modules.
#     - Establishes required metadata fields (name, version, revision).
#     - Defines the expected lifecycle routines:
#           * setup()
#           * run()
#           * cleanup()
#     - Ensures consistent structure, naming, and contributor-proof behavior
#       across all TAF test suites.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not implement any actual test logic.
#     - Does not define configuration semantics.
#     - Does not enforce suite-specific behavior.
#     - Does not guess caller intent; all customization must be explicit.
#
# CONTRACT:
#     - Developers must copy and rename this file when creating a new suite.
#     - All metadata fields must be updated to reflect the new suite.
#     - Lifecycle routines must be implemented or stubbed as appropriate.
#     - Any exported API must follow TAF naming and error-handling conventions.
#
# GUARANTEES:
#     - Provides a stable, reproducible starting point for new test suites.
#     - Ensures consistent documentation and architectural clarity.
#     - Prevents drift in structure or metadata across the test suite layer.
#
# USAGE:
#     perl taf.pl --properties-file=./properties/examples/<your_suite>.properties
#
# NOTES:
#     - This module is part of the TAF test suite layer, not toolsLib.
#     - Any change to template structure must be reflected in this header and
#       in the TAF manual.
#
# NOTE ABOUT $ctx VISIBILITY
#
# Test suites are executed inside the TAF driverâ€™s runtime environment.
# The driver constructs a fully populated context hashref ($ctx) containing
# all runtime configuration, directories, database settings, and options.
#
# Because test suites are loaded and executed in the same package (main::),
# $ctx is automatically visible to all suite code without being declared.
#
# This is intentional and part of the TAF execution contract.
# Suites must treat $ctx as read-only and must not modify its structure.
###############################################################################

###############################################################################
## --------------------------------------------------------------------------
## Metadata
## --------------------------------------------------------------------------
our $properties_prefix = "template";
our $ts_version        = 1;
our $ts_revision       = 0;

use FindBin qw($Bin);
use Cwd;
use constant OK    => 0;
use constant ERROR => 1;
use constant TRUE  => 1;
use constant FALSE => 0;

#-----------------------------------------------------------------------------
# Global Configuration
#-----------------------------------------------------------------------------

our $TS_prefix        = "template";
our $TS_version       = 1;
our $TS_revision      = 0;
our $TS_defaults_file = $Bin."/properties/default/template_default.properties";

our @defaultTests = qw(HelloWorld JebsTest Monty Anna);
our @legalTests = qw(BigTest HelloWorld JebsTest Monty Anna OlesTest);

# Default options hash - customize as needed
our %tsOptions = (
    clean_args          => undef,
    client_args         => undef,
    client_executable   => undef,
    default_duration    => undef,
    load_args           => undef,
    source              => undef,
    test_client_version => undef,
);

#-----------------------------------------------------------------------------
# Test Suite private sub functions declaration
#-----------------------------------------------------------------------------
sub Hello;
sub Jeb;
sub OlesTest;
sub BigTest;
sub Monty;

#-----------------------------------------------------------------------------
# Required AF Sub Functions
#-----------------------------------------------------------------------------

sub BuildClient{
    PrintVerbose("Template -> BuildClient Called");
    # Implement build logic here if needed for make, ant, etc...
    PrintVerbose("Template -> Building $tsOptions{source}");
    return OK;
}

#-----------------------------------------------------------------------------
sub GetDefaultTests{
    
    # This returns a list of default test case to be execute if no test(s)
    # were given in users properties or commandline.
    return \@defaultTests;
}

#-----------------------------------------------------------------------------
sub GetLegalTests{
    # Return all known legal tests to validate ones passed in if
    # Test Suite strict is true
    # Legal could be same as default e.g. return GetDefaultTests();
    return \@legalTests;
}

#-----------------------------------------------------------------------------
sub GetTestClientVersion{
    PrintVerbose("template -> GetTestClientVersion called.");
    # If client has version, should be listed in test suite's default properties.
    return %tsOptions{test_client_version};
}

#-----------------------------------------------------------------------------
sub GetTestSuiteType{
    return "database";
}

#-----------------------------------------------------------------------------
sub GetConnectorType{
     return "template connetor";
}
#-----------------------------------------------------------------------------
sub GetTestDuration{
    PrintVerbose("template -> GetTestDuration called.");
    # If no duration for running test case(s) passed in by user properties or
    # command line, we use the default duration value from test suite's
    # default properties
    return %tsOptions{default_duration};
}

#-----------------------------------------------------------------------------
sub GetTestSuiteRevision {
    PrintVerbose("template -> GetTestSuiteRevision called.");
    return $TS_revision;
}

#-----------------------------------------------------------------------------
sub GetTestSuiteVersion{
    PrintVerbose("template -> GetTestSuiteVersion called.");
    return $TS_version;
}

#-----------------------------------------------------------------------------
sub GetThreads{
    PrintVerbose("template -> GetThreads called.");
    my $_test = shift;
    # Name of tests is passed in so that different tests can have different
    # threads returned.
    # This is default if none are passed in.
    my @_threads = qw(1 4 8 16 32 64 128 256);
    return \@_threads;
}

#-----------------------------------------------------------------------------
sub InstancesEnabled{
    PrintVerbose("template -> InstancesEnabled called.");
    # Can more than 1 instnace of client be running at one time?
    return FALSE;
}

#-----------------------------------------------------------------------------
sub RequestEnabled{
    return FALSE;
}
#-----------------------------------------------------------------------------
sub MultiThreadEnabled{
    PrintVerbose("template -> MultiThreadEnabled called.");
    # Can the client handle more than 1 thread at a time?
    return TRUE;
}


#-----------------------------------------------------------------------------
sub PreTestSetup{
    # Code to be executed before the testing loops are started
    PrintVerbose("template -> PreTestSetup called.");
    return OK;
 }

#-----------------------------------------------------------------------------
sub StrictTestValidation{
    PrintVerbose("template -> StrictTestValidation called.");
    # If TRUE, tests passed in must match exactly all legal. 
    # Some test suite might have many test case, too many to have all
    # added.
    return TRUE;
}


#-----------------------------------------------------------------------------
# How to get test metadata into the readme's created/iteration
sub GetReadmeMeta {
    return {
        table_count     => 'N/A',
        rand_type       => 'N/A',
        thread_model    => 'N/A',
        duration        => $options{duration} // 'N/A',
        notes           => 'This is a template test suite. Replace with actual metadata.',
    };
}


#-----------------------------------------------------------------------------
sub TestCleanup{
    PrintVerbose("template -> TestCleanup called.");
    # This function is used as testing completes. Finial cleanup etc.
    PrintVerbose($tsOptions{client_executable}." ".$tsOptions{clean_args});
    return OK;
}

#-----------------------------------------------------------------------------
sub TestPost{
    PrintVerbose("template -> TestPost called.");
    # This function cleanup happens right after a run has completed.
    return OK;
}

#-----------------------------------------------------------------------------
sub TestRun{
    PrintVerbose("template -> TestRun called.");
    # Here is the meat of the TSPM. This is what invokes and runs your test.
    my ($testCase, $threadCount) =  @_;
    print("test run threads = $threadCount\n");
    $testCase = lc($testCase);
    if($testCase eq "helloworld"){
        return Hello($threadCount);
    } elsif($testCase eq "jebstest"){
        return Jeb($threadCount);
    } elsif($testCase eq "monty"){
        return Monty($threadCount);
    } elsif($testCase eq "anna"){
        return Monty($threadCount);
    } elsif($testCase eq "olestest"){
        return OlesTest($threadCount);
    } elsif($testCase eq "bigtest"){
        return BigTest($threadCount);
    } else{
        # Should never get here since we are strict.
        PrintError("Unknown test: $testCase");
        return ERROR;
    }
}

#-----------------------------------------------------------------------------
sub TestSetup{
    PrintVerbose("template -> TestRun TestSetup.");
    # Code to setup test case/test suite
    # Setup can happen every iteration, or just the first.
    PrintVerbose($tsOptions{client_executable}." ".$tsOptions{load_args});
    return OK;
}

#-----------------------------------------------------------------------------
sub TestSuiteCleanup() {
    PrintVerbose("template -> TestSuiteCleanup called.");
    # This function is used as tests loop completes. Finial cleanup etc.
    PrintVerbose($tsOptions{client_executable}." ".$tsOptions{clean_args});
    return OK;
}

#-----------------------------------------------------------------------------
sub TSParseProperties{
    my $users_properties = shift;

    # Parse defaults file
    my $returnedHash = TAF::Properties::ParsePropertiesFile($TS_prefix, \%tsOptions, $TS_defaults_file);

    unless ($returnedHash && ref $returnedHash eq 'HASH') {
        PrintError($_tpp."Failed to parse defaults file");
        return ERROR;
    }
    %tsOptions = %{$returnedHash};

    # Parse user properties file if defined
    if (defined $users_properties) {
        PrintVerbose($_tpp."Parsing user properties file -> $users_properties");
        $returnedHash = TAF::Properties::ParsePropertiesFile($TS_prefix, \%tsOptions, $users_properties);

        unless ($returnedHash && ref $returnedHash eq 'HASH') {
            PrintError($_tpp."Failed to parse user properties file");
            return ERROR;
        }
        %tsOptions = %{$returnedHash};
    }

    # Parse command-line overrides
    if (defined $options{test_suite_properties}) {
        PrintVerbose($_tpp."Command-line options detected");
        for my $pair (split(',', $options{test_suite_properties})) {
            my ($key, $value) = split('=', $pair, 2);
            PrintVerbose($_tpp."Overriding $key = $value");
            $tsOptions{$key} = $value;
        }
    }
    return OK;
}

#-----------------------------------------------------------------------------
sub Help{
    # Help should provide useful information to anyone wanting to use test suite
    Print("\t====================== Test Suite Template Help ===========================");
    Print("\tContains following default tests");
    Print("\t---------------------------------");
    foreach(@{GetDefaultTests()}){
        Print("\t$_");
    }
    Print("\t---------------------------------");
    Print("\tContains following legal tests");
    Print("\t---------------------------------");
    foreach(@{GetLegalTests()}){
        Print("\t$_");
    }
    Print("\tDEFAULTS:");
    foreach(sort keys %tsOptions){
        if(!defined $tsOptions{$_}){
            Print("\t$TS_properties_prefix."."$_"."="."not defined");
        } else {
            Print("\t$TS_properties_prefix."."$_"."="."$tsOptions{$_}");
        }
    }
    Print("\n\tHelpful Sites:");
    Print("\t------------------------------");
    Print("\thttps://www.mariadb.org");
    Print("\t\n================= Test Suite Template Help End===================\n");
}

#-----------------------------------------------------------------------------
sub ValidateTargetWithSuite {
    my ($incoming_type) = @_;  # e.g. 'mysql', 'mariadb', 'pgsql'

    return OK;
}

############# Test suite's private sub functions ###############################

sub Hello{
    my $threads = shift;
    Print("Hellworld is running.... with ".$threads." threads");

    sleep($options{duration});

    return OK;
}

#-----------------------------------------------------------------------------
sub Jeb{
    my $threads = shift;
    Print("Jeb's Test is running.... with ".$threads." threads");

    sleep($options{duration});

    return OK;
}

#-----------------------------------------------------------------------------
sub Monty{
    my $threads = shift;
    Print("Monty's Test is running.... with ".$threads." threads");
    Print("Want to say THANKS! Monty for MySQL and M part of the LAMP stack");
    Print("Want to say THANKS! Monty for MariaDB the MySQL replacement!");

    sleep($options{duration});

    return OK;
}

#-----------------------------------------------------------------------------
sub Anna{
    my $threads = shift;
    Print("Anna's Test is running.... with ".$threads." threads");
    Print("Want to say THANKS! Anna for My and Maria");
    Print("Want to say THANKS! Anna taking over and leading MariaDB Foundation!");

    sleep($options{duration});

    return OK;
}

#-----------------------------------------------------------------------------
sub OlesTest{
    my $threads = shift;
    Print("Ole's Test is running.... with ".$threads." threads but will fail");

    sleep($options{duration});

    return ERROR;
}

#-----------------------------------------------------------------------------
sub BigTest {
	my $threads = shift;
    Print("Big Test is running... with $threads threads");

    my $cmd = join ' ', $tsOptions{client_executable}, $tsOptions{client_args};
    #PrintVerbose($cmd);

    if ($options{instances} > 1) {
        for my $num (0 .. $options{instances} - 1) {
            my $msg = "Instance $num: $cmd";
            PrintVerbose($msg);
        }
    }

    sleep($options{duration});
    return OK;
}
#-----------------------------------------------------------------------------
sub PrintTsOptions {
    my ($label) = @_;
    $label ||= 'tsOptions';

    print("$label contents:\n");

    for my $key (sort keys %tsOptions) {
        my $val = defined $tsOptions{$key} ? $tsOptions{$key} : '<undef>';
        print("template -> $key => $val\n");
    }
}

#############################################################################
# Module terminator
#############################################################################
# NOTE: Must end in true (i.e. 1;)
1;
