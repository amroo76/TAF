-- ----------------------------------------------------------------------
-- OLTP_RO-order_ranges benchmark, notrx
-- ----------------------------------------------------------------------

BMK_HOME = os.getenv( "BMK_HOME" )
if( BMK_HOME == nil ) then BMK_HOME= "/BMK" end
package.path = "?.lua;" .. BMK_HOME .. "/sb_exec/lua/?.lua;" .. package.path 

require( "oltp_common" ) 

function prepare_statements()
  if( sysbench.opt.order_ranges <= 0 ) then
    sysbench.opt.order_ranges = 1
  end
  prepare_order_ranges()
end

-- test workload..
function event()
  check_extra_query_before()
  execute_order_ranges()
  check_extra_query_after()
end
