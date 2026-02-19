package SystemInfo;
#############################################################################
# SystemInfo
#
# This file is part of the Test Automation Framework (TAF).
# Copyright (c) MariaDB Foundation
#
# Licensed under the GNU General Public License, version 2 or later (GPLv2+).
# See https://www.gnu.org/licenses/ for details.
#
# PURPOSE:
#     Provide deterministic, cross-platform routines for collecting basic
#     system information required by toolsLib and higher-level TAF components.
#     This module gathers CPU model, logical CPU count, physical core count,
#     socket count, memory, OS type and version, locale, encoding, kernel,
#     architecture, bitness, and timezone in a consistent, contributor-proof
#     manner.
#
# ARCHITECTURAL ROLE:
#     - Acts as the unified system-information provider for toolsLib.
#     - Collects platform-specific details and normalizes them into a
#       predictable, stable structure.
#     - Provides simple accessor routines:
#           * GetSystemInfo()
#           * GetCpuCount()
#           * GetCoreCount()
#           * GetSocketCount()
#           * GetCpu()
#           * GetMemory()
#           * GetLocale()
#           * GetEncoding()
#           * GetOSType()
#           * GetOSVersion()
#           * GetArch()
#           * GetKernel()
#           * GetTimezone()
#     - Ensures consistent behavior across Windows, Linux, and Cygwin.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not perform deep hardware inspection beyond topology counts.
#     - Does not validate system configuration or environment health.
#     - Does not provide performance metrics or benchmarking data.
#     - Does not guess or infer missing values; unavailable fields remain empty.
#     - Does not die(); all routines return simple values or undef.
#
# CONTRACT:
#     - new() must:
#           * create an object with a populated data hash
#           * call _gather_info() to collect system details
#     - _gather_info() must:
#           * detect platform via $^O
#           * populate the data hash deterministically
#           * avoid throwing exceptions except for unrecoverable errors
#     - Accessor routines must:
#           * return scalar values or undef
#           * remain side-effect-free
#
# GUARANTEES:
#     - Cross-platform behavior is deterministic and contributor-proof.
#     - No silent fallbacks or ambiguous behavior.
#     - No Unicode contamination; all output is ASCII-clean.
#     - Returned values are stable and predictable across environments.
#     - Debug output is minimal and controlled by caller logic.
#
# NOTES:
#     - This module is intentionally minimal; it provides only the system
#       information primitives required by toolsLib and higher-level TAF
#       components.
#     - Any change to system-information semantics must be reflected in this
#       header and in the TAF manual.
#############################################################################

our $VERSION = '2.0';
use strict;
use warnings;
use Carp;
use Sys::Hostname;
use Exporter 'import';
use File::Spec;

our @EXPORT_OK = qw(GetSystemInfo
                    GetCpuCount
                    GetCoreCount
                    GetSocketCount
                    GetCpu
                    GetMemory
                    GetLocale
                    GetEncoding
                    GetOSType
                    GetOSVersion
                    GetArch
                    GetKernel
                    GetTimezone);


use constant IS_WINDOWS => ($^O =~ /^(mswin)/oi);
use constant IS_CYGWIN  => ($^O =~ /^(cygwin)/oi);
use constant IS_LINUX   => ($^O =~ /^(linux)/oi);

###############################################################################
# Constructor
###############################################################################
sub new {
    my $class = shift;
    my $self = { data => {} };
    bless $self, $class;
    $self->_gather_info;
    return $self;
}

################################################################################
# Subroutine : _gather_info
#
# Purpose:
#   Dispatch routine that gathers system-specific information based on the
#   detected operating system. Provides a unified entry point for platform-
#   dependent processing.
#
# Globals Used:
#   Constants : IS_LINUX, IS_WINDOWS, IS_CYGWIN
#   $^O       - Perl built-in variable indicating current OS
#
# Parameters:
#   $self (object) - Caller object reference; expected to provide
#                    _process_linux and _process_windows methods.
#
# Behavior:
#   - If running on Linux:
#       - Calls $self->_process_linux to collect system information.
#   - If running on Windows or Cygwin:
#       - Calls $self->_process_windows to collect system information.
#   - Otherwise:
#       - Confesses with explicit error message including $^O.
#
# Returns:
#   None explicitly. Delegates to platform-specific processing methods.
#
# Notes:
#   - INTERNAL routine; not intended for external callers.
#   - Acts as a dispatcher; actual logic resides in platform-specific methods.
#   - Ensure that _process_linux and _process_windows are implemented in caller.
################################################################################
sub _gather_info {
    my $self = shift;
    if (IS_LINUX) {
        $self->_process_linux;
    } elsif (IS_WINDOWS || IS_CYGWIN) {
        $self->_process_windows;
    } else {
        confess "Unsupported OS: $^O";
    }
}

################################################################################
# Subroutine : GetSystemInfo
#
# Purpose:
#   Provide access to the system information data stored within the object.
#   Returns the contents of the internal data hash for external use.
#
# Globals Used:
#   None explicitly.
#
# Parameters:
#   $self (object) - Caller object reference; expected to contain a
#                    {data} hashref with system information.
#
# Behavior:
#   - Dereferences $self->{data} and returns its key/value pairs.
#   - Provides a simple accessor for system information collected elsewhere.
#
# Returns:
#   Hash (list context) - Key/value pairs from $self->{data}
#
# Notes:
#   - Intended as a public accessor method.
#   - Assumes $self->{data} has already been populated by other routines.
#   - Does not perform validation or error checking on {data}.
################################################################################
sub GetSystemInfo {
    my $self = shift;
    return %{ $self->{data} };
}

################################################################################
# Subroutine : GetCpuCount
#
# Purpose:
#   Accessor method that returns the number of CPUs detected and stored in
#   the object-> internal data structure.
#
# Globals Used:
#   None explicitly.
#
# Parameters:
#   $self (object) - Caller object reference; expected to contain a
#                    {data}->{cpu_count} entry.
#
# Behavior:
#   - Retrieves the value of $self->{data}->{cpu_count}.
#   - Provides a simple accessor for CPU count information collected elsewhere.
#
# Returns:
#   Integer - Number of CPUs recorded in $self->{data}
#
# Notes:
#   - Intended as a public accessor method.
#   - Assumes {data}->{cpu_count} has already been populated by system
#     information gathering routines.
#   - Does not perform validation or error checking on the stored value.
################################################################################
sub GetCpuCount {
    my $self = shift;
    return $self->{data}->{cpu_count};
}

################################################################################
# Subroutines : GetCpu, GetMemory, GetLocale, GetEncoding,
#               GetOSType, GetOSVersion, GetArch, GetKernel, GetTimezone
#
# Purpose:
#   Provide accessor methods for retrieving specific pieces of system
#   information stored in the object-> internal {data} hash.
#
# Globals Used:
#   None explicitly.
#
# Parameters:
#   $self (object) - Caller object reference; expected to contain a {data}
#                    hashref with the following keys:
#                      cpu, memory, locale, encoding,
#                      ostype, osversion, arch, kernel, timezone
#
# Behavior:
#   - Each subroutine dereferences $self->{data} and returns the value
#     associated with its respective key.
#   - No validation or transformation is performed; values are returned
#     exactly as stored.
#
# Returns:
#   Scalar - Value of the requested system property:
#              - GetCpu       ->' CPU identifier or description
#              - GetMemory    ->' Memory size or descriptor
#              - GetLocale    ->' Current locale string
#              - GetEncoding  ->' Character encoding in use
#              - GetOSType    ->' Operating system type
#              - GetOSVersion ->' Operating system version
#              - GetArch      ->' System architecture
#              - GetKernel    ->' Kernel version string
#              - GetTimezone  ->' Timezone identifier
#
# Notes:
#   - Intended as public accessor methods.
#   - Assumes {data} has been populated by system information gathering
#     routines (e.g., _gather_info).
#   - Lightweight getters; do not perform error checking or defaults.
################################################################################
sub GetCpu       { shift->{data}->{cpu} }
sub GetSocketCount { shift->{data}->{socket_count} }
sub GetCoreCount   { shift->{data}->{core_count} }
sub GetMemory    { shift->{data}->{memory} }
sub GetLocale    { shift->{data}->{locale} }
sub GetEncoding  { shift->{data}->{encoding} }
sub GetOSType    { shift->{data}->{ostype} }
sub GetOSVersion { shift->{data}->{osversion} }
sub GetArch      { shift->{data}->{arch} }
sub GetKernel    { shift->{data}->{kernel} }
sub GetTimezone  { shift->{data}->{timezone} }

################################################################################
# Subroutine: _process_linux
#
# Purpose:
#   Populate the object's {data} hash with Linux-specific system information.
#   Executes shell commands and helper parsing routines to gather CPU, memory,
#   OS, locale, and topology details.
#
# Globals Used:
#   None explicitly; relies on helper subs (_trim, _parse_meminfo,
#   _parse_locale, _detect_linux_version, _linux_socket_count,
#   _linux_core_count) and standard Linux utilities.
#
# Parameters:
#   $self (object) - Caller object reference; expected to contain a {data}
#                    hashref for storing collected system information.
#
# Behavior:
#   - Sets {name}         -> Hostname (via `hostname`).
#   - Sets {cpu}          -> CPU model string (first match from /proc/cpuinfo).
#   - Sets {cpu_count}    -> Logical processor count.
#   - Sets {arch}         -> Machine architecture (via `uname -m`).
#   - Sets {bit}          -> 64 or 32 depending on architecture.
#   - Sets {kernel}       -> Kernel version (via `uname -r`).
#   - Sets {memory}       -> Parsed memory info (via _parse_meminfo()).
#   - Sets {locale}       -> Parsed locale string (via _parse_locale()).
#   - Sets {encoding}     -> Extracted encoding suffix or "UNKNOWN".
#   - Sets {timezone}     -> Current timezone (via `date +%Z`).
#   - Sets {ostype}       -> Literal string "Linux".
#   - Sets {osversion}    -> Linux distribution/version (via _detect_linux_version()).
#   - Sets {socket_count} -> Physical CPU socket count (via _linux_socket_count()).
#   - Sets {core_count}   -> Physical core count (via _linux_core_count()).
#
# Returns:
#   None explicitly. Populates $self->{data} with Linux system information.
#
# Notes:
#   - INTERNAL routine; not intended for external callers.
#   - Relies on external commands and helper parsing routines.
################################################################################
sub _process_linux {
    my $self = shift;
    my $d = $self->{data};

    $d->{name} = _trim(`hostname`);
    $d->{cpu}  = _trim(`grep -m1 "model name" /proc/cpuinfo | cut -d: -f2`);
    $d->{cpu_count} = _trim(`grep -c ^processor /proc/cpuinfo`);
    $d->{arch} = _trim(`uname -m`);
    $d->{bit}  = ($d->{arch} =~ /64/) ? 64 : 32;
    $d->{kernel} = _trim(`uname -r`);
    $d->{memory} = _parse_meminfo();
    $d->{locale} = _parse_locale();
    $d->{encoding} = $d->{locale} =~ /\.(\w+)/ ? $1 : "UNKNOWN";
    $d->{timezone} = _trim(`date +%Z`);
    $d->{ostype} = "Linux";
    $d->{osversion} = _detect_linux_version();
    $d->{socket_count} = _linux_socket_count();
    $d->{core_count}   = _linux_core_count();
}

################################################################################
# Subroutine: _process_windows
#
# Purpose:
#   Populate the object's {data} hash with Windows-specific system information.
#   Parses `systeminfo` output for OS, memory, locale, and timezone details,
#   then supplements CPU topology using WMI-based helper routines.
#
# Globals Used:
#   None explicitly; relies on helper subs (_trim, _windows_logical_count,
#   _windows_core_count, _windows_socket_count, _windows_cpu_model) and the
#   Windows `systeminfo` command.
#
# Parameters:
#   $self (object) - Caller object reference; expected to contain a {data}
#                    hashref for storing collected system information.
#
# Behavior:
#   - Iterates through `systeminfo` output and sets:
#       ostype       -> OS name string
#       osversion    -> OS version string
#       kernel       -> Mirrors osversion
#       arch         -> System architecture string
#       bit          -> 64 or 32 depending on architecture
#       memory       -> Total physical memory (cleaned)
#       locale       -> Locale string
#       encoding     -> Hardcoded "UNKNOWN"
#       timezone     -> Time zone identifier
#
#   - Gathers CPU topology via WMI helper routines:
#       cpu_count    -> Logical processor count
#       core_count   -> Physical core count
#       socket_count -> Physical CPU socket count
#       cpu          -> CPU model string
#
# Returns:
#   None explicitly. Populates $self->{data} with Windows system information.
#
# Notes:
#   - INTERNAL routine; not intended for external callers.
#   - Parsing depends on localized `systeminfo` output format.
################################################################################
sub _process_windows {
    my $self = shift;
    my $d    = $self->{data};

    my @lines = `systeminfo 2>&1`;

    foreach my $line (@lines) {
        if ($line =~ /^OS Name:\s+(.*)/) {
            $d->{ostype} = _trim($1);
        }
        elsif ($line =~ /^OS Version:\s+(.*)/) {
            $d->{osversion} = _trim($1);
            $d->{kernel}    = $d->{osversion};
        }
        elsif ($line =~ /^System Type:\s+(.*)/) {
            $d->{arch} = _trim($1);
            $d->{bit}  = ($d->{arch} =~ /64/) ? 64 : 32;
        }
        elsif ($line =~ /^Total Physical Memory:\s+(.*)/) {
            $d->{memory} = _trim($line);
            $d->{memory} =~ s/^Total Physical Memory:\s+//;
        }
        elsif ($line =~ /^Locale:\s+(.*)/) {
            $d->{locale}   = _trim($1);
            $d->{encoding} = "UNKNOWN";
        }
        elsif ($line =~ /^Time Zone:\s+(.*)/) {
            $d->{timezone} = _trim($1);
        }
    }

    # CPU topology via WMI
    $d->{cpu_count}    = _windows_logical_count();
    $d->{core_count}   = _windows_core_count();
    $d->{socket_count} = _windows_socket_count();
    $d->{cpu}          = _windows_cpu_model();
}

################################################################################
# Subroutine : _detect_linux_version
#
# Purpose:
#   Detect and return a human-readable Linux distribution/version string by
#   inspecting common release files. Provides a best-effort identification of
#   the OS flavor for system information reporting.
#
# Globals Used:
#   None explicitly; relies on helper sub _trim() and standard Linux utilities.
#
# Behavior:
#   - Iterates through a list of known release files:
#       - /etc/os-release
#       - /etc/redhat-release
#       - /etc/debian_version
#       - /etc/fedora-release
#       - /etc/SuSE-release
#       - /etc/oracle-release
#   - For /etc/os-release:
#       - Extracts PRETTY_NAME value using grep.
#       - Strips leading/trailing quotes.
#       - Returns trimmed PRETTY_NAME if found.
#   - For other files:
#       - Reads first line via `head -n 1`.
#       - Returns trimmed line if non-empty.
#   - If none of the files exist or yield a value:
#       - Returns literal string "linux-unknown".
#
# Parameters:
#   None explicitly; operates in current environment.
#
# Returns:
#   String - Detected Linux distribution/version, or "linux-unknown" if not found.
#
# Notes:
#   - INTERNAL routine; not intended for external callers.
#   - Relies on presence and format of release files, which may vary by distro.
#   - Provides a simple heuristic; not guaranteed to cover all Linux variants.
################################################################################
sub _detect_linux_version {
    for my $file (qw(
        /etc/os-release
        /etc/redhat-release
        /etc/debian_version
        /etc/fedora-release
        /etc/SuSE-release
        /etc/oracle-release
    )) {
        next unless -e $file;

        if ($file eq '/etc/os-release') {
            my $pretty = `grep ^PRETTY_NAME= /etc/os-release`;
            $pretty =~ s/^PRETTY_NAME=//;
            $pretty =~ s/^"//;
            $pretty =~ s/"$//;
            return _trim($pretty) if $pretty;
        }

        my $line = `head -n 1 $file`;
        return _trim($line) if $line;
    }
    return "linux-unknown";
}

################################################################################
# Subroutine : _parse_meminfo
#
# Purpose:
#   Extract total physical memory from /proc/meminfo on Linux systems and
#   return it as a human-readable string in gigabytes.
#
# Globals Used:
#   None explicitly; relies on external command execution and regex parsing.
#
# Parameters:
#   None explicitly; operates in current environment.
#
# Behavior:
#   - Executes `grep -i MemTotal /proc/meminfo` to capture the line containing
#     total memory information.
#   - Applies regex to extract the numeric value (in kilobytes).
#   - Converts kilobytes to gigabytes by dividing by 1024 twice.
#   - Formats the result to two decimal places with "GB" suffix.
#
# Returns:
#   String - Total memory in gigabytes, e.g. "15.62 GB"
#
# Notes:
#   - INTERNAL routine; not intended for external callers.
#   - Assumes /proc/meminfo is available (Linux only).
#   - No error handling if MemTotal line is missing or malformed.
################################################################################
sub _parse_meminfo {
    my $line = `grep -i MemTotal /proc/meminfo`;
    $line =~ /MemTotal:\s+(\d+)/;
    return sprintf("%.2f GB", $1 / 1024 / 1024);
}

################################################################################
# Subroutine : _parse_locale
#
# Purpose:
#   Extract the current locale-> character type (LC_CTYPE) setting from the
#   system and return it as a string. Provides encoding context for system
#   information reporting.
#
# Globals Used:
#   None explicitly; relies on external command execution and regex parsing.
#
# Parameters:
#   None explicitly; operates in current environment.
#
# Behavior:
#   - Executes `locale | grep LC_CTYPE` to capture the LC_CTYPE line.
#   - Applies regex to extract the value following "LC_CTYPE=".
#   - Strips optional surrounding quotes.
#   - Returns the extracted locale string if found.
#   - Returns literal "UNKNOWN" if no match is found.
#
# Returns:
#   String - LC_CTYPE value (e.g., "en_US.UTF-8") or "UNKNOWN"
#
# Notes:
#   - INTERNAL routine; not intended for external callers.
#   - Assumes `locale` command is available (POSIX/Linux systems).
#   - Provides encoding context used by higher-level system info routines.
################################################################################
sub _parse_locale {
    my $line = `locale | grep LC_CTYPE`;
    $line =~ /LC_CTYPE="?([^"]+)/;
    return $1 // "UNKNOWN";
}

################################################################################
# Subroutine : _trim
#
# Purpose:
#   Utility function to remove leading and trailing whitespace from a string.
#   Ensures clean, normalized values for system information and parsing routines.
#
# Globals Used:
#   None explicitly.
#
# Parameters:
#   $s (string) - Input string to be trimmed.
#
# Behavior:
#   - Applies regex substitution to strip all whitespace at the beginning
#     and end of the string.
#   - Returns the cleaned string.
#
# Returns:
#   String - Input value with leading/trailing whitespace removed.
#
# Notes:
#   - INTERNAL helper; not intended for external callers.
#   - Commonly used to normalize values parsed from system commands or files.
################################################################################
sub _trim {
    my $s = shift;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

################################################################################
# Subroutine: _linux_socket_count
#
# Purpose:
#   Determine the number of physical CPU sockets present on a Linux system.
#   Uses sysfs topology data to avoid parsing /proc/cpuinfo or relying on
#   vendor-specific markers. Returns a deterministic, contributor-proof count.
#
# Globals Used:
#   None.
#
# Parameters:
#   None explicitly. Operates on sysfs paths exposed by the Linux kernel.
#
# Behavior:
#   - Iterates over all cpu*/topology/physical_package_id files.
#   - Reads each package_id value and records unique numeric identifiers.
#   - Ignores missing or malformed entries.
#   - Returns the number of distinct physical_package_id values discovered.
#
# Returns:
#   Scalar integer representing the number of physical CPU sockets.
#
# Notes:
#   - This is the canonical Linux method for socket detection; it matches how
#     the kernel exposes topology and avoids ambiguous heuristics.
#   - INTERNAL routine; not intended for external callers.
################################################################################
sub _linux_socket_count {
    my %sockets;

    for my $path (glob("/sys/devices/system/cpu/cpu*/topology/physical_package_id")) {
        next unless -f $path;
        if (open my $fh, "<", $path) {
            my $id = <$fh>;
            chomp $id;
            $sockets{$id} = 1 if $id =~ /^\d+$/;
            close $fh;
        }
    }

    return scalar keys %sockets;
}

################################################################################
# Subroutine: _linux_core_count
#
# Purpose:
#   Determine the number of physical CPU cores on a Linux system. Uses sysfs
#   topology data to identify unique (package_id, core_id) pairs, ensuring a
#   deterministic and contributor-proof core count independent of hyperthreading
#   or vendor-specific markers.
#
# Globals Used:
#   None.
#
# Parameters:
#   None explicitly. Operates on sysfs paths exposed by the Linux kernel.
#
# Behavior:
#   - Iterates over cpu[0-9]* directories only (avoids cpuidle, cpufreq, etc.).
#   - For each CPU directory:
#       * Reads physical_package_id
#       * Reads core_id
#       * Validates both values as numeric
#       * Records the unique package_id:core_id combination
#   - Returns the number of distinct physical cores discovered.
#
# Returns:
#   Scalar integer representing the number of physical CPU cores.
#
# Notes:
#   - This method matches the kernel's topology model and avoids parsing
#     /proc/cpuinfo, which can be ambiguous across vendors and environments.
#   - INTERNAL routine; not intended for external callers.
################################################################################
sub _linux_core_count {
    my %cores;

    # Only match cpu0, cpu1, cpu2 ... not cpuidle, cpufreq, etc.
    for my $cpu (glob("/sys/devices/system/cpu/cpu[0-9]*")) {
        next unless -d $cpu;

        my $pkg = "$cpu/topology/physical_package_id";
        my $cid = "$cpu/topology/core_id";

        next unless -f $pkg && -f $cid;

        my ($p, $c);

        # Read physical_package_id
        {
            my $fh;
            if (open($fh, "<", $pkg)) {
                $p = <$fh>;
                close($fh);
            } else {
                next;
            }
        }

        # Read core_id
        {
            my $fh;
            if (open($fh, "<", $cid)) {
                $c = <$fh>;
                close($fh);
            } else {
                next;
            }
        }

        chomp($p);
        chomp($c);

        next unless $p =~ /^\d+$/ && $c =~ /^\d+$/;

        $cores{"$p:$c"} = 1;
    }

    return scalar keys %cores;
}

################################################################################
# Subroutine: _windows_socket_count
#
# Purpose:
#   Determine the number of physical CPU sockets on a Windows system using WMI.
#   Parses the output of `wmic cpu get SocketDesignation` and counts unique
#   socket identifiers. Provides a deterministic, contributor-proof socket count.
#
# Globals Used:
#   None.
#
# Parameters:
#   None explicitly. Relies on the Windows WMI interface via the `wmic` command.
#
# Behavior:
#   - Executes `wmic cpu get SocketDesignation` and reads all returned lines.
#   - Skips the header row.
#   - Trims whitespace and ignores empty lines.
#   - Records each unique socket designation string.
#   - Returns the number of distinct socket identifiers discovered.
#
# Returns:
#   Scalar integer representing the number of physical CPU sockets.
#
# Notes:
#   - WMI exposes one entry per physical socket, making this method reliable
#     across Windows versions and hardware vendors.
#   - INTERNAL routine; not intended for external callers.
################################################################################
sub _windows_socket_count {
    my @lines = `wmic cpu get SocketDesignation 2>NUL`;
    my %seen;

    for my $l (@lines) {
        next if $l =~ /SocketDesignation/i;
        $l =~ s/^\s+|\s+$//g;
        next unless length $l;
        $seen{$l} = 1;
    }

    return scalar keys %seen;
}

################################################################################
# Subroutine: _windows_core_count
#
# Purpose:
#   Determine the total number of physical CPU cores on a Windows system.
#   Uses WMI via `wmic cpu get NumberOfCores` and sums the core count across
#   all physical processors. Provides a deterministic, contributor-proof value.
#
# Globals Used:
#   None.
#
# Parameters:
#   None explicitly. Relies on the Windows WMI interface through the `wmic`
#   command to expose per-socket core counts.
#
# Behavior:
#   - Executes `wmic cpu get NumberOfCores` and reads all returned lines.
#   - Skips the header row.
#   - Trims whitespace and ignores non-numeric or empty lines.
#   - Adds each numeric core count to an accumulator.
#   - Returns the total number of physical cores across all sockets.
#
# Returns:
#   Scalar integer representing the total number of physical CPU cores.
#
# Notes:
#   - WMI exposes one NumberOfCores value per physical CPU socket.
#   - This method avoids logical processor counts and hyperthreading noise.
#   - INTERNAL routine; not intended for external callers.
################################################################################
sub _windows_core_count {
    my @lines = `wmic cpu get NumberOfCores 2>NUL`;
    my $total = 0;

    for my $l (@lines) {
        next if $l =~ /NumberOfCores/i;
        $l =~ s/^\s+|\s+$//g;
        next unless $l =~ /^\d+$/;
        $total += $l;
    }

    return $total;
}

#############################################################################
# Module terminator
#############################################################################
1;