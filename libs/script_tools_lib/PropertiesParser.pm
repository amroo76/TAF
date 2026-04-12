package PropertiesParser;
#############################################################################
# PropertiesParser
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
#     Provide a deterministic helper for parsing Java-style .properties files
#     using a hash of script variables supplied by the caller. This module
#     wraps the Properties module and adds TAF-specific lookup, substitution,
#     and error-handling behavior for toolsLib and higher-level components.
#
# ARCHITECTURAL ROLE:
#     - Acts as the glue layer between Properties and TAF scripts that require
#       variable substitution or structured property resolution.
#     - Provides a single entry point:
#           * ParseProperties() - load a .properties file and apply variable
#             substitution using a caller-provided hash.
#     - Ensures consistent error handling, lookup behavior, and debug output.
#     - Supports test automation scripts that rely on dynamic configuration
#       values derived from both .properties files and runtime variables.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not replace the underlying Properties module.
#     - Does not validate property schemas or enforce required keys.
#     - Does not perform type checking or deep configuration validation.
#     - Does not guess caller intent or silently ignore missing files.
#     - Does not die(); all failures return undef through ReturnError().
#
# CONTRACT:
#     - ParseProperties(<file>, <hashref>) must:
#           * attempt to load the specified .properties file
#           * return undef on failure
#           * apply variable substitution using the provided hash
#           * return a populated Properties object on success
#     - ReturnError(<file>) must:
#           * print an error message only when $debug is enabled
#           * always return undef
#     - All routines must remain deterministic and side-effect-free.
#
# GUARANTEES:
#     - No silent fallbacks or ambiguous behavior.
#     - Debug output is minimal and controlled by $debug.
#     - All file-access failures are surfaced through ReturnError().
#     - Variable substitution behavior is stable and contributor-proof.
#
# NOTES:
#     - This module is intentionally narrow in scope; it exists to provide
#       predictable integration between Properties and TAF scripts that rely
#       on runtime variable substitution.
#     - Any change to parsing or substitution semantics must be reflected in
#       this header and in the TAF manual.
#############################################################################
use strict;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK $VERSION);

@ISA = qw(Exporter);
@EXPORT = qw(&ParseProperties);
$VERSION = '2.0';

# Autobench tools include
use FindBin qw($Bin);
use lib 'lib';
use lib "$Bin"; 
require Properties;
require toolsLib;

our $debug  = 0;
our $propSearch = undef;

################################################################################
# Function : ReturnError
# Purpose  : Report an error when a properties file cannot be opened or located.
#
# Details  :
#   - Arguments:
#       * $propertiesFile : Path to the properties file that failed to open.
#   - Behavior:
#       * If $debug is enabled, prints an error message to STDERR.
#       * Always returns undef to signal failure.
#
# Returns  : undef (used as an error indicator).
################################################################################
sub ReturnError {
    my ($propertiesFile) = @_;
    print "ERROR: Unable to open or locate '$propertiesFile'\n" if $debug;
    return undef;
}

################################################################################
# Function : ParseProperties
# Purpose  : Load a properties file and map values into a provided variable list.
#
# Details  :
#   - Arguments:
#       * $prefix         : Optional string prefix to prepend to variable names
#                           when searching in the properties file.
#       * $varList        : Hash reference of expected variables (keys).
#       * $propertiesFile : Path to the properties file to parse.
#   - Behavior:
#       * Verifies the file exists; returns undef if not.
#       * Opens the file and loads it into a Properties object.
#       * Iterates over each expected variable:
#           - Constructs a search key using $prefix (if defined).
#           - Compares against keys in the loaded properties.
#           - Trims whitespace from values.
#           - Skips values explicitly set to "null".
#           - Converts "true"/"false" strings into 1/0.
#           - Updates the variable list with the resolved value.
#       * Debug mode prints detailed trace information for each step.
#
# Returns  : Hash reference of variables with values populated from the file.
################################################################################
sub ParseProperties {
    my $self           = shift;
    my $prefix         = shift;
    my $varList        = shift;
    my %listOfVars     = %$varList;
    my $propertiesFile = shift;

    # Check if file exists and open safely
    unless (-e $propertiesFile) {
        print "ERROR!!! $propertiesFile does not exist\n" if $debug;
        return undef;
    }

    open my $fh, '<', $propertiesFile or return ReturnError($propertiesFile);

    print "\n**********************************\n" .
          "Current file = $propertiesFile\n" .
          "**********************************\n\n" if $debug;

    # Load properties
    my $properties = Properties->new();
    $properties->load($fh);
    my %propertiesList = $properties->properties();

    # Walk through each expected variable
    VAR: foreach my $var (sort keys %listOfVars) {
        print "\nVariable = $var\n" if $debug;

        my $propSearch = defined $prefix ? "$prefix.$var" : $var;
        print "Search = $propSearch\n" if $debug;

        foreach my $prop (sort keys %propertiesList) {
            print "Property = $prop\n" if $debug;

            my $value = trimLite($propertiesList{$prop});
            next unless $prop eq $propSearch;

            if (lc($value) eq 'null') {
                print "\t NULL, skipping\n\n" if $debug;
                next VAR;
            }

            $listOfVars{$var} = lc($value) eq 'true'  ? 1
                              : lc($value) eq 'false' ? 0
                              : $value;

            if ($debug) {
                print "\tVariable = $var, Property Search = $prop :\n";
                print "\tpropertiesList{propSearch} = $value\n";
                print "\tlistOfVars{var} = $listOfVars{$var}\n\n";
            }

            next VAR;
        }
    }
    return \%listOfVars;
}

################################################################################
# Function : trimLite
# Purpose  : Strip leading and trailing whitespace from a string.
#
# Details  :
#   - Arguments:
#       * $string : Input string to trim.
#   - Behavior:
#       * Returns an empty string if input is undef.
#       * Removes all leading and trailing whitespace characters.
#
# Returns  : Cleaned string with no surrounding whitespace.
################################################################################
sub trimLite {
    my ($string) = @_;
    return '' unless defined $string;

    $string =~ s/^\s+//;
    $string =~ s/\s+$//;
    return $string;
}

#############################################################################
# Module terminator
#############################################################################
1;