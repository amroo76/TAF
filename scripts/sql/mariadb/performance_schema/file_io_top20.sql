SELECT FILE_NAME,
       EVENT_NAME,
       COUNT_READ,
       COUNT_WRITE,
       SUM_TIMER_WAIT
FROM performance_schema.file_summary_by_instance
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 20;