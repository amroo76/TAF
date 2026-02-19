-- ----------------------------------------------------------------------
-- OLTP_RW-point_selects benchmark, trx
-- ----------------------------------------------------------------------

BMK_HOME = os.getenv( "BMK_HOME" )
if( BMK_HOME == nil ) then BMK_HOME= "/BMK" end
package.path = "?.lua;" .. BMK_HOME .. "/sb_exec/lua/?.lua;" .. package.path 

require( "oltp_common" ) 

function prepare_statements()
  prepare_begin()
  prepare_commit()
  prepare_point_selects()
  prepare_index_updates()
  prepare_non_index_updates()
  prepare_delete_inserts()
end

-- test workload..
function event()
  check_extra_query_before()
  begin()
  execute_point_selects()
  execute_index_updates()
  execute_non_index_updates()
  execute_delete_inserts()
  commit()
  check_extra_query_after()
end
