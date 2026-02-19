-- ----------------------------------------------------------------------
-- OLTP_RW-write_only benchmark, notrx
-- ----------------------------------------------------------------------

BMK_HOME = os.getenv( "BMK_HOME" )
if( BMK_HOME == nil ) then BMK_HOME= "/BMK" end
package.path = "?.lua;" .. BMK_HOME .. "/sb_exec/lua/?.lua;" .. package.path 

require( "oltp_common" ) 

function prepare_statements()
  prepare_index_updates()
  prepare_non_index_updates()
  prepare_delete_inserts()
end

-- test workload..
function event()
  check_extra_query_before()
  execute_index_updates()
  execute_non_index_updates()
  execute_delete_inserts()
  check_extra_query_after()
end
