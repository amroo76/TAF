SELECT EVENT_NAME,
       COUNT_STAR,
       SUM_TIMER_WAIT,
       AVG_TIMER_WAIT,
       MAX_TIMER_WAIT
FROM performance_schema.events_stages_summary_global_by_event_name
ORDER BY SUM_TIMER_WAIT DESC;