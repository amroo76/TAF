SELECT
    table_schema AS db,
    SUM(data_length) AS data_bytes,
    SUM(index_length) AS index_bytes,
    SUM(data_length + index_length) AS total_bytes,
    SUM(data_free) AS free_bytes
FROM information_schema.tables
GROUP BY table_schema
ORDER BY total_bytes DESC;

SELECT
    TABLE_SCHEMA AS db,
    FILE_TYPE,
    SUM(TOTAL_EXTENTS * EXTENT_SIZE) AS bytes
FROM information_schema.FILES
GROUP BY TABLE_SCHEMA, FILE_TYPE
ORDER BY bytes DESC;

SELECT
    FILE_TYPE,
    FILE_NAME,
    TOTAL_EXTENTS * EXTENT_SIZE AS bytes
FROM information_schema.FILES
WHERE FILE_TYPE IN ('REDO LOG', 'UNDO LOG', 'LOG');