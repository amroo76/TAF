package reporter_libs::_taf_paths;
#############################################################################
# reporter_libs::_taf_paths
#
# Created: December 2025
# Last Modified: January 2026
#
# This file is part of the Test Automation Framework (TAF).
# Copyright (c) 2025-2026 MariaDB Foundation
#
# Licensed under the GNU General Public License, version 2 or later (GPLv2+).
# See https://www.gnu.org/licenses/ for details.
#
# PURPOSE:
#     Provide shared path-resolution helpers for reporter modules. This includes
#     determining the TAF root directory based on module location and resolving
#     relative config file paths into canonical absolute paths.
#
# ARCHITECTURAL ROLE:
#     - Acts as the central path utility for all reporters.
#     - Ensures consistent, deterministic resolution of config file paths.
#     - Eliminates duplicated logic across reporter modules.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not validate config file syntax or contents.
#     - Does not check directory permissions or readability.
#     - Does not infer missing directories or create filesystem paths.
#     - Does not depend on framework context or environment variables.
#
# CONTRACT:
#     - taf_root() must return the parent directory of libs/.
#     - resolve_config_path() must return:
#           * absolute path unchanged
#           * canonicalized path for relative inputs
#           * "unknown" for undefined or empty inputs
#
# GUARANTEES:
#     - All returned paths are ASCII-clean and canonicalized.
#     - No silent fallbacks; behavior is deterministic.
#     - Module has no side effects and performs no filesystem writes.
#############################################################################

use strict;
use warnings;
use Cwd 'abs_path';
use File::Basename;
use Exporter 'import';

our @EXPORT_OK = qw(taf_root resolve_config_path);

#############################################################################
# taf_root
#
# PURPOSE:
#     Determine the TAF installation root by locating this module and walking
#     up two directory levels (libs/ and its parent).
#
# ARCHITECTURAL ROLE:
#     - Provides a stable anchor point for resolving relative paths.
#
# WHAT THIS BLOCK DOES NOT DO:
#     - Does not validate the existence of expected subdirectories.
#     - Does not use environment variables or global state.
#
# GUARANTEES:
#     - Always returns a canonical absolute path.
#############################################################################
sub taf_root {
    my $module_path = abs_path(__FILE__);
    my $module_dir  = dirname($module_path);
    return dirname(dirname($module_dir));   # parent of libs/
}

#############################################################################
# resolve_config_path
#
# PURPOSE:
#     Convert a config file path into a canonical absolute path. Supports both
#     absolute paths and paths relative to the TAF root.
#
# ARCHITECTURAL ROLE:
#     - Ensures reporters can reliably locate config files regardless of how
#       the user specified them.
#
# WHAT THIS BLOCK DOES NOT DO:
#     - Does not verify file existence.
#     - Does not attempt to guess missing directories.
#
# CONTRACT:
#     - Undefined or empty input returns "unknown".
#     - Absolute paths are returned unchanged.
#     - Relative paths are resolved against taf_root().
#
# GUARANTEES:
#     - Returned paths are canonicalized via File::Spec->canonpath().
#############################################################################
sub resolve_config_path {
    my ($cfg) = @_;
    return 'unknown' unless defined $cfg && $cfg ne '';

    # absolute path? use as-is
    return $cfg if $cfg =~ m{^/};

    my $root = taf_root();
    my $resolved = File::Spec->catfile($root, $cfg);
    return File::Spec->canonpath($resolved);
}

#############################################################################
# Module terminator
#############################################################################
1;