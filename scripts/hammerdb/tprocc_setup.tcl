###############################################################################
# tprocc_setup.tcl
#
# Created: December 2025
# Last Modified: January 2026
# Version: 1.0
#
# This file is part of the Test Automation Framework (TAF).
# Copyright (c) 2025-2026 MariaDB Foundation
#
# Licensed under the GNU General Public License, version 2 or later (GPLv2+).
# See https://www.gnu.org/licenses/ for details.
#
# PURPOSE:
#     Build and load a fresh HammerDB TPROC-C schema in a deterministic,
#     automation-safe manner. This script loads configuration from the
#     environment, performs a full cleanup of any existing schema and virtual
#     users, and then executes the schema build sequence.
#
# ARCHITECTURAL ROLE:
#     - Canonical TPROC-C schema setup script for use under TAF.
#     - Ensures consistent teardown and rebuild behavior across all test runs.
#     - Provides a standalone, non-interactive setup path suitable for both
#       manual and automated execution.
#
# CONTRACT:
#     - Requires HAMMERDB_TPROCC_CONFIG to be defined and point to a valid
#       configuration file loadable by Tcl.
#     - Must perform the following steps in order:
#           * load configuration
#           * dump the TPROC-C dictionary for visibility
#           * delete any existing schema
#           * destroy all virtual users
#           * build a new schema
#     - Must exit with status 0 on success.
#
# GUARANTEES:
#     - No schema build occurs without a valid configuration source.
#     - All lingering virtual users are destroyed before schema build.
#     - Output is printed to stdout for visibility in automated logs.
#     - Behavior is deterministic and identical across environments.
#
# USAGE:
#     tclsh tprocc_setup.tcl
#
# NOTES:
#     - Intended for use within the Test Automation Framework (TAF).
#     - May be invoked directly or through higher-level TAF setup routines.
#     - Does not perform safety prompts; callers must ensure correct usage.
###############################################################################

## --------------------------------------------------------------------------
## Startup
## --------------------------------------------------------------------------
puts "=== Starting TPROCC Schema Build/Load ==="
vuset showoutput 1

## --------------------------------------------------------------------------
## Load Configuration
## --------------------------------------------------------------------------
source $env(HAMMERDB_TPROCC_CONFIG)
puts "Config loaded from: $env(HAMMERDB_TPROCC_CONFIG)"

## --------------------------------------------------------------------------
## Dictionary Dump
## --------------------------------------------------------------------------
puts "---- TPROCC Dictionary ----"
print dict

## --------------------------------------------------------------------------
## Schema Cleanup
## --------------------------------------------------------------------------
puts "Running deleteschema..."
deleteschema
puts "Schema delete complete."

## --------------------------------------------------------------------------
## Virtual User Cleanup
## --------------------------------------------------------------------------
puts "Destroying Virtual Users..."
vudestroy
puts "Virtual Users destroyed."

## --------------------------------------------------------------------------
## Schema Build
## --------------------------------------------------------------------------
puts "Running buildschema..."
buildschema
puts "Schema build complete."

## --------------------------------------------------------------------------
## Exit
## --------------------------------------------------------------------------
exit 0