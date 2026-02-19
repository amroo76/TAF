-- ----------------------------------------------------------------------
-- OLTP_RO-simple_ranges benchmark, notrx
-- ----------------------------------------------------------------------

BMK_HOME = os.getenv( "BMK_HOME" )
if( BMK_HOME == nil ) then BMK_HOME= "/BMK" end
package.path = "?.lua;" .. BMK_HOME .. "/sb_exec/lua/?.lua;" .. package.path 

require( "oltp_common" ) 

function prepare_statements()
  if( sysbench.opt.simple_ranges <= 0 ) then
    sysbench.opt.simple_ranges = 1
  end
  prepare_simple_ranges()
end

-- test workload..
function event()
  check_extra_query_before()
  execute_simple_ranges()
  check_extra_query_after()
end
