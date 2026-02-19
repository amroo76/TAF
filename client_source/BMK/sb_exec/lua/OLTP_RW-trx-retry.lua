-- ----------------------------------------------------------------------
-- OLTP_RW benchmark, trx + retry
-- ----------------------------------------------------------------------

package.path = "?.lua;./sb_exec/lua/?.lua;" .. package.path
require( "oltp_common-retry" ) 

function prepare_statements()
  prepare_begin()
  prepare_commit()
  prepare_point_selects()
  prepare_simple_ranges()
  prepare_sum_ranges()
  prepare_order_ranges()
  prepare_distinct_ranges()
  prepare_index_updates()
  prepare_non_index_updates()
  prepare_delete_inserts()
end

-- test workload..
function event()
  start_id()
  begin()
  execute_point_selects()
  execute_simple_ranges()
  execute_sum_ranges()
  execute_order_ranges()
  execute_distinct_ranges()
  execute_index_updates()
  execute_non_index_updates()
  execute_delete_inserts()
  commit()
  reset_id()
end
