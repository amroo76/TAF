-- ----------------------------------------------------------------------
-- OLTP loop
-- ----------------------------------------------------------------------

BMK_HOME = os.getenv( "BMK_HOME" )
if( BMK_HOME == nil ) then BMK_HOME= "/BMK" end
package.path = "?.lua;" .. BMK_HOME .. "/sb_exec/lua/?.lua;" .. package.path

require( "oltp_common" )


function prepare_statements()
end


-- test workload..
function event()
  rs = con:query("CALL loop_test(1,1)")
  for i = 1, rs.nrows
  do
    row = rs:fetch_row()
    -- print( "row:" .. row[1] )
  end

  con:reconnect()
end
