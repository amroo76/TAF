SELECT DIGEST_TEXT,
       COUNT_STAR,
       SUM_TIMER_WAIT,
       AVG_TIMER_WAIT,
       MAX_TIMER_WAIT
FROM performance_schema.events_statements_summary_by_digest
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 20;