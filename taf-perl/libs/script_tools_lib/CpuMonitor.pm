package CpuMonitor;
# ======================================================================
#  NAME
#    CpuMonitor
#
#  PURPOSE
#    Dependency-free CPU usage monitor for a single process. Provides a
#    deterministic alternative to fixed sleeps during setup and iteration
#    phases. Samples /proc/<pid>/stat to compute CPU usage over a 1-second
#    window and evaluates whether the process has reached a defined "rest"
#    state.
#
#  BEHAVIOR
#    - Tracks a target PID and measures CPU usage once per second.
#    - Maintains a consecutive rest counter based on configured thresholds.
#    - Resets the counter when CPU usage exceeds the reset threshold.
#    - Stops when either:
#         * required consecutive rest samples are reached, or
#         * maximum attempts are exhausted, or
#         * the process disappears.
#    - Intended to replace sleeps when CPU-based readiness detection is
#      enabled in TAF properties.
#
#  INPUTS
#    pid                Target process ID to monitor.
#    rest_low           CPU percent threshold considered "at rest".
#    rest_high          CPU percent threshold that forces a reset.
#    consecutive_needed Number of consecutive rest samples required.
#    max_attempts       Maximum sampling cycles before giving up.
#    interval           Seconds to sleep between cycles (excluding the
#                       1-second CPU sampling window).
#    verbose            Enable diagnostic snapshots to STDOUT.
#
#  OUTPUTS
#    Returns one of the following status codes:
#       REST          Process reached rest state.
#       NOT_REST      Max attempts reached without rest.
#       NO_SUCH_PROC  Target PID no longer exists.
#       ERROR_UNKNOWN Unexpected failure during sampling.
#
#  NOTES
#    - Linux-only implementation; relies on /proc/<pid>/stat.
#    - No external Perl modules required.
#    - Designed as an optional tool invoked by Run.pm when CPU monitoring
#      is enabled via TAF properties.
# ======================================================================
use strict;
use warnings;
use Time::HiRes qw(time sleep);

# Return codes
use constant {
    REST          => 0,
    NOT_REST      => 1,
    NO_SUCH_PROC  => 2,
    ERROR_UNKNOWN => 3,
};

################################################################################
# Subroutine: new
#
# Purpose:
#   Construct a CpuMonitor object with all thresholds, limits, and behavioral
#   parameters required to evaluate whether a target PID has reached a stable
#   rest state. This routine performs no validation beyond storing the caller-
#   provided values; all operational checks occur during wait_for_rest().
#
# Responsibilities:
#   * Capture all configuration parameters into a deterministic object.
#   * Provide a contributor-safe, explicit contract for all tunables.
#   * Remain side-effect free; no sampling or PID validation occurs here.
#
# Non-Responsibilities:
#   * Does NOT verify that the PID exists.
#   * Does NOT perform any CPU sampling.
#   * Does NOT enforce threshold correctness.
#
# Inputs:
#   pid                - Target process ID.
#   rest_low           - CPU percent threshold considered "at rest".
#   rest_high          - CPU percent threshold that forces a reset.
#   consecutive_needed - Number of consecutive rest samples required.
#   max_attempts       - Maximum sampling cycles before giving up.
#   interval           - Sleep duration between cycles.
#   verbose            - Enable diagnostic output.
#
# Returns:
#   A blessed CpuMonitor object.
#
# Notes:
#   - This constructor must remain deterministic and contributor-safe.
################################################################################
sub new {
    my ($class, %args) = @_;

    my $self = {
        pid                => $args{pid},
        rest_low           => $args{rest_low}           // 30,
        rest_high          => $args{rest_high}          // 90,
        consecutive_needed => $args{consecutive_needed} // 10,
        max_attempts       => $args{max_attempts}       // 800,
        interval           => $args{interval}           // 2,
        verbose            => $args{verbose}            // 0,
    };

    bless $self, $class;
    return $self;
}

################################################################################
# Subroutine: _read_proc_stat
#
# Purpose:
#   Read /proc/<pid>/stat and extract the process CPU time fields (utime and
#   stime). These values represent accumulated CPU time in clock ticks and are
#   used by _sample_cpu() to compute CPU usage deltas.
#
# Responsibilities:
#   * Open and parse /proc/<pid>/stat safely.
#   * Extract utime and stime from the correct positional fields.
#   * Return undef if the PID no longer exists or the file cannot be read.
#
# Non-Responsibilities:
#   * Does NOT compute CPU percentages.
#   * Does NOT validate field semantics beyond positional extraction.
#   * Does NOT retry or handle transient read failures.
#
# Inputs:
#   (object attribute)
#     pid - Target process ID.
#
# Returns:
#   (utime, stime) - On success.
#   undef          - If /proc/<pid>/stat cannot be read.
#
# Notes:
#   - Linux-only; relies on /proc semantics.
#   - Must remain minimal and deterministic.
################################################################################
sub _read_proc_stat {
    my ($self) = @_;
    my $pid = $self->{pid};

    my $path = "/proc/$pid/stat";
    open my $fh, "<", $path or return;
    my $line = <$fh>;
    close $fh;

    my @fields = split /\s+/, $line;

    # utime = field 14, stime = field 15 (1-based)
    my $utime = $fields[13];
    my $stime = $fields[14];

    return ($utime, $stime);
}

################################################################################
# Subroutine: _sample_cpu
#
# Purpose:
#   Compute CPU usage for the target PID over a 1-second window using deltas
#   from /proc/<pid>/stat. This routine performs the core measurement used by
#   wait_for_rest() to determine whether the process is active or idle.
#
# Responsibilities:
#   * Capture initial utime/stime and timestamp.
#   * Sleep exactly one second to establish a measurement window.
#   * Capture final utime/stime and compute CPU percent based on clock ticks.
#   * Return undef if the PID disappears during sampling.
#
# Non-Responsibilities:
#   * Does NOT interpret CPU usage relative to thresholds.
#   * Does NOT update rest or reset counters.
#   * Does NOT handle multi-core normalization; raw percent is sufficient for
#     rest detection.
#
# Inputs:
#   (object attributes)
#     pid - Target process ID.
#
# Returns:
#   <cpu_percent> - Floating-point CPU usage over the 1-second window.
#   undef         - If PID disappears or sampling fails.
#
# Notes:
#   - Uses getconf CLK_TCK when available; defaults to 100 ticks.
#   - Must remain deterministic and free of external dependencies.
################################################################################
sub _sample_cpu {
    my ($self) = @_;
    my $pid = $self->{pid};

    return undef unless -e "/proc/$pid";

    my ($u1, $s1) = $self->_read_proc_stat() or return undef;
    my $t1 = time;

    sleep 1;

    my ($u2, $s2) = $self->_read_proc_stat() or return undef;
    my $t2 = time;

    my $delta_proc = ($u2 + $s2) - ($u1 + $s1);
    my $delta_time = $t2 - $t1;

    my $ticks = _clock_ticks();
    my $cpu = ($delta_proc / $ticks) / $delta_time * 100;

    return $cpu;
}

################################################################################
# Subroutine: _clock_ticks
#
# Purpose:
#   Determine the system clock tick rate used by the kernel to represent
#   process CPU time in /proc/<pid>/stat. This value is required to convert
#   utime/stime deltas into seconds when computing CPU usage. Most Linux
#   systems report 100 ticks per second, but this routine queries the system
#   explicitly for correctness.
#
# Responsibilities:
#   * Invoke "getconf CLK_TCK" to retrieve the kernel clock tick rate.
#   * Provide a deterministic fallback of 100 ticks if the query fails.
#
# Non-Responsibilities:
#   * Does NOT validate the returned tick value.
#   * Does NOT cache results; callers may invoke repeatedly.
#   * Does NOT perform any CPU sampling or PID checks.
#
# Inputs:
#   None.
#
# Returns:
#   <ticks> - Integer clock tick rate (from getconf or fallback).
#
# Notes:
#   - Linux-only; relies on getconf availability.
#   - Must remain deterministic and contributor-safe.
################################################################################
sub _clock_ticks {
    my $ticks = `getconf CLK_TCK 2>/dev/null`;
    chomp $ticks;
    return $ticks || 100;
}


################################################################################
# Subroutine: _debug_snapshot
#
# Purpose:
#   Emit a diagnostic snapshot of the current sampling cycle, including CPU
#   usage, rest/reset counters, and cycle number. This routine is used only
#   when verbose mode is enabled and is intended for human inspection during
#   troubleshooting.
#
# Responsibilities:
#   * Print a consistent, contributor-safe snapshot format.
#   * Reflect the current state of the monitoring loop without altering it.
#
# Non-Responsibilities:
#   * Does NOT modify counters or influence state machine behavior.
#   * Does NOT perform any CPU sampling.
#   * Does NOT validate inputs.
#
# Inputs:
#   percent      - CPU usage for the current sample.
#   rest_count   - Current consecutive rest counter.
#   reset_count  - Number of times rest counter has been reset.
#   cycle        - Current sampling cycle number.
#
# Returns:
#   None.
#
# Notes:
#   - Output is suppressed unless verbose mode is enabled.
#   - Must remain stable for log parsing and contributor readability.
################################################################################
sub _debug_snapshot {
    my ($self, $percent, $rest_count, $reset_count, $cycle) = @_;
    return unless $self->{verbose};

    my $ts = scalar localtime();
    print "============================================================\n";
    print "===================== CPU Monitor ==========================\n";
    print "============================================================\n";
    print "Date Time Stamp:         $ts\n";
    print "Number of process polls: $cycle\n";
    print "DB Procress ID:          $self->{pid}\n";
    print "Current CPU Usage:       " . sprintf("%.2f", $percent) . "%\n";
    print "Rest Count:              $rest_count\n";
    print "Reset Count:             $reset_count\n";
    print "\n";
}

################################################################################
# Subroutine: wait_for_rest
#
# Purpose:
#   Monitor a target PID and determine when the process has reached a stable
#   "rest" state based on CPU usage. This routine implements the full state
#   machine: sampling CPU usage, tracking consecutive rest cycles, resetting
#   on spikes, and enforcing a maximum attempt limit. It provides a deterministic
#   alternative to fixed sleeps during setup and iteration phases.
#   This keeps setup and iteration work from bleeding into subsequent phases by
#   ensuring the database process is truly idle before proceeding. It eliminates
#   the guesswork inherent in fixed sleeps, which are typically tuned only for
#   lower thread counts and become insufficient or unpredictable at higher
#   concurrency levels, especially under write-heavy workloads.
#
# Behavior Contract:
#   - CPU usage is measured using /proc/<pid>/stat over a 1-second window.
#   - A sample is considered "at rest" when CPU usage <= rest_low.
#   - A sample forces a reset when CPU usage >= rest_high.
#   - The process is considered fully at rest only after
#         consecutive_needed
#     consecutive rest samples.
#   - Monitoring stops when:
#         * rest condition is satisfied,
#         * max_attempts is reached, or
#         * the PID disappears.
#
# Responsibilities:
#   * Drive the sampling loop and enforce all thresholds.
#   * Maintain rest and reset counters.
#   * Emit optional verbose snapshots for diagnostics.
#   * Return a deterministic status code describing the outcome.
#
# Non-Responsibilities:
#   * Does NOT validate PID existence beyond checking /proc/<pid>.
#   * Does NOT attempt to restart or manage the target process.
#   * Does NOT perform any timing beyond the sampling window and interval.
#   * Does NOT modify global TAF state; caller interprets return codes.
#
# Inputs:
#   (object attributes)
#     pid                - Target process ID.
#     rest_low           - CPU percent threshold considered "at rest".
#     rest_high          - CPU percent threshold that forces a reset.
#     consecutive_needed - Number of consecutive rest samples required.
#     max_attempts       - Maximum sampling cycles before giving up.
#     interval           - Sleep duration between cycles.
#     verbose            - Enable diagnostic output.
#
# Returns:
#   REST          - Process reached rest state.
#   NOT_REST      - Max attempts reached without rest.
#   NO_SUCH_PROC  - PID disappeared during monitoring.
#   ERROR_UNKNOWN - Unexpected failure during sampling.
#
# Notes:
#   - This routine is Linux-only; relies on /proc/<pid>/stat.
#   - Designed to be called by Run.pm when CPU monitoring is enabled.
#   - Must remain deterministic and contributor-safe.
################################################################################
sub wait_for_rest {
    my ($self) = @_;

    my $pid = $self->{pid};

    # PID missing or process already gone
    unless (-e "/proc/$pid") {
        print "CpuMonitor: PID $pid does not exist at start of monitoring.\n" if $self->{verbose};
        return NO_SUCH_PROC;
    }

    my $rest_count  = 0;
    my $reset_count = 0;

    for (my $cycle = 1; $cycle <= $self->{max_attempts}; $cycle++) {

        my $percent = $self->_sample_cpu();

        # Process disappeared during sampling
        unless (defined $percent) {
            print "CpuMonitor: PID $pid disappeared during sampling at cycle $cycle.\n" if $self->{verbose};
            return NO_SUCH_PROC;
        }

        # At-rest sample
        if ($percent <= $self->{rest_low}) {

            $rest_count++;
            $self->_debug_snapshot($percent, $rest_count, $reset_count, $cycle);

            if ($rest_count >= $self->{consecutive_needed}) {
                print "CpuMonitor: PID $pid reached rest state after $cycle cycles.\n" if $self->{verbose};
                return REST;
            }

        }
        # Reset condition
        elsif ($percent >= $self->{rest_high}) {

            $rest_count = 0;
            $reset_count++;
            $self->_debug_snapshot($percent, $rest_count, $reset_count, $cycle);
        }

        sleep $self->{interval};
    }

    # Max attempts exhausted
    print "CpuMonitor: PID $pid did not reach rest state after $self->{max_attempts} cycles.\n" if $self->{verbose};
    return NOT_REST;
}
#############################################################################
# Module terminator
#############################################################################
1;