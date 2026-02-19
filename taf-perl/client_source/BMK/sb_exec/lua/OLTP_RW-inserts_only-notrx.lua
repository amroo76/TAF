-- ----------------------------------------------------------------------
-- OLTP_RW-inserts_only benchmark, notrx
-- ----------------------------------------------------------------------

BMK_HOME = os.getenv( "BMK_HOME" )
if( BMK_HOME == nil ) then BMK_HOME= "/BMK" end
package.path = "?.lua;" .. BMK_HOME .. "/sb_exec/lua/?.lua;" .. package.path 

require( "oltp_common" ) 

function prepare_statements()
  if( sysbench.opt.inserts_only <= 0 ) then
    sysbench.opt.inserts_only = 1
  end
  prepare_inserts_only()
end

-- test workload..
function event()
  check_extra_query_before()
  execute_inserts_only()
  check_extra_query_after()
end
