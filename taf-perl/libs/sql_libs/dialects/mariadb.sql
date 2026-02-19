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
SELECT VERSION();

[variables]
SHOW VARIABLES;

[row_count]
SELECT COUNT(*) FROM {table};

[db_size]
SELECT table_schema AS db,
       SUM(data_length + index_length) AS size_bytes
FROM information_schema.tables
GROUP BY table_schema;

[stats]
SHOW GLOBAL STATUS;

[create_database]
CREATE DATABASE {db};

[drop_database]
DROP DATABASE IF EXISTS {db};