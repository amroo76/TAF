SELECT OBJECT_SCHEMA,
       OBJECT_NAME,
       COUNT_READ,
       COUNT_WRITE,
       SUM_TIMER_WAIT
FROM performance_schema.table_io_waits_summary_by_table
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 20;