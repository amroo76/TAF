package TAF::Properties;
#############################################################################
# TAF::Properties
#
# Created: December 2025
# Last Modified: January 2026
#
# This file is part of the Test Automation Framework (TAF).
# Copyright (c) 2025-2026
# MariaDB Foundation
#
# Licensed under the GNU General Public License, version 2 or later (GPLv2+).
# See https://www.gnu.org/licenses/ for details.
#
# PURPOSE:
#     Provide deterministic, contributor-proof loading and merging of TAF
#     configuration properties. This module unifies default properties,
#     user-defined properties, and command-line overrides into a single,
#     explicit options hash used throughout the framework.
#
# ARCHITECTURAL ROLE:
#     - Loads default TAF properties from the framework installation.
#     - Loads user properties from the test run environment.
#     - Applies command-line overrides deterministically.
#     - Produces a clean temporary options structure for override parsing.
#     - Ensures all property sources are validated, merged, and logged.
#     - Appends cleaned user property contents to run metadata for traceability.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not validate semantic correctness of property values.
#     - Does not infer missing properties or apply hidden defaults.
#     - Does not modify directory structures or create files.
#     - Does not interpret test suite behavior or execution semantics.
#     - Does not silently skip malformed property files.
#
# CONTRACT:
#     - Caller must provide a fully populated context containing:
#           ctx->{options}
#           ctx->{files}{default_taf_properties}
#           ctx->{files}{user_properties}
#           ctx->{taf_var}{upd_cmdline}
#     - Property files must be readable and syntactically valid.
#     - ParsePropertiesFile() must return a hashref or ERROR.
#     - Overrides must be provided as a hashref of explicit key/value pairs.
#     - All failures must be explicit; no silent fallbacks are permitted.
#
# GUARANTEES:
#     - All property merges are deterministic and logged.
#     - User properties overwrite defaults; overrides overwrite both.
#     - Temporary option structures contain all keys with undef values.
#     - Malformed or unreadable property files return ERROR immediately.
#
# NOTES:
#     - This module defines the authoritative configuration merge order:
#           1. Default properties
#           2. User properties
#           3. Command-line overrides
#     - This order must remain stable; downstream modules depend on it.
#     - Any expansion of property semantics must be reflected in this header
#       and documented in the TAF manual.
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

use TAF::Logging qw(
    Print
    PrintError
    PrintWarning
    PrintVerbose
    PrintHeader
    PrintHashVerbose
    PrintLine
    StageStart
    StageEnd
    TAFMsg
);

use TAF::Utilities;
our $VERSION = '2.0';

#===============================================================================
#                                Exports
#===============================================================================
our @EXPORT = qw(
    LoadDefaultProperties
    LoadUserProperties
    ApplyOverrides
    InitTempOptions
);

#===============================================================================
#                                 Constants
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
#                            Properties Functions
#===============================================================================
#
# Subroutines implementing Properties logic for TAF.
# Each routine follows contributor proof headers with
# explicit Purpose, Behavior, Parameters, and Returns.
#===============================================================================

#===============================================================================
#                            Exported Subs
#===============================================================================

#===============================================================================
# LoadDefaultProperties
#
# PURPOSE:
#     Load and merge the default TAF properties file into the framework options.
#     Ensures deterministic initialization of the base configuration layer.
#
# PARAMETERS:
#     $ctx
#         Framework context object containing options and files hashes.
#
# BEHAVIOR:
#     - Extract the options and files hashes from the context.
#     - Validate that both references are defined and hashrefs.
#     - Validate that the default properties file exists and is readable.
#     - Parse the file using ParsePropertiesFile("taf", ...).
#     - On parse failure or unexpected return type, log an error and return ERROR.
#     - Merge parsed properties into the options hash, overwriting existing keys.
#
# RETURNS:
#     OK
#         Successful load and merge.
#
#     ERROR
#         Validation failure, unreadable file, or parse error.
#
# NOTES:
#     - Provides contributor-proof initialization of the framework’s default
#       configuration layer.
#     - Caller is responsible for invoking user-property and CLI override
#       resolution after this routine completes.
#===============================================================================
sub LoadDefaultProperties {
    my ($ctx) = @_;

     # Break out context components
     my $options_ref =  $ctx->{options};
     my $files_ref   =  $ctx->{files}; 

    unless (defined $options_ref && ref($options_ref) eq 'HASH') {
        TAF::Logging::Print("ERROR: LoadDefaultProperties: options_ref is not a hashref");
        return ERROR;
    }

    unless (defined $files_ref && ref($files_ref) eq 'HASH') {
        TAF::Logging::Print("ERROR: LoadDefaultProperties: files_ref is not a hashref");
        return ERROR;
    }

    # Validate file existence
    unless (defined $files_ref->{default_taf_properties} 
      && -e $files_ref->{default_taf_properties}) {
        TAF::Logging::Print("ERROR: Default properties file not found: "
          . ($files_ref->{default_taf_properties} // 'undef'));
        return ERROR;
    }

    unless (-r $files_ref->{default_taf_properties}) {
        TAF::Logging::Print("ERROR: Default properties file is not readable: $files_ref->{default_taf_properties}");
        return ERROR;
    }

    # Attempt parse
    my $hash = ParsePropertiesFile("taf", $options_ref,
       $files_ref->{default_taf_properties});

    # Handle parse failure or explicit ERROR
    if (!defined $hash || $hash == ERROR) {
        TAF::Logging::Print("ERROR: Failed to parse default properties file: $files_ref->{default_taf_properties}");
        return ERROR;
    }

    # Enforce hashref contract
    unless (ref $hash eq 'HASH') {
        TAF::Logging::Print("ERROR: ParsePropertiesFile returned unexpected type: "
           . (ref($hash) || 'scalar/undef'));
        return ERROR;
    }

    # Safe merge with overwrite visibility
    foreach my $key (sort keys %{$hash}) {
        my $old = $options_ref->{$key};
        my $new = $hash->{$key};

        # For debugging
        #if (!defined $old) {
        #    TAF::Logging::Print("Property added: $key = $new");
        #}
        #elsif ($old ne $new) {
        #    TAF::Logging::Print("Property overwritten: $key = $old -> $new");
        #}

        $options_ref->{$key} = $new;
    }

    return OK;
}

#===============================================================================
# LoadUserProperties
#
# PURPOSE:
#     Load and merge user-defined properties into the framework options. Also
#     append a cleaned, human-readable summary of the property file contents to
#     $ctx->{taf_var}{upd_cmdline} for run metadata.
#
# PARAMETERS:
#     $ctx
#         Framework context object containing:
#             - $ctx->{options}          Hashref of framework options.
#             - $ctx->{files}            Hashref containing user_properties path.
#             - $ctx->{taf_var}          Hashref containing upd_cmdline.
#             - $ctx->{flags}            Hashref containing delete/purge flags.
#
# BEHAVIOR:
#     - Validate that required context components are present and hashrefs.
#     - Validate presence and readability of the user properties file.
#       * If delete/purge mode is active, silently skip missing file.
#     - Parse the file via ParsePropertiesFile().
#     - On parse failure or unexpected return type, log an error and return ERROR.
#     - Merge parsed properties into $ctx->{options}, overwriting existing keys.
#     - Read the raw file, strip comments and whitespace, and append a compact
#       summary of cleaned lines to $ctx->{taf_var}{upd_cmdline}.
#
# RETURNS:
#     OK
#         Properties loaded and merged successfully.
#
#     ERROR
#         Missing file (outside purge mode), unreadable file, parse failure,
#         or invalid structure.
#
# NOTES:
#     - Ensures contributor-proof initialization of user-level overrides.
#     - Caller is responsible for applying CLI overrides after this routine.
#===============================================================================
sub LoadUserProperties {
    my ($ctx) = @_;

    # Break out ctx
    my $options = $ctx->{options};
    my $files   = $ctx->{files};
    my $taf_vars = $ctx->{taf_var};
    my $flags    = $ctx->{flags};

    # Validate context components
    unless (defined $options && ref($options) eq 'HASH') {
        TAF::Logging::Print("ERROR: LoadUserProperties: ctx->{options} is not a hashref");
        return ERROR;
    }

    unless (defined $files && ref($files) eq 'HASH') {
        TAF::Logging::Print("ERROR: LoadUserProperties: ctx->{files} is not a hashref");
        return ERROR;
    }

    # Validate user properties file
    my $user_file = $files->{user_properties};

    unless (defined $user_file && -e $user_file) {
        if ($flags->{delete_purge_flag}) {
            # For purge/delete, missing user properties is allowed.
            # We will use defaults + command-line only.
            TAF::Logging::Print("LoadUserProperties: No user properties file, delete/purge flag set, skipping user load");
            return OK;
        }
        TAF::Logging::Print("ERROR: User properties file not defined or not found");
        return ERROR;
    }

    unless (-r $user_file) {
        TAF::Logging::Print("ERROR: User properties file is not readable: $user_file");
        return ERROR;
    }

    # Parse properties file
    my $hash = ParsePropertiesFile("taf", $options, $user_file);

    if (!defined $hash || $hash == ERROR) {
        TAF::Logging::Print("ERROR: Failed to parse user properties file: $user_file");
        return ERROR;
    }

    unless (ref $hash eq 'HASH') {
        TAF::Logging::Print("ERROR: ParsePropertiesFile returned unexpected type: " . (ref($hash) || 'UNDEF'));
        return ERROR;
    }

    # Merge parsed properties into ctx->{options}
    foreach my $key (sort keys %{$hash}) {
        $options->{$key} = $hash->{$key};
    }

    # Read and clean file contents for annotation
    open(my $fh, "<", $user_file)
        or do {
            PrintError("Cannot open user properties file: $user_file ($!)");
            return ERROR;
        };

    my @lines = <$fh>;
    close($fh);

    my @cleaned_lines;
    foreach my $line (@lines) {
        next if $line =~ /^\s*#/;
        chomp($line);
        $line =~ s/^\s+|\s+$//g;
        $line =~ s/\s+/ /g;
        push @cleaned_lines, $line if length $line;
    }

    # Append cleaned property contents to updated command line
    if (@cleaned_lines) {
        $taf_vars->{upd_cmdline} .=
            " :: prop file contents -> " . join(" ", @cleaned_lines);
    }

    return OK;
}

#===============================================================================
# ApplyOverrides
#
# PURPOSE:
#     Apply command-line override key/value pairs to the framework options
#     stored in $ctx->{options}. Ensures deterministic and explicit override
#     behavior.
#
# PARAMETERS:
#     $ctx
#         Framework context object containing the options hash.
#
#     $tmp_ref
#         Hashref containing override key/value pairs.
#
# BEHAVIOR:
#     - Validate that the override reference is a hashref.
#     - Iterate through all keys in the override hash.
#     - For each key with a defined value, update the corresponding entry in
#       $ctx->{options}.
#
# RETURNS:
#     OK
#         Overrides applied successfully.
#
#     ERROR
#         Invalid override structure.
#
# NOTES:
#     - Caller must pass a valid hashref containing only override keys.
#     - Overrides are explicit: only defined values are applied.
#     - Logging of overrides is handled by the caller when needed.
#===============================================================================
sub ApplyOverrides {
    my ($ctx, $tmp_ref) = @_;

    unless (defined $tmp_ref && ref($tmp_ref) eq 'HASH') {
        print("ERROR: ApplyOverrides: override data is not a hashref/n");
        return ERROR;
    }
    
    # Apply commandline overrides
    foreach my $key (sort keys %{$tmp_ref}) {
        if (defined $tmp_ref->{$key}) {
            $ctx->{options}{$key} = $tmp_ref->{$key};
        }
    }

    return OK;
}

#===============================================================================
# InitTempOptions
#
# PURPOSE:
#     Initialize a temporary options hash containing the same keys as the
#     framework options hash, with all values explicitly set to undef. Provides
#     a clean, isolated workspace for command-line override processing.
#
# PARAMETERS:
#     $options_ref
#         Hashref containing the framework’s current options.
#
# BEHAVIOR:
#     - Validate that the provided reference is a hashref.
#     - Create a new hashref with identical keys, each initialized to undef.
#     - Return the new hashref to the caller.
#
# RETURNS:
#     Hashref
#         A temporary options structure with all values set to undef.
#
#     UNDEF
#         Invalid input reference.
#
# NOTES:
#     - Caller must capture the returned reference.
#     - Does not modify the original options hash.
#     - Ensures contributor-proof initialization with no hidden side effects.
#===============================================================================
sub InitTempOptions {
    my ($options_ref) = @_;

    unless (defined $options_ref && ref($options_ref) eq 'HASH') {
         TAF::Logging::Print("ERROR: InitTempOptions: options_ref is not a hashref");
        return UNDEF;
    }

    # Initialize a temp options hash with all keys from options_ref, values set to undef
    my $tmp_ref = { map { $_ => undef } keys %{$options_ref} };


    return $tmp_ref;
}

#===============================================================================
#                          Internal Subs
#===============================================================================

#===============================================================================
# ParsePropertiesFile
#
# PURPOSE:
#     Parse a properties file into a hash using PropertiesParser. Performs
#     minimal validation and does not participate in lifecycle logging.
#
# PARAMETERS:
#     $prefix
#         String prefix used by the parser to scope keys.
#
#     $hashRef
#         Hashref to populate with parsed key/value pairs.
#
#     $filePath
#         Path to the properties file.
#
# BEHAVIOR:
#     - Validate that the file exists.
#     - Invoke PropertiesParser->ParseProperties($prefix, $hashRef, $filePath).
#     - On success, return the populated hashref.
#     - On failure, log an error and return ERROR.
#
# RETURNS:
#     Hashref
#         Populated with parsed properties on success.
#
#     ERROR
#         File missing or parsing failure.
#
# NOTES:
#     - Does not validate the structure of $prefix or $hashRef.
#     - Does not emit StageStart/StageEnd markers.
#     - Relies on PropertiesParser for all parsing semantics and internal logging.
#===============================================================================
sub ParsePropertiesFile {
    my ($prefix, $hashRef, $filePath) = @_;


    if (-e $filePath) {
        my $returnedHash = PropertiesParser->ParseProperties($prefix, $hashRef, $filePath);

        if (defined $returnedHash) {
            return $returnedHash;
        } else {
            TAF::Logging::Print("ERROR: Issues processing $filePath");
        }
    } else {
        TAF::Logging::Print("ERROR: $filePath does not exist");
    }

    return ERROR;
}

#############################################################################
# Module terminator
#############################################################################
1;