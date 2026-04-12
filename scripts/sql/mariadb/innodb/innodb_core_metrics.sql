SELECT name, count 
FROM information_schema.INNODB_METRICS 
WHERE name IN (
  'buffer_pool_reads',
  'buffer_pool_read_requests',
  'buffer_pool_write_requests',
  'log_writes',
  'log_write_requests',
  'log_waits',
  'os_log_bytes_written',
  'innodb_dblwr_writes',
  'innodb_dblwr_pages_written',
  'log_lsn_checkpoint_age',
  'trx_rseg_history_len'
)
ORDER BY name;