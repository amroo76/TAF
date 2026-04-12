package DateTime;
#############################################################################
# DateTime
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
#
# PURPOSE:
#     Provide a deterministic, contributor-proof set of date and time utilities
#     for the TAF runtime. This module centralizes all timestamp generation,
#     elapsed-time calculations, and file-date formatting to ensure consistent
#     behavior across the framework.
#
# ARCHITECTURAL ROLE:
#     - Acts as the single timekeeping utility for TAF.
#     - Provides high-resolution timing via Time::HiRes.
#     - Supplies stable, formatted timestamps for:
#           * logging
#           * readme metadata
#           * result directories
#           * duration calculations
#     - Maintains both "current" and "original" (startup) timestamps to support
#       reproducible reporting and elapsed-time tracking.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not perform scheduling or sleep logic.
#     - Does not manage time zones beyond system defaults.
#     - Does not guess or infer missing timestamps.
#     - Does not modify caller state outside of its own object.
#
# CONTRACT:
#     - Caller must instantiate via DateTime->new().
#     - All methods operate on object state; no global time state is used.
#     - Methods provide:
#           SetDate()
#           GetDate()
#           GetDateTime()
#           GetStartTime()
#           SetStartTime()
#           GetElapsedTimeSeconds()
#           GetElapsedTimeMilliseconds()
#           FigureElapsedTimeSeconds()
#           FigureElapsedTimeMilliseconds()
#           GetFileDateStamp()
#           and related "Org" variants for original timestamps.
#     - All returned values are deterministic and formatted consistently.
#
# GUARANTEES:
#     - High-resolution timing is used for elapsed-time calculations.
#     - Original timestamps are preserved for the lifetime of the object.
#     - All formatting is stable and contributor-proof.
#     - No silent failures; invalid states croak explicitly.
#
# NOTES:
#     - This module predates the TAF plugin architecture but remains a core
#       dependency for logging, reporting, and result directory generation.
#     - Any change to timestamp formatting must be reflected in the TAF manual
#       and in all modules that consume these values.
#############################################################################
use strict;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK $VERSION);
use Time::HiRes qw(gettimeofday tv_interval);
use Carp;
use Exporter;

@ISA = qw(Exporter);
@EXPORT = qw(&new
             &SetDate
             &GetDate
             &GetDateTimeSeed
             &GetOrgDate
             &GetTime
             &GetOrgTime
             &GetStartTime
             &GetOrgStartTime
             &SetStartTime
             &GetElapsedTimeSeconds
             &GetElapsedTimeFormated
             &GetDateTime
             &FigureElapsedTimeSeconds
             &FigureElapsedTimeSecondsMilliseconds
             &FigureElapsedTimeFormatted
             &GetFileDateStamp
             &GetStartTimeMilliseconds
             &GetOrgStartTimeMilliseconds
             &GetElapsedTimeMilliseconds
             &GetElapsedTimeSecondsMilliseconds
             &FigureElapsedTimeMilliseconds
             );

$VERSION = '2.0';

################################################################################
# Create an Object
################################################################################
sub new {
    my $class = shift;
    my $self = {
        DEBUG        => 0,
        dtDate       => undef,
        dtTime       => undef,
        dtStart      => undef,
        dtFileDate   => undef,
        dtOrgDate    => undef,
        dtOrgTime    => undef,
        dtOrgStart   => undef,
        dtMsStart    => undef,
        dtOrgMsStart => undef,
        dtSeed       => undef,
    };
    bless $self, $class;

    $self->SetDate;
    $self->SetStartTime;

    # Preserve original values
    $self->{dtOrgDate}    = $self->{dtDate};
    $self->{dtOrgTime}    = $self->{dtTime};
    $self->{dtOrgStart}   = $self->{dtStart};
    $self->{dtOrgMsStart} = $self->{dtMsStart};

    return $self;
}


################################################################################
# Set Date inits date time and filedate varaibles with current date/time
################################################################################
sub SetDate {
    my $self = shift;

    my ($sec, $min, $hour, $mday, $mon, $year) = localtime(time);

    $year += 1900;
    $mon  += 1;

    # Pad hour, min, sec to two digits
    $hour = sprintf("%02d", $hour);
    $min  = sprintf("%02d", $min);
    $sec  = sprintf("%02d", $sec);

    # Store values in object
    $self->{dtDate}     = "$year-$mon-$mday";
    $self->{dtTime}     = "$hour:$min:$sec";
    $self->{dtFileDate} = "${year}_${mon}_${mday}_${hour}_${min}_${sec}";
    $self->{dtSeed}     = "$mon$mday$hour$min$sec";

    return;
}

################################################################################
# Returns date time seed in mmddhhmmss format
################################################################################
sub GetDateTimeSeed {
    my $self = shift;
    $self->SetDate;
    return $self->{dtSeed};
}

################################################################################
# Set current time in seconds and milliseconds from Epoch
################################################################################
sub SetStartTime {
    my $self = shift;
    $self->{dtStart}    = time;
    $self->{dtMsStart}  = [gettimeofday()];
}

################################################################################
# Get current time in seconds from Epoch
################################################################################
sub GetStartTime {
    my $self = shift;
    return time;
}

################################################################################
# Get current time in milliseconds
################################################################################
sub GetStartTimeMilliseconds {
    my $self = shift;
    return [gettimeofday()];
}

################################################################################
# Get original start time in seconds from Epoch
################################################################################
sub GetOrgStartTime {
    my $self = shift;
    return $self->{dtOrgStart};
}

################################################################################
# Get original start time in milliseconds
################################################################################
sub GetOrgStartTimeMilliseconds {
    my $self = shift;
    return $self->{dtOrgMsStart};
}

################################################################################
# Returns date set by SetDate
################################################################################
sub GetDate {
    my $self = shift;
    $self->SetDate;
    return $self->{dtDate};
}

################################################################################
# Returns original date set by new()
################################################################################
sub GetOrgDate {
    my $self = shift;
    return $self->{dtOrgDate};
}

################################################################################
# Returns time set by SetDate
################################################################################
sub GetTime {
    my $self = shift;
    $self->SetDate;
    return $self->{dtTime};
}

################################################################################
# Returns original time set by new()
################################################################################
sub GetOrgTime {
    my $self = shift;
    return $self->{dtOrgTime};
}

################################################################################
# Returns combined date and time set by SetDate
################################################################################
sub GetDateTime {
    my $self = shift;
    $self->SetDate;
    return "$self->{dtDate} $self->{dtTime}";
}

################################################################################
# Returns formatted date/time string for use in file names
################################################################################
sub GetFileDateStamp {
    my $self = shift;
    $self->SetDate;
    return $self->{dtFileDate};
}

################################################################################
# Returns elapsed time in seconds since SetStartTime
################################################################################
sub GetElapsedTimeSeconds {
    my $self = shift;
    return time - $self->{dtStart};
}

################################################################################
# Returns elapsed time in milliseconds since SetStartTime
################################################################################
sub GetElapsedTimeMilliseconds {
    my $self = shift;
    return sprintf("%u", tv_interval($self->{dtMsStart}) * 1000);
}

################################################################################
# Returns elapsed time in seconds.milliseconds since SetStartTime
################################################################################
sub GetElapsedTimeSecondsMilliseconds {
    my $self = shift;
    return sprintf("%.3f", tv_interval($self->{dtMsStart}));
}

################################################################################
# Returns seconds.milliseconds from provided start time (arrayref from gettimeofday)
################################################################################
sub FigureElapsedTimeSecondsMilliseconds {
    my ($self, $m_start) = @_;
    unless (defined $m_start) {
        carp "Start milliseconds not provided\n";
        return "ERROR";
    }
    return sprintf("%.3f", tv_interval($m_start));
}

################################################################################
# Returns milliseconds from provided start time (arrayref from gettimeofday)
################################################################################
sub FigureElapsedTimeMilliseconds {
    my ($self, $m_start) = @_;
    unless (defined $m_start) {
        carp "Start milliseconds not provided\n";
        return "ERROR";
    }
    return sprintf("%u", tv_interval($m_start) * 1000);
}

################################################################################
# Returns seconds from provided start time (epoch seconds)
################################################################################
sub FigureElapsedTimeSeconds {
    my ($self, $start) = @_;
    unless (defined $start) {
        carp "Start seconds from Epoch not provided\n";
        return "ERROR";
    }
    return time - $start;
}

################################################################################
# Returns formatted elapsed time since SetStartTime (e.g., "1 days 2 hours 3 minutes 4 seconds")
################################################################################
sub GetElapsedTimeFormated {
    my $self = shift;
    return _format_duration(time - $self->{dtStart});
}

################################################################################
# Returns formatted elapsed time from provided start time
################################################################################
sub FigureElapsedTimeFormatted {
    my ($self, $start) = @_;
    unless (defined $start) {
        carp "Start seconds from Epoch not provided\n";
        return "ERROR";
    }
    return _format_duration(time - $start);
}

################################################################################
# Internal helper to format duration in days, hours, minutes, seconds
################################################################################
sub _format_duration {
    my $seconds = shift;
    my $days    = int($seconds / 86400); $seconds -= $days * 86400;
    my $hours   = int($seconds / 3600);  $seconds -= $hours * 3600;
    my $minutes = int($seconds / 60);    $seconds %= 60;

    return join('', 
        ($days    ? "$days days "    : ''),
        ($hours   ? "$hours hours "  : ''),
        ($minutes ? "$minutes minutes " : ''),
        "$seconds seconds"
    );
}

#############################################################################
# Module terminator
#############################################################################
1;
