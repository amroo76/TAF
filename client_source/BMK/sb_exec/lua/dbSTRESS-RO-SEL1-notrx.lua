-- ----------------------------------------------------------------------
-- dbSTRESS benchmark
-- ----------------------------------------------------------------------

BMK_HOME = os.getenv( "BMK_HOME" )
if( BMK_HOME == nil ) then BMK_HOME= "/BMK" end
package.path = "?.lua;" .. BMK_HOME .. "/sb_exec/lua/?.lua;" .. package.path 

require( "dbSTRESS-common" ) 

function prepare_statements()
  prepare_SEL1()
end

-- test workload..
function event()
  local tnum
  local ref 

  ops = ops + 1 

  if( sysbench.opt.same_ref ) then
    tnum = get_set_num()
    ref  = get_ref()
  end 

  execute_SEL1( tnum, ref )
end
