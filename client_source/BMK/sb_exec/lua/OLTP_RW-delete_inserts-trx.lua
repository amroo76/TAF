-- ----------------------------------------------------------------------
-- OLTP_RW-delete_inserts benchmark, trx
-- ----------------------------------------------------------------------

BMK_HOME = os.getenv( "BMK_HOME" )
if( BMK_HOME == nil ) then BMK_HOME= "/BMK" end
package.path = "?.lua;" .. BMK_HOME .. "/sb_exec/lua/?.lua;" .. package.path 

require( "oltp_common" ) 

function prepare_statements()
  if( sysbench.opt.delete_inserts <= 0 ) then
    sysbench.opt.delete_inserts = 1
  end
  prepare_begin()
  prepare_commit()
  prepare_delete_inserts()
end

-- test workload..
function event()
  check_extra_query_before()
  begin()
  execute_delete_inserts()
  commit()
  check_extra_query_after()
end
