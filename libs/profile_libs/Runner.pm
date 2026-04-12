package profile_libs::Runner;
#############################################################################
# Runner.pm
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
#     Provide a minimal, deterministic dispatcher for the profiling
#     subsystem. Runner.pm selects the correct profiler module based on
#     TAF options, performs shared validation, loads the profiler module
#     dynamically, and invokes its start() routine. All profiler-specific
#     logic is delegated to the profiler module itself.
#
# ARCHITECTURAL ROLE:
#     - Acts as the single entry point for all profiling operations.
#     - Reads profiler_lib from $ctx->{options} and maps it to a module.
#     - Performs shared validation (timing constraints only).
#     - Loads profiler modules dynamically using require.
#     - Calls module->start($ctx) and returns immediately.
#     - Does not implement stop-file semantics or subprocess logic.
#     - Does not interpret or mutate $ctx; modules may read from $ctx
#       but must not modify it.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not discover or validate external tools (perf, python3, vtune).
#       Each profiler module is responsible for its own tool discovery.
#     - Does not manage stop files, stopped files, or long-running loops.
#     - Does not create or modify iteration directories.
#     - Does not enforce profiler-specific options or constraints.
#     - Does not catch exceptions from profiler modules; all modules must
#       return explicit OK/ERROR status codes.
#
# CONTRACT:
#     - Caller must supply $ctx with:
#           $ctx->{options}->{profiler_lib}
#           $ctx->{options}->{profiler_start_delay}
#           $ctx->{options}->{profiler_duration}
#           $ctx->{taf_var}->{iteration_duration}
#     - profiler_lib must map to a known profiler module.
#     - Profiler modules must implement start($ctx) and return OK/ERROR.
#     - Runner.pm returns OK on success, ERROR on failure.
#
# GUARANTEES:
#     - No mutation of $ctx.
#     - No exceptions (die, croak) are thrown.
#     - All failures are reported via ASCII-only error messages.
#     - All return paths are explicit and deterministic.
#     - Behavior is stable and contributor-proof.
#
# NOTES:
#     - This module is intentionally minimal to preserve architectural
#       clarity and prevent cross-profiler coupling.
#     - Adding a new profiler requires only adding a mapping entry and
#       implementing a module with a start($ctx) routine.
#############################################################################
use strict;
use warnings;
use File::Spec;
use constant {
    OK    => 0,
    ERROR => 1,
};

# ======================================================================
# start($ctx)
#
# PURPOSE:
#     Dispatcher for the profiling subsystem. This routine selects the
#     correct profiler module based on TAF options, performs shared
#     validation (timing constraints), loads the profiler module
#     dynamically, and invokes its start() routine. All profiler-specific
#     logic is delegated to the module being loaded.
#
# BEHAVIOR:
#     - Reads profiler_lib from $ctx->{options}.
#     - Validates timing constraints (delay + duration).
#     - Maps profiler_lib to a Perl module name.
#     - Dynamically loads the module using require.
#     - Calls module->start($ctx).
#     - Returns immediately; no stop-file semantics.
#
# RETURNS:
#     OK    - success
#     ERROR - failure
#
# SIDE EFFECTS:
#     - None. This routine does not modify $ctx or global state.
#
# NOTES:
#     - All profiler modules must implement start($ctx).
#     - This dispatcher is intentionally minimal and contributor-proof.
# ======================================================================
sub start {
    my ($ctx) = @_;

    my $opts = $ctx->{options};
    my $prof = $opts->{profiler_lib};

    unless ($prof) {
        print "ERROR profiler_lib is undefined\n";
        return ERROR;
    }

    if ($prof eq 'taf-perf') {
        if( _validate_timing($ctx) != OK){
            print "ERROR: from _validate_timing\n";
            return ERROR;
        }
    } else {
        print "ERROR: Invalid profiler_lib '$prof'\n";
        return ERROR;
    }

    my %map = (
        'taf-perf' => 'profile_libs::Perf',
    );

    my $module = $map{$prof};
    (my $file = $module) =~ s!::!/!g;
    $file .= '.pm';

    unless ($module) {
        print "ERROR: No module mapping for profiler_lib '$prof'\n";
        return ERROR;
    }

    my $loaded = eval { require $file; 1 };
    unless ($loaded) {
        (my $err = $@) =~ s/\s+$//;
        print "ERROR: Failed to load $module: $err\n";
        return ERROR;
    }

    if($module->start($ctx) != OK){
        print "ERROR profiler module '$module' returned ERROR from start()\n";
        return ERROR;
    }

    return OK;
}

# ======================================================================
# stop($ctx)
#
# PURPOSE:
#     Generic dispatcher for stopping a running profiler. This routine
#     selects the correct profiler module based on TAF options, loads
#     the module dynamically, and invokes its stop($ctx) routine.
#     All profiler-specific stop logic is delegated to the module.
#
# BEHAVIOR:
#     - Reads profiler_lib from $ctx->{options}.
#     - Maps profiler_lib to a Perl module name.
#     - Dynamically loads the module using require.
#     - Calls module->stop($ctx).
#     - Returns OK or ERROR based on module return value.
#
# WHAT THIS ROUTINE DOES NOT DO:
#     - Does not implement stop-file semantics.
#     - Does not interpret profiler output.
#     - Does not mutate $ctx or global state.
#
# RETURNS:
#     OK    - success
#     ERROR - failure (invalid profiler_lib, load failure, or module error)
#
# NOTES:
#     - Profiler modules must implement stop($ctx) when continuous mode
#       is supported. Modules that do not support stop() must return ERROR.
# ======================================================================
sub stop {
    my ($ctx) = @_;

    my $opts = $ctx->{options};
    my $prof = $opts->{profiler_lib};

    unless ($prof) {
        print "ERROR stop() called but profiler_lib is undefined\n";
        return ERROR;
    }

    my %map = (
        'taf-perf' => 'profile_libs::Perf',
    );

    my $module = $map{$prof};
    (my $file = $module) =~ s!::!/!g;
    $file .= '.pm';
    unless ($module) {
        print "ERROR no module mapping for profiler_lib '$prof'\n";
        return ERROR;
    }

    my $ok = eval { require $file; 1 };
    unless ($ok) {
        (my $err = $@) =~ s/\s+$//;
        print "ERROR failed to load $module: $err\n";
        return ERROR;
    }

    unless ($module->can('stop')) {
        print "ERROR profiler module '$module' does not implement stop()\n";
        return ERROR;
    }

    if($module->stop($ctx) != OK){
        print "ERROR profiler stop() returned ERROR\n";
        return ERROR;
    }

    return OK;
}

# ======================================================================
# _validate_timing($ctx)
#
# PURPOSE:
#     Validate profiler timing parameters against the total test window.
#     The profiler window (delay + duration) must fit entirely within
#     the test suite's duration window (duration + warmup), after
#     applying the test-suite duration unit (sec|min).
#
# BEHAVIOR:
#     - Extracts:
#           profiler_start_delay   (seconds, default 0)
#           profiler_duration      (seconds, default 0)
#           duration               (test duration, unit may be sec|min)
#           warmup_duration        (warmup duration, unit may be sec|min)
#           profiler_ts_duration_unit (sec|min, default sec)
#
#     - Converts:
#           duration and warmup_duration to seconds when unit = min
#
#     - Computes:
#           full_profile_duration  = profiler_start_delay
#                                   + profiler_duration
#           full_duration          = duration + warmup_duration
#
#     - Skips validation when full_duration <= 0.
#
#     - Returns ERROR when full_profile_duration exceeds full_duration.
#       Returns OK otherwise.
#
# RETURNS:
#     OK    - Timing parameters are valid.
#     ERROR - Profiler window exceeds total duration window.
#
# SIDE EFFECTS:
#     None. This routine does not modify $ctx, globals, or environment.
#
# NOTES:
#     - Profiler delay/duration are always interpreted as seconds.
#     - Test suite duration units (sec|min) apply only to duration and
#       warmup_duration.
#     - This is the shared timing validator used by Runner.pm.
# ======================================================================
 sub _validate_timing {
     my ($ctx) = @_;
     my $opts = $ctx->{options};
     my $title = "profile_libs::Runner::_validate_timing:: ";
 
     # Unit selector (default = sec)
     my $unit = $opts->{profiler_ts_duration_unit} || 'sec';
 
     # Profiler times (ALWAYS seconds)
     my $profiler_delay    = $opts->{profiler_start_delay} || 0;
     my $profiler_duration = $opts->{profiler_duration}    || 0;
     my $full_profile_duration = $profiler_delay + $profiler_duration;
 
     # Test suite duration times
     my $duration = $opts->{duration} || 0;
     my $warmup   = $opts->{warmup_duration} || 0;
     my $full_duration = $duration + $warmup;
      
     # Convert ONLY test suite duration units
     if ($unit eq "min") {
         $full_duration = $full_duration * 60;
     }
     elsif ($unit ne 'sec') {
         print "ERROR: invalid profiler_ts_duration_unit: $unit\n";
         return ERROR;
     }
 
     return OK if $full_duration <= 0;
 
     if ($full_profile_duration > $full_duration) {
         print $title."ERROR: profiler delay + duration exceeds iteration duration\n";
         print $title."Time unit used:                        = $unit\n";
         print $title."Full profiler time (delay + duration): = $full_profile_duration\n";
         print $title."Full run time (duration + warmup):     = $full_duration\n";
         return ERROR;
     }
 
     return OK;
 }

#############################################################################
# Module terminator
#############################################################################
1;