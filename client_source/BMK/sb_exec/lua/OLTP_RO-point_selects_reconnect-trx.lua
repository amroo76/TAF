-- ----------------------------------------------------------------------
-- OLTP_RO-point_selects_reconnect benchmark, trx
-- ----------------------------------------------------------------------

BMK_HOME = os.getenv( "BMK_HOME" )
if( BMK_HOME == nil ) then BMK_HOME= "/BMK" end
package.path = "?.lua;" .. BMK_HOME .. "/sb_exec/lua/?.lua;" .. package.path 

require( "oltp_common" ) 

function prepare_statements()
  prepare_point_selects_reconnect()
end

-- test workload..
function event()
  check_extra_query_before()
  execute_point_selects_reconnect(true)
  check_extra_query_after()
end
