-- ----------------------------------------------------------------------
-- OLTP_RO-non_index_updates benchmark, trx
-- ----------------------------------------------------------------------

BMK_HOME = os.getenv( "BMK_HOME" )
if( BMK_HOME == nil ) then BMK_HOME= "/BMK" end
package.path = "?.lua;" .. BMK_HOME .. "/sb_exec/lua/?.lua;" .. package.path 

require( "oltp_common" ) 

function prepare_statements()
  prepare_begin()
  prepare_commit()
  prepare_point_selects()
  prepare_simple_ranges()
  prepare_sum_ranges()
  prepare_order_ranges()
  prepare_distinct_ranges()
  prepare_non_index_updates()
end

-- test workload..
function event()
  check_extra_query_before()
  begin()
  execute_point_selects()
  execute_simple_ranges()
  execute_sum_ranges()
  execute_order_ranges()
  execute_distinct_ranges()
  execute_non_index_updates()
  commit()
  check_extra_query_after()
end
