-- ----------------------------------------------------------------------
-- OLTP test
-- ----------------------------------------------------------------------

BMK_HOME = os.getenv( "BMK_HOME" )
if( BMK_HOME == nil ) then BMK_HOME= "/BMK" end
package.path = "?.lua;" .. BMK_HOME .. "/sb_exec/lua/?.lua;" .. package.path

require( "oltp_common" )
counter= 0


function my_counter( step )
  if( sysbench.tid == 0 ) then
    counter = counter + 1
  end

  print( ">> step: " .. step .. "  tid: " .. sysbench.tid .. "  counter: " .. counter )
  print( sysbench.rand.varstring( 5, 20 ))
  usleep( 1000000 )
end


function thread_init()
  my_counter( "init" )
  my_counter( "init" )
  my_counter( "init" )
  my_counter( "init" )
end


function thread_done()
end


-- test workload..
function event()
  my_counter( "event" )
end
