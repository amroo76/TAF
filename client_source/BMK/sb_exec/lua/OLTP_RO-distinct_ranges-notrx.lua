-- ----------------------------------------------------------------------
-- OLTP_RO-distinct_ranges benchmark, notrx
-- ----------------------------------------------------------------------

BMK_HOME = os.getenv( "BMK_HOME" )
if( BMK_HOME == nil ) then BMK_HOME= "/BMK" end
package.path = "?.lua;" .. BMK_HOME .. "/sb_exec/lua/?.lua;" .. package.path 

require( "oltp_common" ) 

function prepare_statements()
  if( sysbench.opt.distinct_ranges <= 0 ) then
    sysbench.opt.distinct_ranges = 1
  end
  prepare_distinct_ranges()
end

-- test workload..
function event()
  check_extra_query_before()
  execute_distinct_ranges()
  check_extra_query_after()
end
