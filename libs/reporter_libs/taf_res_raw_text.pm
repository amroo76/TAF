package reporter_libs::taf_res_raw_text;
#############################################################################
# reporter_libs::taf_res_raw_text
#
# Created: December 2025
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
#
# PURPOSE:
#     Dump raw, unprocessed reporting data structures to a plain text file.
#     This plugin is intended for debugging, inspection, and development of
#     new report plugins. It exposes the full result entry array exactly as
#     produced by TAF::Reports, including metadata, metrics, and iteration
#     structures.
#
# ARCHITECTURAL ROLE:
#     - Implements the GenerateResults() interface required by TAF::Reports.
#     - Produces a deterministic text dump using Data::Dumper with stable
#       formatting (sorted keys, quoted strings, terse mode).
#     - Emits a small header summarizing canonical lowercase metadata fields
#       (test_name, test_host, database_maker, timestamp).
#     - Writes a single .raw.txt file for each invocation.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not compute statistics or aggregates.
#     - Does not generate charts, tables, HTML, or JSON.
#     - Does not validate result entry structure beyond basic presence checks.
#     - Does not modify result directories or archive output.
#     - Does not guess plugin names or perform dynamic dispatch.
#
# CONTRACT:
#     - Caller must invoke GenerateResults($resultsRef, $filename, $outputDir).
#     - $resultsRef must be an arrayref of result entry hashrefs created by
#       TAF::Reports::BuildResultEntry().
#     - Each result entry must contain:
#           metadata  => hashref of lowercase metadata fields
#           metrics   => arrayref of metric hashes
#     - The plugin must write exactly one text file:
#           $outputDir/$filename.raw.txt
#
# GUARANTEES:
#     - Output is deterministic and stable for diffing and debugging.
#     - Missing metadata fields fall back to explicit "unknown_*" placeholders.
#     - Data::Dumper output is sorted and consistently formatted.
#
# NOTES:
#     - This plugin is intended for developers and debugging workflows.
#     - It is not meant for end users or presentation-quality reporting.
#############################################################################
use strict;
use warnings;
use Exporter 'import';
use File::Spec;
use Data::Dumper;

our @EXPORT_OK = qw(GenerateResults);

sub GenerateResults {
    my ($resultsRef, $filename, $outputDir) = @_;
    my $output_path = File::Spec->catfile($outputDir, "$filename.raw.txt");

    open my $fh, '>', $output_path
        or die "Cannot write raw dump to $output_path: $!";

    my $first    = $resultsRef->[0];
    my $meta     = $first->{metadata} // {};

    # canonical lowercase metadata
    my $testname = $first->{test_name}          // 'unknown_test';
    my $host     = $meta->{test_host}           // 'unknown_host';
    my $dbmaker  = $meta->{database_maker}      // 'unknown_dbmaker';
    my $endtime  = $meta->{timestamp}           // 'unknown_time';

    print $fh "=== Raw Results Dump ===\n";
    print $fh "Test Name   : $testname\n";
    print $fh "Host        : $host\n";
    print $fh "Database    : $dbmaker\n";
    print $fh "End Time    : $endtime\n";
    print $fh "=========================\n\n";

    local $Data::Dumper::Indent   = 1;
    local $Data::Dumper::Sortkeys = 1;
    local $Data::Dumper::Terse    = 1;
    local $Data::Dumper::Useqq    = 1;

    print $fh Dumper($resultsRef);

    close $fh or die "Failed to close $output_path cleanly";
    print "Raw results written to: $output_path\n";

    return 1;
}

#############################################################################
# Module terminator
#############################################################################
1;
