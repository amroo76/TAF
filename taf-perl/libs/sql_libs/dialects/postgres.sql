# ======================================================================
# MariaDB Foundation - SQL Dialect Definitions
# ----------------------------------------------------------------------
# File: dialects/sql.dialect
# Purpose:
#     Defines named SQL snippets used by TAF for MariaDB diagnostics,
#     environment introspection, and database lifecycle operations.
#
# Copyright:
#     Copyright (c) MariaDB Foundation.
#     Licensed under the Apache License, Version 2.0.
#     You may obtain a copy of the License at:
#         http://www.apache.org/licenses/LICENSE-2.0
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