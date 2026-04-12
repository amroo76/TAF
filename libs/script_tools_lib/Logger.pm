package Logger;
#############################################################################
# Logger
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
#     Provide deterministic, contributor-proof logging utilities for test
#     automation. This module offers a unified interface for emitting debug,
#     warning, error, and informational messages with multiple verbosity levels.
#     It forms part of the foundational toolsLib layer and is used throughout
#     TAF for traceability, diagnostics, and structured log output.
#
# ARCHITECTURAL ROLE:
#     - Acts as the central logging utility for toolsLib and higher-level TAF
#       components.
#     - Provides consistent, cross-component logging semantics:
#           * LogDebug / LogDebugVerbose
#           * LogWarn / LogWarnVPlus
#           * LogError / LogErrorVPlus
#           * LogMessage / LogMessageV / LogMessageVPlus / LogMessageVOnly
#           * LogLine / LogLineVPlus / LogLineDebugVerbose
#           * RenameLog
#     - Ensures predictable formatting and output behavior across all callers.
#     - Manages file handles and log file naming through SetName() and internal
#       I/O helpers.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not implement log rotation or archival.
#     - Does not enforce timestamping or structured log formats unless callers
#       provide them.
#     - Does not buffer logs or maintain in-memory history.
#     - Does not guess verbosity; all verbosity levels must be explicitly set.
#     - Does not die() on logging failures; errors are reported but execution
#       continues.
#
# CONTRACT:
#     - SetName(file => path) must set the active log file path.
#     - Logging routines must:
#           * open the file if needed
#           * append or write deterministically
#           * respect verbosity flags
#           * return without throwing exceptions
#     - RenameLog() must safely rename the active log file.
#     - All routines must avoid implicit side effects outside the log file.
#
# GUARANTEES:
#     - Logging behavior is deterministic and contributor-proof.
#     - No silent failures; errors are surfaced through STDERR or return codes.
#     - Verbosity levels behave consistently across all log types.
#     - File handles are opened and closed safely.
#
# NOTES:
#     - This module is intentionally minimal; it provides only the logging
#       primitives required by toolsLib and higher-level TAF components.
#     - Any change to logging semantics or verbosity rules must be reflected in
#       this header and in the TAF manual.
#############################################################################

use strict;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK $VERSION);

use Exporter;
use IO::File;

@ISA = qw(Exporter);
@EXPORT = qw(
    &LogDebug
    &LogDebugSwtch
    &LogDebugVerbose
    &LogError
    &LogErrorVPlus
    &LogWarn
    &LogWarnVPlus
    &LogMessage
    &LogMessageV
    &LogMessageVPlus
    &LogMessageVOnly
    &LogLine
    &LogLineVPlus
    &LogLineDebugVerbose
    &RenameLog
);

$VERSION = '2.0';

our $fh;
our $error = 0;
use Data::Dumper;

################################################################################
# Create an Object
################################################################################
sub new {
    my $class = shift;
    my $self = {};
    bless $self, $class;
    $self->SetName(@_);
    return $self;
}

################################################################################
# Function : SetName
# Purpose  : Assign a file name to the object, with a default fallback.
#
# Details  :
#   - Accepts key/value arguments via %fileIn.
#   - Uses 'file' key if provided, otherwise defaults to "./default.log".
#   - Stores the resolved file path in $self->{'file'}.
#
# Returns  : None (updates object state).
################################################################################
sub SetName(){
    my $self = shift;
    my %fileIn = @_;
    $self -> {'file'}  = $fileIn{'file'} || "./default.log";
}

################################################################################
# I/O Utilities
#
# Purpose :
#   Provide helper routines for file handling operations:
#     - OpenFileAppend   : Open existing file for appending, or create new file.
#     - OpenFileForWrite : Open file for writing, truncating or creating as needed.
#     - CloseFile        : Close the file handle safely.
#
# Details :
#   - Uses IO::File with appropriate flags for append/write modes.
#   - Reports errors to STDERR if file operations fail.
#   - CloseFile undefines the handle, automatically closing the file.
################################################################################
#--- Append ---
sub OpenFileAppend (){
    my $self  = shift;
    if (-e $self->{'file'})  {
        $fh = IO::File->new("$self->{'file'}", O_WRONLY|O_APPEND) or $error = 1;
        if($error){
            print("ERROR: could not append to $self->{'file'}: $!\n");
        }
    } else{
        $self->OpenFileForWrite();
    }
}

#--- Write ---
sub OpenFileForWrite (){
    my( $self ) = @_;
    $fh = IO::File->new("$self->{'file'}", O_WRONLY|O_TRUNC|O_CREAT) or $error = 1;
    if ($error){  
        print "ERROR: could not open $self->{'file'} $! for write\n";
    }
}

#--- Close ---
sub CloseFile (){
    my $pos = $fh->getpos;
    $fh->setpos($pos);
    undef $fh;       # automatically closes the file
}

################################################################################
# Write to file functions
################################################################################
################################################################################
# Function : LogMessage
# Purpose  : Write a message to the object's logfile.
#
# Details  :
#   - Opens the logfile in append mode via OpenFileAppend().
#   - Prints the provided message ($_[1]) followed by newline.
#   - Closes the file handle after writing.
#   - Reports error if append operation fails.
#
# Returns  : None (side effect: message written to logfile).
################################################################################
sub LogMessage($){
    # All messages get logged to logfile
    my( $self ) = @_;
    $self->OpenFileAppend ();
    if(!$error){
        print $fh "$_[1]\n";
        CloseFile ();
    }
}

################################################################################
# Function : LogMessageV
# Purpose  : Print a message to STDOUT and also log it to the object's logfile.
#
# Details  :
#   - Accepts a message string as argument.
#   - Prints the message directly to STDOUT.
#   - Delegates to LogMessage() to append the same message to the logfile.
#
# Returns  : None (side effect: message printed and logged).
################################################################################
sub LogMessageV($){
    # All messages get logged to STOUT
    my( $self ) = @_;
    print "$_[1]\n";
    $self->LogMessage($_[1]);
}

################################################################################
# Function : LogMessageVOnly
# Purpose  : Conditionally print and log a message based on verbosity flag.
#
# Details  :
#   - Argument $_[1] acts as the verbosity flag (TRUE/FALSE).
#   - Argument $_[2] is the message string to output.
#   - If verbosity is enabled, prints the message to STDOUT and logs it via LogMessage().
#
# Returns  : None (side effect: message printed and logged when verbose).
################################################################################
sub LogMessageVOnly($$){
    # $_[1] if Verbose
    # $_[2] Message
    my( $self ) = @_;
    if($_[1]){
        print "$_[2]\n";
        $self->LogMessage($_[2]);
    }
}

################################################################################
# Function : CreateLine
# Purpose  : Construct a string consisting of a repeated character.
#
# Details  :
#   - Argument $_[0] specifies the character to repeat.
#   - Argument $_[1] specifies the total length of the line.
#   - Builds the string iteratively by appending the character.
#
# Returns  : A string of the requested size composed of the given character.
################################################################################
sub CreateLine{
    my( $char ) = $_[0];
    my( $size ) = $_[1];
    my( $line ) = undef;
    $line = $char;
    for(my $i = 1; $i < $size; $i++){
        $line = "$line"."$char"; 
    }
    return $line;
}

################################################################################
# Function : LogLine
# Purpose  : Write a line of repeated characters to the logfile.
#
# Details  :
#   - Argument $_[1] specifies the character to repeat.
#   - Argument $_[2] specifies the number of repetitions.
#   - Builds the line using CreateLine() and logs it via LogMessage().
#
# Returns  : None (side effect: line written to logfile).
################################################################################
sub LogLine($$){
    # All messages get logged to logfile
    my( $self )    = $_[0];
    my( $char )    = $_[1];
    my( $size )    = $_[2];
    my( $line ) = undef;
    $line = CreateLine($char,$size);
    $self->LogMessage($line);
}

################################################################################
# Function : LogLineVPlus
# Purpose  : Write a line of repeated characters to the logfile.
#
# Details  :
#   - Argument $_[2] specifies the character to repeat.
#   - Argument $_[3] specifies the number of repetitions.
#   - Builds the line using CreateLine() and logs it via LogMessage().
#   - If $_[1] (verbose flag) is TRUE, also prints the line to STDOUT.
#
# Returns  : None (side effect: line written to logfile, optionally printed).
################################################################################
sub LogLineVPlus($$$){
    my( $self )    = $_[0];
    my( $verbose ) = $_[1];
    my( $char )    = $_[2];
    my( $size )    = $_[3];
    my( $line ) = undef;
    $line = CreateLine($char,$size);
    $self->LogMessage($line);
    if($verbose){
        print "$line\n";
    }
}

################################################################################
# Function : LogLineDebugVerbose
# Purpose  : Write a line of repeated characters to the logfile.
#
# Details  :
#   - Argument $_[3] specifies the character to repeat.
#   - Argument $_[4] specifies the number of repetitions.
#   - Builds the line using CreateLine().
#   - If $_[2] (debug flag) is TRUE, logs the line via LogMessage().
#   - If $_[1] (verbose flag) is TRUE, prints the line to STDOUT.
#
# Returns  : None (side effect: line written to logfile, optionally printed).
################################################################################
sub LogLineDebugVerbose($$$$){
    my( $self )    = $_[0];
    my( $verbose ) = $_[1];
    my( $debugIn ) = $_[2];
    my( $char )    = $_[3];
    my( $size )    = $_[4];
    my( $line ) = undef;
    $line = CreateLine($char,$size);
    if($debugIn){
        $self->LogMessage($line);
    }
    if($verbose){
        print "$line\n";
    }
}

################################################################################
# Function : LogDebugVerbose
# Purpose  : Log a debug message to the object's logfile.
#
# Details  :
#   - Argument $_[1] acts as the verbosity flag; if TRUE, prints the message to STDOUT.
#   - Argument $_[2] acts as the debug flag; if TRUE, logs the message via LogDebug().
#   - Argument $_[3] is the message string to output and/or log.
#
# Returns  : None (side effect: message logged and/or printed depending on flags).
################################################################################
sub LogDebugVerbose($$$){
    # $_[1] if Verbose
    # $_[2] if debug
    # $_[3] Message
    # print screen if verbose
    # Log to file if debug
    my( $self ) = @_;
    if($_[1]){
      print "$_[3]\n";
    }
    if($_[2]){
      $self->LogDebug("$_[3]");
    }
}

################################################################################
# Function : LogMessageVPlus
# Purpose  : Log a message to the logfile and optionally print it to STDOUT.
#
# Details  :
#   - Argument $_[1] acts as the verbosity flag; if TRUE, prints the message.
#   - Argument $_[2] is the message string to output and log.
#   - Always logs the message via LogMessage(), regardless of verbosity.
#
# Returns  : None (side effect: message logged, optionally printed).
################################################################################
sub LogMessageVPlus($$){
    # Log message, and print screen if verbose
    my( $self ) = @_;
    if($_[1]){
      print "$_[2]\n";
    }
    $self->LogMessage($_[2]);
}

################################################################################
# Function : LogDebug
# Purpose  : Log a debug message to the object's logfile.
#
# Details  :
#   - Accepts a message string as argument ($_[1]).
#   - Prefixes the message with "DEBUG:" for clarity.
#   - Delegates to LogMessage() to append the formatted message to the logfile.
#
# Returns  : None (side effect: debug message written to logfile).
################################################################################
sub LogDebug($){
    my( $self ) = @_;
    $self->LogMessage("DEBUG: $_[1]");
}

################################################################################
# Function : LogDebugSwtch
# Purpose  : Conditionally log a debug message based on a flag.
#
# Details  :
#   - Argument $_[1] acts as the switch flag; if TRUE, the message is logged.
#   - Argument $_[2] is the message string to log.
#   - Delegates to LogDebug() for actual logging when the flag is enabled.
#
# Returns  : None (side effect: debug message logged if switch is TRUE).
################################################################################
sub LogDebugSwtch($$){
    my( $self ) = @_;
    if($_[1]){
        $self->LogDebug("$_[2]");
    }
}

################################################################################
# Function : LogError
# Purpose  : Log an error message to the object's logfile.
#
# Details  :
#   - Accepts a message string as argument ($_[1]).
#   - Prefixes the message with "ERROR:" for clarity.
#   - Delegates to LogMessage() to append the formatted message to the logfile.
#
# Returns  : None (side effect: error message written to logfile).
################################################################################
sub LogError($){
    my( $self ) = @_;
    $self->LogMessage("ERROR: $_[1]");
}

################################################################################
# Function : LogErrorVPlus
# Purpose  : Log an error message to the logfile and optionally print it to STDOUT.
#
# Details  :
#   - Argument $_[1] acts as the verbosity flag; if TRUE, prints the error message.
#   - Argument $_[2] is the error message string to output and log.
#   - Always logs the error via LogError(), regardless of verbosity.
#
# Returns  : None (side effect: error message logged, optionally printed).
################################################################################
sub LogErrorVPlus($$){
    # Log message, and print screen if verbose
    my( $self ) = @_;
    if($_[1]){
        print "ERROR: $_[2]\n";
    }
    $self->LogError("$_[2]");
}

################################################################################
# Function : LogWarn
# Purpose  : Log a warning message to the object's logfile.
#
# Details  :
#   - Accepts a message string as argument ($_[1]).
#   - Prefixes the message with "WARNING:" for clarity.
#   - Delegates to LogMessage() to append the formatted message to the logfile.
#
# Returns  : None (side effect: warning message written to logfile).
################################################################################
sub LogWarn($){
    my( $self ) = @_;
    $self->LogMessage("WARNING: $_[1]");
}

################################################################################
# Function : LogWarnVPlus
# Purpose  : Log a warning message to the logfile and optionally print it to STDOUT.
#
# Details  :
#   - Argument $_[1] acts as the verbosity flag; if TRUE, prints the warning message.
#   - Argument $_[2] is the warning message string to output and log.
#   - Always logs the warning via LogWarn(), regardless of verbosity.
#
# Returns  : None (side effect: warning message logged, optionally printed).
################################################################################
sub LogWarnVPlus($$){
    # Log message, and print screen if verbose
    my( $self ) = @_;
    if($_[1]){
        print "WARNING: $_[2]\n";
    }
    $self->LogWarn("$_[2]");
}

################################################################################
# Function : RenameLog
# Purpose  : Rename the current logfile to a new filename.
#
# Details  :
#   - Checks if the existing logfile ($self->{'file'}) exists.
#   - Attempts to rename it to the new filename provided in $_[1].
#   - If rename fails, prints a permission-related error message.
#   - Updates $self->{'file'} to the new filename, or defaults to "./default.log".
#   - If the original logfile does not exist, prints an error message.
#
# Returns  : None (side effect: logfile renamed or error message printed).
################################################################################
sub RenameLog($){
    my( $self ) = @_;
    if (-e $self->{'file'}){
        rename($self->{'file'},$_[1]) || 
          print "Rename of $self->{'file'} failed, do you have permission to rename?";
        $self -> {'file'}  = $_[1] || "./default.log";
    } else{
        print "RenameLog failed as the given log does not exist!\n";
    }
}

#############################################################################
# Module terminator
#############################################################################
1;