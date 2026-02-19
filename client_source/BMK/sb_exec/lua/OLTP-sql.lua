-- ----------------------------------------------------------------------
-- OLTP sql
-- ----------------------------------------------------------------------

BMK_HOME = os.getenv( "BMK_HOME" )
if( BMK_HOME == nil ) then BMK_HOME= "/BMK" end
package.path = "?.lua;" .. BMK_HOME .. "/sb_exec/lua/?.lua;" .. package.path

require( "oltp_common" )


function prepare_statements()
end


--
-- Test OLTP workload..
-- 1) uncomment "for" loop if you also need to fetch all rows from SQL query
-- 2) uncomment reconnect() if you need simulate a re-connect on each query
--
function event()
  local dbid = sysbench.rand.default( 1, 1000 )
  local id = sysbench.rand.default( 1, 155 )

  rs = con:query( "select * from customer_" .. dbid .. ".tbl where id = " .. id )

  -- for i = 1, rs.nrows
  -- do
  --   row = rs:fetch_row()
  -- end

  -- con:reconnect()
end
