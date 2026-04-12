# ======================================================================
# MariaDB Foundation - SQL Dialect Definitions
# ----------------------------------------------------------------------
# File: dialects/sql.dialect
# Purpose:
#     Defines named SQL snippets used by TAF for MariaDB diagnostics,
#     environment introspection, and database lifecycle operations.
#
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
# Notes:
#     - All blocks must remain deterministic and contributor-proof.
#     - Do not modify block names without updating all references.
# ======================================================================
[version]
SELECT version();

[variables]
SHOW ALL;

[row_count]
SELECT COUNT(*) FROM {table};

[db_size]
SELECT pg_database.datname AS db,
       pg_database_size(pg_database.datname) AS size_bytes
FROM pg_database;

[stats]
SELECT * FROM pg_stat_database;

[create_database]
CREATE DATABASE {db};

[drop_database]
DROP DATABASE IF EXISTS {db};