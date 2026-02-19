-- ----------------------------------------------------------------------
-- OLTP_RW-index_updates benchmark, notrx
-- ----------------------------------------------------------------------

BMK_HOME = os.getenv( "BMK_HOME" )
if( BMK_HOME == nil ) then BMK_HOME= "/BMK" end
package.path = "?.lua;" .. BMK_HOME .. "/sb_exec/lua/?.lua;" .. package.path 

require( "oltp_common" ) 

function prepare_statements()
  if( sysbench.opt.index_updates <= 0 ) then
    sysbench.opt.index_updates = 1
  end
  prepare_index_updates()
end

-- test workload..
function event()
  check_extra_query_before()
  execute_index_updates()
  check_extra_query_after()
end
