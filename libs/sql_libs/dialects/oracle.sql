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
SELECT * FROM v$version;

[variables]
SELECT name, value FROM v$parameter;

[row_count]
SELECT COUNT(*) FROM {table};

[db_size]
SELECT tablespace_name AS ts,
       SUM(bytes) AS size_bytes
FROM dba_data_files
GROUP BY tablespace_name;

[stats]
SELECT * FROM v$sysstat;

[create_database]
CREATE USER {db}
  IDENTIFIED BY {db}
  DEFAULT TABLESPACE USERS
  TEMPORARY TABLESPACE TEMP
  QUOTA UNLIMITED ON USERS;

[drop_database]
DROP USER {db} CASCADE;