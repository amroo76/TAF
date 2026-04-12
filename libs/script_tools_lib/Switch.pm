package Switch;
#############################################################################
# Switch
#
# Created: August 2025
# Last Modified: January 2026
#
# This file is part of the Test Automation Framework (TAF).
#
# ORIGINAL AUTHORSHIP AND PROVENANCE:
#     This module is an internal, borrowed library. The Switch module was
#     originally written by Damian Conway and later maintained by
#     Rafael Garcia-Suarez and the Perl 5 Porters as part of the Perl core.
#
#     All original upstream copyright notices, authorship statements,
#     and licensing terms remain in full effect.
#
# TAF INTEGRATION:
#     Additional glue code, integration hooks, and contributor-proof headers
#     were added by the MariaDB Foundation for use within the Test Automation
#     Framework. These additions do not alter upstream behavior or licensing.
#
# Copyright:
#  Original upstream copyright:
#   Licensed under the same terms as Perl itself.
#   See the Switch module documentation and Perl core distribution.
#
#TAF integration and header additions:
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
#     Provide a generalized switch/case control structure for Perl. This module
#     augments standard Perl syntax with switch and case statements supporting
#     multiple matching semantics, including numeric, string, regex, array or
#     hash membership, and subroutine evaluation.
#
# ARCHITECTURAL ROLE:
#     - Acts as a convenience control-flow extension for toolsLib and TAF
#       components that benefit from switch/case semantics.
#     - Provides Perl 5 and optional Perl 6-style (given/when) syntax.
#     - Supports higher-order operations via the imported __ placeholder.
#     - Offers deterministic behavior for case matching across multiple types.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not replace native Perl control structures.
#     - Does not guarantee correct behavior inside string eval.
#     - Does not avoid all source-filter edge cases.
#     - Does not validate case expressions or enforce type constraints.
#
# CONTRACT:
#     - switch(EXPR) must cache the expression for subsequent case testing.
#     - case(EXPR) must select matching semantics based on the types of both
#       the switch value and the case argument.
#     - Successful case execution must exit the enclosing switch block unless
#       fall-through is explicitly enabled.
#     - All behavior must remain consistent with upstream Switch semantics.
#
# GUARANTEES:
#     - Upstream behavior is preserved exactly.
#     - No silent fall-through unless explicitly enabled.
#     - No modification of Perl core semantics.
#     - TAF-specific integration is isolated and documented.
#
# NOTES:
#     - This module is included for convenience; contributors should prefer
#       native Perl control structures where possible.
#     - Any changes to integration behavior must be reflected in this header
#       and in the TAF manual.
#############################################################################
use strict;
use vars qw($VERSION);
use Carp;

use if $] >= 5.011, 'deprecate';

$VERSION = '2.16';
  

# LOAD FILTERING MODULE...
use Filter::Util::Call;

sub __();

# CATCH ATTEMPTS TO CALL case OUTSIDE THE SCOPE OF ANY switch

$::_S_W_I_T_C_H = sub { croak "case/when statement not in switch/given block" };

my $offset;
my $fallthrough;
my ($Perl5, $Perl6) = (0,0);

#------------------------------------------------------------------------------
# Subroutines : import, unimport
#
# Purpose:
#   Provide module import and unimport hooks for Switch.pm. These routines
#   configure optional behaviors (fallthrough, Perl5/Perl6 syntax, higher-order
#   placeholder __) and manage source filtering during module use/unuse.
#
# Globals Used:
#   $fallthrough - Flag indicating whether case fall-through is enabled
#   $offset      - Line offset for source filtering
#   $Perl5       - Flag enabling Perl 5 style switch/case syntax
#   $Perl6       - Flag enabling Perl 6 style given/when syntax
#
# Parameters (import):
#   @_ - List of import arguments, may include:
#        - 'fallthrough' : enable case fall-through by default
#        - 'Perl5'       : enable Perl 5 style syntax (default)
#        - 'Perl6'       : enable Perl 6 style syntax
#        - '__'          : import higher-order placeholder subroutine
#        - 'noimport'    : suppress automatic filter_add
#
# Behavior (import):
#   - Sets $fallthrough if 'fallthrough' is present.
#   - Sets $offset to caller line + 1.
#   - Adds source filter unless 'noimport' specified.
#   - Installs helper subs (on_defined, on_exists) into caller package.
#   - Installs placeholder __ if requested.
#   - Sets $Perl5/$Perl6 flags based on arguments.
#   - Returns true.
#
# Behavior (unimport):
#   - Removes source filter via filter_del().
#
# Returns:
#   import   : Always returns true after setup.
#   unimport : No explicit return; cleans up filter state.
#
# Notes:
#   - INTERNAL routines; not intended for external callers.
#   - These hooks are automatically invoked when Switch.pm is used or un-used.
#   - Ensure Filter::Util::Call is available for filter_add/filter_del.
#------------------------------------------------------------------------------
sub import
{
    $fallthrough = grep /\bfallthrough\b/, @_;
    $offset = (caller)[2]+1;
    filter_add({}) unless @_>1 && $_[1] eq 'noimport';
    my $pkg = caller;
    no strict 'refs';
    for ( qw( on_defined on_exists ) )
    {
        *{"${pkg}::$_"} = \&$_;
    }
    *{"${pkg}::__"} = \&__ if grep /__/, @_;
    $Perl6 = 1 if grep(/Perl\s*6/i, @_);
    $Perl5 = 1 if grep(/Perl\s*5/i, @_) || !grep(/Perl\s*6/i, @_);
    1;
}

sub unimport
{   
    filter_del()
}

#------------------------------------------------------------------------------
# Subroutine : filter
#
# Purpose:
#   Source filter callback invoked during compilation. Reads and processes
#   chunks of Perl source code, applies block filtering, and adjusts line
#   numbering for accurate diagnostics.
#
# Globals Used:
#   $Switch::file - Localized to caller filename for filter context
#   $offset       - Line offset used to adjust reported line numbers
#
# Parameters:
#   $self (hashref) - Caller object reference (unused, required by filter API)
#
# Behavior:
#   - Localizes $Switch::file to the caller  filename.
#   - Initializes $status to 1.
#   - Calls filter_read() to read up to 1,000,000 characters of source.
#       - If filter_read() returns < 0, immediately returns that status.
#   - Passes the read source through filter_blocks(), applying transformations
#     based on $offset.
#   - If $offset is set:
#       - Prepends a "# line $offset" directive to the source.
#       - Clears $offset after use.
#   - Returns the final $status value to the filter mechanism.
#
# Returns:
#   Integer - Status code from filter_read() or 1 on success
#
# Notes:
#   - INTERNAL routine; not intended for external callers.
#   - Relies on Filter::Util::Call for filter_read() and custom filter_blocks().
#   - Ensures line numbers in diagnostics remain consistent with original source.
#------------------------------------------------------------------------------
sub filter
{
    my($self) = @_ ;
    local $Switch::file = (caller)[1];

    my $status = 1;
    $status = filter_read(1_000_000);
    return $status if $status<0;
        $_ = filter_blocks($_,$offset);
    $_ = "# line $offset\n" . $_ if $offset; undef $offset;
    return $status;
}

#------------------------------------------------------------------------------
# Section    : Text::Balanced utilities and helpers
#
# Purpose:
#   Provide supporting routines and regex patterns for source filtering and
#   block detection within Switch.pm. These utilities assist in parsing Perl
#   code safely and consistently.
#
# Dependencies:
#   use Text::Balanced ':ALL' - imports balanced text extraction functions
#   required for parsing nested blocks and delimiters.
#
# Subroutine : line
#   - Parameters: $pretext (string), $offset (int, optional)
#   - Behavior  : Counts newline characters in $pretext and adds $offset.
#   - Returns   : Integer line count adjusted by offset.
#
# Subroutine : is_block
#   - Parameters: $_[0] (string expression to evaluate)
#   - Behavior  :
#       - Temporarily enables warnings and traps them as fatal.
#       - Evaluates expression as a hash reference assignment.
#       - Determines whether the input is a block (non-hash).
#   - Returns   : Boolean (true if block, false if hash).
#
# Variable   : $pod_or_DATA
#   - Regex pattern that matches POD sections (=head1 |=cut) or special
#     __DATA__/__END__ markers in Perl source.
#   - Used to skip or handle documentation/data segments during filtering.
#
# Notes:
#   - INTERNAL utilities; not intended for external callers.
#   - Ensure Text::Balanced is available for balanced parsing operations.
#   - These helpers support the source filter logic in Switch.pm.
#------------------------------------------------------------------------------
use Text::Balanced ':ALL';

sub line
{
    my ($pretext,$offset) = @_;
    ($pretext=~tr/\n/\n/)+($offset||0);
}

sub is_block
{
    local $SIG{__WARN__}=sub{die$@};
    local $^W=1;
    my $ishash = defined  eval 'my $hr='.$_[0];
    undef $@;
    return !$ishash;
}

my $pod_or_DATA = qr/ ^=[A-Za-z] .*? ^=cut (?![A-Za-z]) .*? $
            | ^__(DATA|END)__\n.*
            /smx;

#------------------------------------------------------------------------------
# Subroutine : filter_blocks
#
# Purpose:
#   Parse and transform Perl source code containing Switch.pm constructs
#   (`switch`/`case` for Perl 5, `given`/`when`/`default` for Perl 6) into
#   equivalent executable Perl code. Ensures correct semantics, block handling,
#   and fall-through behavior during compilation.
#
# Globals Used:
#   $Perl5, $Perl6   - Flags indicating which syntax mode is active
#   $fallthrough     - Flag controlling case fall-through behavior
#   $casecounter     - Global counter used to generate unique case labels
#   $Switch::file    - Current source filename for error reporting
#   $pod_or_DATA     - Regex pattern for POD or __DATA__/__END__ sections
#
# Parameters:
#   $source (string) - Raw Perl source text to be filtered
#   $line   (int)    - Current line offset for error reporting
#
# Behavior:
#   - Returns $source unchanged unless it contains switch/case (Perl 5) or
#     given/when/default (Perl 6) keywords.
#   - Iterates through source text, component by component:
#       - Rewrites `use Switch` to `use Switch 'noimport'`.
#       - Preserves quoted strings, variables, and POD/DATA blocks.
#       - Detects `switch`/`given` statements:
#           - Extracts argument expression.
#           - Wraps block in a `S_W_I_T_C_H: while (1)` loop.
#           - Injects call to Switch::switch with argument.
#       - Detects `case`/`when`/`default` statements:
#           - Validates syntax and extracts code block or expression.
#           - Wraps block in conditional `if (Switch::case(...))` or `if (1)` for default.
#           - Ensures proper termination (`last S_W_I_T_C_H`) unless fall-through enabled.
#           - Generates unique labels using $casecounter for control flow.
#       - Preserves other tokens and comments verbatim.
#   - On syntax errors (bad parentheses, missing braces, invalid case values),
#     dies with descriptive message including filename and line number.
#
# Returns:
#   String - Transformed Perl source code with Switch constructs rewritten
#
# Notes:
#   - INTERNAL routine; not intended for external callers.
#   - Relies heavily on Text::Balanced for parsing code blocks, variables,
#     and quotelike constructs.
#   - Ensures compatibility with both Perl 5 and Perl 6 style switch syntax.
#   - Maintains accurate error reporting by tracking line offsets.
#------------------------------------------------------------------------------
my $casecounter = 1;
sub filter_blocks
{
    my ($source, $line) = @_;
    return $source unless $Perl5 && $source =~ /case|switch/
               || $Perl6 && $source =~ /when|given|default/;
    pos $source = 0;
    my $text = "";
    component: while (pos $source < length $source)
    {
        if ($source =~ m/(\G\s*use\s+Switch\b)/gc)
        {
            $text .= q{use Switch 'noimport'};
            next component;
        }
        my @pos = Text::Balanced::_match_quotelike(\$source,qr/\s*/,1,0);
        if (defined $pos[0])
        {
            my $pre = substr($source,$pos[0],$pos[1]); # matched prefix
                        my $iEol;
                        if( substr($source,$pos[4],$pos[5]) eq '/' && # 1st delimiter
                            substr($source,$pos[2],$pos[3]) eq '' && # no op like 'm'
                            index( substr($source,$pos[16],$pos[17]), 'x' ) == -1 && # no //x
                            ($iEol = index( $source, "\n", $pos[4] )) > 0         &&
                            $iEol < $pos[8] ){ # embedded newlines
                            # If this is a pattern, it isn't compatible with Switch. Backup past 1st '/'.
                            pos( $source ) = $pos[6];
                $text .= $pre . substr($source,$pos[2],$pos[6]-$pos[2]);
            } else {
                $text .= $pre . substr($source,$pos[2],$pos[18]-$pos[2]);
            }
            next component;
        }
        if ($source =~ m/(\G\s*$pod_or_DATA)/gc) {
            $text .= $1;
            next component;
        }
        @pos = Text::Balanced::_match_variable(\$source,qr/\s*/);
        if (defined $pos[0])
        {
            $text .= " " if $pos[0] < $pos[2];
            $text .= substr($source,$pos[0],$pos[4]-$pos[0]);
            next component;
        }

        if ($Perl5 && $source =~ m/\G(\n*)(\s*)(switch)\b(?=\s*[(])/gc
         || $Perl6 && $source =~ m/\G(\n*)(\s*)(given)\b(?=\s*[(])/gc
         || $Perl6 && $source =~ m/\G(\n*)(\s*)(given)\b(.*)(?=\{)/gc)
        {
            my $keyword = $3;
            my $arg = $4;
            $text .= $1.$2.'S_W_I_T_C_H: while (1) ';
            unless ($arg) {
                @pos = Text::Balanced::_match_codeblock(\$source,qr/\s*/,qr/\(/,qr/\)/,qr/[[{(<]/,qr/[]})>]/,undef) 
                or do {
                    die "Bad $keyword statement (problem in the parentheses?) near $Switch::file line ", line(substr($source,0,pos $source),$line), "\n";
                };
                $arg = filter_blocks(substr($source,$pos[0],$pos[4]-$pos[0]),line(substr($source,0,$pos[0]),$line));
            }
            $arg =~ s {^\s*[(]\s*%}   { ( \\\%} ||
            $arg =~ s {^\s*[(]\s*m\b} { ( qr}   ||
            $arg =~ s {^\s*[(]\s*/}   { ( qr/}  ||
            $arg =~ s {^\s*[(]\s*qw}  { ( \\qw};
            @pos = Text::Balanced::_match_codeblock(\$source,qr/\s*/,qr/\{/,qr/\}/,qr/\{/,qr/\}/,undef)
            or do {
                die "Bad $keyword statement (problem in the code block?) near $Switch::file line ", line(substr($source,0, pos $source), $line), "\n";
            };
            my $code = filter_blocks(substr($source,$pos[0],$pos[4]-$pos[0]),line(substr($source,0,$pos[0]),$line));
            $code =~ s/{/{ local \$::_S_W_I_T_C_H; Switch::switch $arg;/;
            $text .= $code . 'continue {last}';
            next component;
        }
        elsif ($Perl5 && $source =~ m/\G(\s*)(case\b)(?!\s*=>)/gc
            || $Perl6 && $source =~ m/\G(\s*)(when\b)(?!\s*=>)/gc
            || $Perl6 && $source =~ m/\G(\s*)(default\b)(?=\s*\{)/gc)
        {
            my $keyword = $2;
            $text .= $1 . ($keyword eq "default"
                    ? "if (1)"
                    : "if (Switch::case");

            if ($keyword eq "default") {
                # Nothing to do
            }
            elsif (@pos = Text::Balanced::_match_codeblock(\$source,qr/\s*/,qr/\{/,qr/\}/,qr/\{/,qr/\}/,undef)) {
                my $code = substr($source,$pos[0],$pos[4]-$pos[0]);
                $text .= " " if $pos[0] < $pos[2];
                $text .= "sub " if is_block $code;
                $text .= filter_blocks($code,line(substr($source,0,$pos[0]),$line)) . ")";
            }
            elsif (@pos = Text::Balanced::_match_codeblock(\$source,qr/\s*/,qr/[[(]/,qr/[])]/,qr/[[({]/,qr/[])}]/,undef)) {
                my $code = filter_blocks(substr($source,$pos[0],$pos[4]-$pos[0]),line(substr($source,0,$pos[0]),$line));
                $code =~ s {^\s*[(]\s*%}   { ( \\\%}    ||
                $code =~ s {^\s*[(]\s*m\b} { ( qr}  ||
                $code =~ s {^\s*[(]\s*/}   { ( qr/} ||
                $code =~ s {^\s*[(]\s*qw}  { ( \\qw};
                $text .= " " if $pos[0] < $pos[2];
                $text .= "$code)";
            }
            elsif ($Perl6 && do{@pos = Text::Balanced::_match_variable(\$source,qr/\s*/)}) {
                my $code = filter_blocks(substr($source,$pos[0],$pos[4]-$pos[0]),line(substr($source,0,$pos[0]),$line));
                $code =~ s {^\s*%}  { \%}   ||
                $code =~ s {^\s*@}  { \@};
                $text .= " " if $pos[0] < $pos[2];
                $text .= "$code)";
            }
            elsif ( @pos = Text::Balanced::_match_quotelike(\$source,qr/\s*/,1,0)) {
                my $code = substr($source,$pos[2],$pos[18]-$pos[2]);
                $code = filter_blocks($code,line(substr($source,0,$pos[2]),$line));
                $code =~ s {^\s*m}  { qr}   ||
                $code =~ s {^\s*/}  { qr/}  ||
                $code =~ s {^\s*qw} { \\qw};
                $text .= " " if $pos[0] < $pos[2];
                $text .= "$code)";
            }
            elsif ($Perl5 && $source =~ m/\G\s*(([^\$\@{])[^\$\@{]*)(?=\s*{)/gc
               ||  $Perl6 && $source =~ m/\G\s*([^;{]*)()/gc) {
                my $code = filter_blocks($1,line(substr($source,0,pos $source),$line));
                $text .= ' \\' if $2 eq '%';
                $text .= " $code)";
            }
            else {
                die "Bad $keyword statement (invalid $keyword value?) near $Switch::file line ", line(substr($source,0,pos $source), $line), "\n";
            }

                die "Missing opening brace or semi-colon after 'when' value near $Switch::file line ", line(substr($source,0,pos $source), $line), "\n"
                unless !$Perl6 || $source =~ m/\G(\s*)(?=;|\{)/gc;

            do{@pos = Text::Balanced::_match_codeblock(\$source,qr/\s*/,qr/\{/,qr/\}/,qr/\{/,qr/\}/,undef)}
            or do {
                if ($source =~ m/\G\s*(?=([};]|\Z))/gc) {
                    $casecounter++;
                    next component;
                }
                die "Bad $keyword statement (problem in the code block?) near $Switch::file line ", line(substr($source,0,pos $source),$line), "\n";
            };
            my $code = filter_blocks(substr($source,$pos[0],$pos[4]-$pos[0]),line(substr($source,0,$pos[0]),$line));
            $code =~ s/}(?=\s*\Z)/;last S_W_I_T_C_H }/
                unless $fallthrough;
            $text .= "{ while (1) $code continue { goto C_A_S_E_$casecounter } last S_W_I_T_C_H; C_A_S_E_$casecounter: }";
            $casecounter++;
            next component;
        }

        $source =~ m/\G(\s*(-[sm]\s+|\w+|#.*\n|\W))/gc;
        $text .= $1;
    }
    $text;
}

#------------------------------------------------------------------------------
# Subroutines : in, on_exists, on_defined
#
# Purpose:
#   Provide helper routines for Switch.pm case matching and hash introspection.
#   These utilities support generalized case semantics by enabling array
#   intersection checks and hash key/value filtering.
#
# Globals Used:
#   None explicitly; rely on standard Perl operators and references.
#
# Subroutine : in
#   - Parameters: $x (arrayref), $y (arrayref)
#   - Behavior  :
#       - Iterates over elements of $x and $y.
#       - Determines whether elements are numeric or references.
#       - Compares each pair for equality:
#           - Numeric equality if both are numbers.
#           - String equality otherwise.
#       - Returns 1 immediately on first match.
#       - Returns empty string "" if no matches found.
#   - Returns   : Boolean (true if intersection found, false otherwise).
#
# Subroutine : on_exists
#   - Parameters: Either a hashref or a flat list of key/value pairs.
#   - Behavior  :
#       - Normalizes input to a hashref.
#       - Returns an arrayref of all keys present in the hash.
#   - Returns   : Arrayref of keys.
#
# Subroutine : on_defined
#   - Parameters: Either a hashref or a flat list of key/value pairs.
#   - Behavior  :
#       - Normalizes input to a hashref.
#       - Filters keys whose values are defined.
#       - Returns an arrayref of those keys.
#   - Returns   : Arrayref of keys with defined values.
#
# Notes:
#   - INTERNAL routines; not intended for external callers.
#   - `in` is used to implement array intersection semantics in case matching.
#   - `on_exists` and `on_defined` provide hash introspection for case tests.
#------------------------------------------------------------------------------
sub in
{
    my ($x,$y) = @_;
    my @numy;
    for my $nextx ( @$x )
    {
        my $numx = ref($nextx) || defined $nextx && (~$nextx&$nextx) eq 0;
        for my $j ( 0..$#$y )
        {
            my $nexty = $y->[$j];
            push @numy, ref($nexty) || defined $nexty && (~$nexty&$nexty) eq 0
                if @numy <= $j;
            return 1 if $numx && $numy[$j] && $nextx==$nexty
                     || $nextx eq $nexty;
            
        }
    }
    return "";
}

sub on_exists
{
    my $ref = @_==1 && ref($_[0]) eq 'HASH' ? $_[0] : { @_ };
    [ keys %$ref ]
}

sub on_defined
{
    my $ref = @_==1 && ref($_[0]) eq 'HASH' ? $_[0] : { @_ };
    [ grep { defined $ref->{$_} } keys %$ref ]
}

#------------------------------------------------------------------------------
# Subroutine : switch
#
# Purpose:
#   Initialize the global case-matching closure ($::_S_W_I_T_C_H) based on the
#   type of the provided switch value. Enables generalized case semantics by
#   supporting numeric, string, array, hash, regex, code references, and
#   nested Switch objects.
#
# Globals Used:
#   $::_S_W_I_T_C_H - Closure used by subsequent case statements to test values
#
# Parameters:
#   $s_val (scalar) - Switch value; may be numeric, string, arrayref, hashref,
#                     regex, coderef, or Switch object. Defaults to $_ if not
#                     explicitly passed.
#
# Behavior:
#   - Determines reference type of $s_val and installs a closure into
#     $::_S_W_I_T_C_H that knows how to compare case values against it.
#   - Matching rules by type:
#       - CODE    : Executes coderef with case value(s).
#       - NUMERIC : Compares numerically; supports string equality, array
#                   membership, regex match, hash lookup, or coderef call.
#       - STRING  : Compares by string equality; supports array membership,
#                   regex match, hash lookup, or coderef call.
#       - ARRAY   : Checks intersection with case arrays; supports regex grep,
#                   hash membership, or coderef call.
#       - Regexp  : Matches scalar, array elements, or hash keys against regex.
#       - HASH    : Tests existence/truth of keys; supports array membership,
#                   regex grep, or coderef call.
#       - Switch  : Delegates to another Switch object  call method.
#   - On unsupported types, croaks with an error message.
#
# Returns:
#   Integer 1 on successful setup of $::_S_W_I_T_C_H
#
# Notes:
#   - INTERNAL routine; not intended for external callers.
#   - This is the core of Switch.pm  generalized case mechanism.
#   - Relies on helper subroutines such as `in()` for array intersection.
#   - Ensures that subsequent `case` statements can evaluate against the
#     switch value using the installed closure.
#------------------------------------------------------------------------------
sub switch(;$)
{
    my ($s_val) = @_ ? $_[0] : $_;
    my $s_ref = ref $s_val;
    
    if ($s_ref eq 'CODE')
    {
        $::_S_W_I_T_C_H =
              sub { my $c_val = $_[0];
                return $s_val == $c_val  if ref $c_val eq 'CODE';
                return $s_val->(@$c_val) if ref $c_val eq 'ARRAY';
                return $s_val->($c_val);
              };
    }
    elsif ($s_ref eq "" && defined $s_val && (~$s_val&$s_val) eq 0) # NUMERIC SCALAR
    {
        $::_S_W_I_T_C_H =
              sub { my $c_val = $_[0];
                my $c_ref = ref $c_val;
                return $s_val == $c_val     if $c_ref eq ""
                            && defined $c_val
                            && (~$c_val&$c_val) eq 0;
                return $s_val eq $c_val     if $c_ref eq "";
                return in([$s_val],$c_val)  if $c_ref eq 'ARRAY';
                return $c_val->($s_val) if $c_ref eq 'CODE';
                return $c_val->call($s_val) if $c_ref eq 'Switch';
                return scalar $s_val=~/$c_val/
                            if $c_ref eq 'Regexp';
                return scalar $c_val->{$s_val}
                            if $c_ref eq 'HASH';
                    return; 
              };
    }
    elsif ($s_ref eq "")                # STRING SCALAR
    {
        $::_S_W_I_T_C_H =
              sub { my $c_val = $_[0];
                my $c_ref = ref $c_val;
                return $s_val eq $c_val     if $c_ref eq "";
                return in([$s_val],$c_val)  if $c_ref eq 'ARRAY';
                return $c_val->($s_val) if $c_ref eq 'CODE';
                return $c_val->call($s_val) if $c_ref eq 'Switch';
                return scalar $s_val=~/$c_val/
                            if $c_ref eq 'Regexp';
                return scalar $c_val->{$s_val}
                            if $c_ref eq 'HASH';
                    return; 
              };
    }
    elsif ($s_ref eq 'ARRAY')
    {
        $::_S_W_I_T_C_H =
              sub { my $c_val = $_[0];
                my $c_ref = ref $c_val;
                return in($s_val,[$c_val])  if $c_ref eq "";
                return in($s_val,$c_val)    if $c_ref eq 'ARRAY';
                return $c_val->(@$s_val)    if $c_ref eq 'CODE';
                return $c_val->call(@$s_val)
                            if $c_ref eq 'Switch';
                return scalar grep {$_=~/$c_val/} @$s_val
                            if $c_ref eq 'Regexp';
                return scalar grep {$c_val->{$_}} @$s_val
                            if $c_ref eq 'HASH';
                    return; 
              };
    }
    elsif ($s_ref eq 'Regexp')
    {
        $::_S_W_I_T_C_H =
              sub { my $c_val = $_[0];
                my $c_ref = ref $c_val;
                return $c_val=~/s_val/  if $c_ref eq "";
                return scalar grep {$_=~/s_val/} @$c_val
                            if $c_ref eq 'ARRAY';
                return $c_val->($s_val) if $c_ref eq 'CODE';
                return $c_val->call($s_val) if $c_ref eq 'Switch';
                return $s_val eq $c_val if $c_ref eq 'Regexp';
                return grep {$_=~/$s_val/ && $c_val->{$_}} keys %$c_val
                            if $c_ref eq 'HASH';
                    return; 
              };
    }
    elsif ($s_ref eq 'HASH')
    {
        $::_S_W_I_T_C_H =
              sub { my $c_val = $_[0];
                my $c_ref = ref $c_val;
                return $s_val->{$c_val}     if $c_ref eq "";
                return scalar grep {$s_val->{$_}} @$c_val
                            if $c_ref eq 'ARRAY';
                return $c_val->($s_val) if $c_ref eq 'CODE';
                return $c_val->call($s_val) if $c_ref eq 'Switch';
                return grep {$_=~/$c_val/ && $s_val->{"$_"}} keys %$s_val
                            if $c_ref eq 'Regexp';
                return $s_val==$c_val   if $c_ref eq 'HASH';
                    return; 
              };
    }
    elsif ($s_ref eq 'Switch')
    {
        $::_S_W_I_T_C_H =
              sub { my $c_val = $_[0];
                return $s_val == $c_val  if ref $c_val eq 'Switch';
                return $s_val->call(@$c_val)
                             if ref $c_val eq 'ARRAY';
                return $s_val->call($c_val);
              };
    }
    else
    {
        croak "Cannot switch on $s_ref";
    }
    return 1;
}

#------------------------------------------------------------------------------
# Subroutines : case, __, __arg, hosub, call, meta_bop, meta_uop
#
# Purpose:
#   Implement generalized case evaluation and higher-order operations for
#   Switch.pm. These routines provide the glue between the global switch
#   closure ($::_S_W_I_T_C_H), placeholder arguments, and operator overloading
#   used to construct lazy evaluation expressions.
#
# Globals Used:
#   $::_S_W_I_T_C_H - Closure installed by switch() to test case values
#   $placeholder    - Default higher-order placeholder (__)
#
# Subroutine : case($)
#   - Invokes the current $::_S_W_I_T_C_H closure with the provided argument.
#   - Temporarily redirects warnings to carp().
#   - Returns result of case evaluation.
#
# Subroutine : __()
#   - Returns the global placeholder object.
#   - Used in expressions to build higher-order functions (e.g. __ < 10).
#
# Subroutine : __arg($)
#   - Creates a new placeholder object for a specific argument index.
#   - Returns a blessed object with arity 0 and impl closure.
#
# Subroutine : hosub(&@)
#   - Intended to wrap a block into a higher-order subroutine.
#   - Placeholder for implementation; integrates with operator overloading.
#
# Subroutine : call
#   - Executes the impl closure of a Switch object with provided arguments.
#   - Returns computed value.
#
# Subroutine : meta_bop(&)
#   - Higher-order binary operator constructor.
#   - Parameters: $op (coderef implementing binary operation).
#   - Returns a closure that combines left and right operands (Switch objects
#     or scalars) into a new Switch object with appropriate arity and impl.
#
# Subroutine : meta_uop(&)
#   - Higher-order unary operator constructor.
#   - Parameters: $op (coderef implementing unary operation).
#   - Returns a closure that wraps a single operand (Switch object or scalar)
#     into a new Switch object with appropriate arity and impl.
#
# Notes:
#   - INTERNAL routines; not intended for external callers.
#   - Provide the operator overloading backbone for  placeholder
#     (__), enabling lazy evaluation of expressions in case statements.
#   - Ensure that case matching can be expressed naturally using Perl operators.
#------------------------------------------------------------------------------
sub case($) { local $SIG{__WARN__} = \&carp;
          $::_S_W_I_T_C_H->(@_); }

# IMPLEMENT __

my $placeholder = bless { arity=>1, impl=>sub{$_[1+$_[0]]} };

sub __() { $placeholder }

sub __arg($)
{
    my $index = $_[0]+1;
    bless { arity=>0, impl=>sub{$_[$index]} };
}

sub hosub(&@)
{
    # WRITE THIS
}

sub call
{
    my ($self,@args) = @_;
    return $self->{impl}->(0,@args);
}

sub meta_bop(&)
{
    my ($op) = @_;
    sub
    {
        my ($left, $right, $reversed) = @_;
        ($right,$left) = @_ if $reversed;

        my $rop = ref $right eq 'Switch'
            ? $right
            : bless { arity=>0, impl=>sub{$right} };

        my $lop = ref $left eq 'Switch'
            ? $left
            : bless { arity=>0, impl=>sub{$left} };

        my $arity = $lop->{arity} + $rop->{arity};

        return bless {
                arity => $arity,
                impl  => sub { my $start = shift;
                           return $op->($lop->{impl}->($start,@_),
                                    $rop->{impl}->($start+$lop->{arity},@_));
                         }
                 };
    };
}

sub meta_uop(&)
{
    my ($op) = @_;
    sub
    {
        my ($left) = @_;

        my $lop = ref $left eq 'Switch'
            ? $left
            : bless { arity=>0, impl=>sub{$left} };

        my $arity = $lop->{arity};

        return bless {
                arity => $arity,
                impl  => sub { $op->($lop->{impl}->(@_)) }
                 };
    };
}

#------------------------------------------------------------------------------
# Section    : Operator Overloading (use overload)
#
# Purpose:
#   Define overloaded operators for Switch.pm placeholder objects, enabling
#   higher-order expressions (e.g. __ < 10, __ + 5) to be converted into
#   lazy evaluation subroutines. Provides both binary and unary operator
#   support via meta_bop and meta_uop constructors.
#
# Globals Used:
#   Relies on meta_bop() and meta_uop() helper routines to construct Switch
#   objects with appropriate arity and impl closures.
#
# Behavior:
#   - Binary operators (+, -, *, /, %, **, <<, >>, x, ., comparison, bitwise,
#     string comparison, atan2) are mapped to meta_bop closures.
#   - Unary operators (negation, logical not, bitwise not, cos, sin, exp, abs,
#     log, sqrt) are mapped to meta_uop closures.
#   - The "bool" overload explicitly croaks if && or || are used in expressions
#     containing __, since Perl does not allow overloading of short-circuit
#     boolean operators.
#   - Fallback is disabled (commented out), ensuring only defined overloads
#     are active.
#
# Returns:
#   Overloaded Switch objects that behave like lazy higher-order functions
#   when used in expressions.
#
# Notes:
#   - INTERNAL section; not intended for external callers.
#   - Provides the operator overloading backbone for the placeholder (__),
#     enabling concise case expressions in Switch.pm.
#   - && and || cannot be safely overloaded; attempting to use them with __
#     will throw an error.
#------------------------------------------------------------------------------
use overload
    "+" =>  meta_bop {$_[0] + $_[1]},
    "-" =>  meta_bop {$_[0] - $_[1]},  
    "*" =>      meta_bop {$_[0] * $_[1]},
    "/" =>      meta_bop {$_[0] / $_[1]},
    "%" =>      meta_bop {$_[0] % $_[1]},
    "**"    =>      meta_bop {$_[0] ** $_[1]},
    "<<"    =>      meta_bop {$_[0] << $_[1]},
    ">>"    =>      meta_bop {$_[0] >> $_[1]},
    "x" =>      meta_bop {$_[0] x $_[1]},
    "." =>      meta_bop {$_[0] . $_[1]},
    "<" =>      meta_bop {$_[0] < $_[1]},
    "<="    =>      meta_bop {$_[0] <= $_[1]},
    ">" =>      meta_bop {$_[0] > $_[1]},
    ">="    =>      meta_bop {$_[0] >= $_[1]},
    "=="    =>      meta_bop {$_[0] == $_[1]},
    "!="    =>      meta_bop {$_[0] != $_[1]},
    "<=>"   =>      meta_bop {$_[0] <=> $_[1]},
    "lt"    =>      meta_bop {$_[0] lt $_[1]},
    "le"    =>  meta_bop {$_[0] le $_[1]},
    "gt"    =>  meta_bop {$_[0] gt $_[1]},
    "ge"    =>  meta_bop {$_[0] ge $_[1]},
    "eq"    =>  meta_bop {$_[0] eq $_[1]},
    "ne"    =>  meta_bop {$_[0] ne $_[1]},
    "cmp"   =>  meta_bop {$_[0] cmp $_[1]},
    "\&"    =>  meta_bop {$_[0] & $_[1]},
    "^" =>  meta_bop {$_[0] ^ $_[1]},
    "|" =>  meta_bop {$_[0] | $_[1]},
    "atan2" =>  meta_bop {atan2 $_[0], $_[1]},

    "neg"   =>  meta_uop {-$_[0]},
    "!" =>  meta_uop {!$_[0]},
    "~" =>  meta_uop {~$_[0]},
    "cos"   =>  meta_uop {cos $_[0]},
    "sin"   =>  meta_uop {sin $_[0]},
    "exp"   =>  meta_uop {exp $_[0]},
    "abs"   =>  meta_uop {abs $_[0]},
    "log"   =>  meta_uop {log $_[0]},
    "sqrt"  =>  meta_uop {sqrt $_[0]},
    "bool"  =>  sub { croak "Can't use && or || in expression containing __" },

    #   "&()"   =>  sub { $_[0]->{impl} },

    #   "||"    =>  meta_bop {$_[0] || $_[1]},
    #   "&&"    =>  meta_bop {$_[0] && $_[1]},
    # fallback => 1,
    ;
1;

__END__


=head1 NAME

Switch - A switch statement for Perl

=head1 SYNOPSIS

    use Switch;

    switch ($val) {
    case 1      { print "number 1" }
    case "a"    { print "string a" }
    case [1..10,42] { print "number in list" }
    case (\@array)  { print "number in list" }
    case /\w+/  { print "pattern" }
    case qr/\w+/    { print "pattern" }
    case (\%hash)   { print "entry in hash" }
    case (\&sub)    { print "arg to subroutine" }
    else        { print "previous case not true" }
    }

=head1 BACKGROUND

[Skip ahead to L<"DESCRIPTION"> if you don't care about the whys
and wherefores of this control structure]

In seeking to devise a "Swiss Army" case mechanism suitable for Perl,
it is useful to generalize this notion of distributed conditional
testing as far as possible. Specifically, the concept of "matching"
between the switch value and the various case values need not be
restricted to numeric (or string or referential) equality, as it is in other 
languages. Indeed, as Table 1 illustrates, Perl
offers at least eighteen different ways in which two values could
generate a match.

    Table 1: Matching a switch value ($s) with a case value ($c)

        Switch  Case    Type of Match Implied   Matching Code
        Value   Value   
        ======  =====   =====================   =============

        number  same    numeric or referential  match if $s == $c;
        or ref          equality

    object  method  result of method call   match if $s->$c();
    ref     name                match if defined $s->$c();
        or ref

        other   other   string equality         match if $s eq $c;
        non-ref non-ref
        scalar  scalar

        string  regexp  pattern match           match if $s =~ /$c/;

        array   scalar  array entry existence   match if 0<=$c && $c<@$s;
        ref             array entry definition  match if defined $s->[$c];
                        array entry truth       match if $s->[$c];

        array   array   array intersection      match if intersects(@$s, @$c);
        ref     ref     (apply this table to
                         all pairs of elements
                         $s->[$i] and
                         $c->[$j])

        array   regexp  array grep              match if grep /$c/, @$s;
        ref     

        hash    scalar  hash entry existence    match if exists $s->{$c};
        ref             hash entry definition   match if defined $s->{$c};
                        hash entry truth        match if $s->{$c};

        hash    regexp  hash grep               match if grep /$c/, keys %$s;
        ref     

        sub     scalar  return value defn       match if defined $s->($c);
        ref             return value truth      match if $s->($c);

        sub     array   return value defn       match if defined $s->(@$c);
        ref     ref     return value truth      match if $s->(@$c);


In reality, Table 1 covers 31 alternatives, because only the equality and
intersection tests are commutative; in all other cases, the roles of
the C<$s> and C<$c> variables could be reversed to produce a
different test. For example, instead of testing a single hash for
the existence of a series of keys (C<match if exists $s-E<gt>{$c}>),
one could test for the existence of a single key in a series of hashes
(C<match if exists $c-E<gt>{$s}>).

=head1 DESCRIPTION

The Switch.pm module implements a generalized case mechanism that covers
most (but not all) of the numerous possible combinations of switch and case
values described above.

The module augments the standard Perl syntax with two new control
statements: C<switch> and C<case>. The C<switch> statement takes a
single scalar argument of any type, specified in parentheses.
C<switch> stores this value as the
current switch value in a (localized) control variable.
The value is followed by a block which may contain one or more
Perl statements (including the C<case> statement described below).
The block is unconditionally executed once the switch value has
been cached.

A C<case> statement takes a single scalar argument (in mandatory
parentheses if it's a variable; otherwise the parens are optional) and
selects the appropriate type of matching between that argument and the
current switch value. The type of matching used is determined by the
respective types of the switch value and the C<case> argument, as
specified in Table 1. If the match is successful, the mandatory
block associated with the C<case> statement is executed.

In most other respects, the C<case> statement is semantically identical
to an C<if> statement. For example, it can be followed by an C<else>
clause, and can be used as a postfix statement qualifier. 

However, when a C<case> block has been executed control is automatically
transferred to the statement after the immediately enclosing C<switch>
block, rather than to the next statement within the block. In other
words, the success of any C<case> statement prevents other cases in the
same scope from executing. But see L<"Allowing fall-through"> below.

Together these two new statements provide a fully generalized case
mechanism:

        use Switch;

        # AND LATER...

        %special = ( woohoo => 1,  d'oh => 1 );

        while (<>) {
        chomp;
            switch ($_) {
                case (%special) { print "homer\n"; }      # if $special{$_}
                case /[a-z]/i   { print "alpha\n"; }      # if $_ =~ /a-z/i
                case [1..9]     { print "small num\n"; }  # if $_ in [1..9]
                case { $_[0] >= 10 } { print "big num\n"; } # if $_ >= 10
                print "must be punctuation\n" case /\W/;  # if $_ ~= /\W/
        }
        }

Note that C<switch>es can be nested within C<case> (or any other) blocks,
and a series of C<case> statements can try different types of matches
-- hash membership, pattern match, array intersection, simple equality,
etc. -- against the same switch value.

The use of intersection tests against an array reference is particularly
useful for aggregating integral cases:

        sub classify_digit
        {
                switch ($_[0]) { case 0            { return 'zero' }
                                 case [2,4,6,8]    { return 'even' }
                                 case [1,3,5,7,9]  { return 'odd' }
                                 case /[A-F]/i     { return 'hex' }
                               }
        }


=head2 Allowing fall-through

Fall-though (trying another case after one has already succeeded)
is usually a Bad Idea in a switch statement. However, this
is Perl, not a police state, so there I<is> a way to do it, if you must.

If a C<case> block executes an untargeted C<next>, control is
immediately transferred to the statement I<after> the C<case> statement
(i.e. usually another case), rather than out of the surrounding
C<switch> block.

For example:

        switch ($val) {
                case 1      { handle_num_1(); next }    # and try next case...
                case "1"    { handle_str_1(); next }    # and try next case...
                case [0..9] { handle_num_any(); }       # and we're done
                case /\d/   { handle_dig_any(); next }  # and try next case...
                case /.*/   { handle_str_any(); next }  # and try next case...
        }

If $val held the number C<1>, the above C<switch> block would call the
first three C<handle_...> subroutines, jumping to the next case test
each time it encountered a C<next>. After the third C<case> block
was executed, control would jump to the end of the enclosing
C<switch> block.

On the other hand, if $val held C<10>, then only the last two C<handle_...>
subroutines would be called.

Note that this mechanism allows the notion of I<conditional fall-through>.
For example:

        switch ($val) {
                case [0..9] { handle_num_any(); next if $val < 7; }
                case /\d/   { handle_dig_any(); }
        }

If an untargeted C<last> statement is executed in a case block, this
immediately transfers control out of the enclosing C<switch> block
(in other words, there is an implicit C<last> at the end of each
normal C<case> block). Thus the previous example could also have been
written:

        switch ($val) {
                case [0..9] { handle_num_any(); last if $val >= 7; next; }
                case /\d/   { handle_dig_any(); }
        }


=head2 Automating fall-through

In situations where case fall-through should be the norm, rather than an
exception, an endless succession of terminal C<next>s is tedious and ugly.
Hence, it is possible to reverse the default behaviour by specifying
the string "fallthrough" when importing the module. For example, the 
following code is equivalent to the first example in L<"Allowing fall-through">:

        use Switch 'fallthrough';

        switch ($val) {
                case 1      { handle_num_1(); }
                case "1"    { handle_str_1(); }
                case [0..9] { handle_num_any(); last }
                case /\d/   { handle_dig_any(); }
                case /.*/   { handle_str_any(); }
        }

Note the explicit use of a C<last> to preserve the non-fall-through
behaviour of the third case.



=head2 Alternative syntax

Perl 6 will provide a built-in switch statement with essentially the
same semantics as those offered by Switch.pm, but with a different
pair of keywords. In Perl 6 C<switch> will be spelled C<given>, and
C<case> will be pronounced C<when>. In addition, the C<when> statement
will not require switch or case values to be parenthesized.

This future syntax is also (largely) available via the Switch.pm module, by
importing it with the argument C<"Perl6">.  For example:

        use Switch 'Perl6';

        given ($val) {
                when 1       { handle_num_1(); }
                when ($str1) { handle_str_1(); }
                when [0..9]  { handle_num_any(); last }
                when /\d/    { handle_dig_any(); }
                when /.*/    { handle_str_any(); }
                default      { handle anything else; }
        }

Note that scalars still need to be parenthesized, since they would be
ambiguous in Perl 5.

Note too that you can mix and match both syntaxes by importing the module
with:

    use Switch 'Perl5', 'Perl6';


=head2 Higher-order Operations

One situation in which C<switch> and C<case> do not provide a good
substitute for a cascaded C<if>, is where a switch value needs to
be tested against a series of conditions. For example:

        sub beverage {
            switch (shift) {
                case { $_[0] < 10 } { return 'milk' }
                case { $_[0] < 20 } { return 'coke' }
                case { $_[0] < 30 } { return 'beer' }
                case { $_[0] < 40 } { return 'wine' }
                case { $_[0] < 50 } { return 'malt' }
                case { $_[0] < 60 } { return 'Moet' }
                else                { return 'milk' }
            }
        }

(This is equivalent to writing C<case (sub { $_[0] < 10 })>, etc.; C<$_[0]>
is the argument to the anonymous subroutine.)

The need to specify each condition as a subroutine block is tiresome. To
overcome this, when importing Switch.pm, a special "placeholder"
subroutine named C<__> [sic] may also be imported. This subroutine
converts (almost) any expression in which it appears to a reference to a
higher-order function. That is, the expression:

        use Switch '__';

        __ < 2

is equivalent to:

        sub { $_[0] < 2 }

With C<__>, the previous ugly case statements can be rewritten:

        case  __ < 10  { return 'milk' }
        case  __ < 20  { return 'coke' }
        case  __ < 30  { return 'beer' }
        case  __ < 40  { return 'wine' }
        case  __ < 50  { return 'malt' }
        case  __ < 60  { return 'Moet' }
        else           { return 'milk' }

The C<__> subroutine makes extensive use of operator overloading to
perform its magic. All operations involving __ are overloaded to
produce an anonymous subroutine that implements a lazy version
of the original operation.

The only problem is that operator overloading does not allow the
boolean operators C<&&> and C<||> to be overloaded. So a case statement
like this:

        case  0 <= __ && __ < 10  { return 'digit' }  

doesn't act as expected, because when it is
executed, it constructs two higher order subroutines
and then treats the two resulting references as arguments to C<&&>:

        sub { 0 <= $_[0] } && sub { $_[0] < 10 }

This boolean expression is inevitably true, since both references are
non-false. Fortunately, the overloaded C<'bool'> operator catches this
situation and flags it as an error. 

=head1 DEPENDENCIES

The module is implemented using Filter::Util::Call and Text::Balanced
and requires both these modules to be installed. 

=head1 AUTHOR

Damian Conway (damian@conway.org). This module is now maintained by Rafael
Garcia-Suarez (rgarciasuarez@gmail.com) and more generally by the Perl 5
Porters (perl5-porters@perl.org), as part of the Perl core.

=head1 BUGS

There are undoubtedly serious bugs lurking somewhere in code this funky :-)
Bug reports and other feedback are most welcome.

=head1 LIMITATIONS

Due to the heuristic nature of Switch.pm's source parsing, the presence of
regexes with embedded newlines that are specified with raw C</.../>
delimiters and don't have a modifier C<//x> are indistinguishable from
code chunks beginning with the division operator C</>. As a workaround
you must use C<m/.../> or C<m?...?> for such patterns. Also, the presence
of regexes specified with raw C<?...?> delimiters may cause mysterious
errors. The workaround is to use C<m?...?> instead.

Due to the way source filters work in Perl, you can't use Switch inside
an string C<eval>.

If your source file is longer then 1 million characters and you have a
switch statement that crosses the 1 million (or 2 million, etc.)
character boundary you will get mysterious errors. The workaround is to
use smaller source files.

=head1 COPYRIGHT

    Copyright (c) 1997-2008, Damian Conway. All Rights Reserved.
    This module is free software. It may be used, redistributed
        and/or modified under the same terms as Perl itself.

