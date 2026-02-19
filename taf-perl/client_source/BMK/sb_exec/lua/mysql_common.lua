--
-- (dim) Common MySQL stuff
--

ffi = require( "ffi" )
ffi.cdef(
  [[
    typedef struct timeval {
      long tv_sec;
      long tv_usec;
    } timeval;

    int gettimeofday(struct timeval* t, void* tzp);
    void sb_counter_inc(int, sb_counter_type);
    int usleep(int microseconds);
  ]]
)
get_tm_data = ffi.new( "struct timeval" )


function get_tm()
  ffi.C.gettimeofday( get_tm_data, nil )
  return tonumber( get_tm_data.tv_sec), tonumber(get_tm_data.tv_usec )
end


function usleep( usec )
  if( usec > 0 ) then
    ffi.C.usleep( usec )
  end
end


function mysql_check_charset( con )
  if( sysbench.tid == 0 and sysbench.opt.mysql_check_charset ) then
    local rs

    rs = con:query( [[
      SELECT * FROM performance_schema.session_variables
        WHERE VARIABLE_NAME IN (
          'character_set_client', 'character_set_connection',
          'character_set_results', 'collation_connection'
        ) ORDER BY VARIABLE_NAME;
    ]] )

    print( "\nCheck MySQL Connection charset" )
    print( "------------------------------------------------------------------" )

    for i = 1, rs.nrows
    do
      row = rs:fetch_row()
      print( string.format( " %-30s : %s", row[1], row[2] ))
    end

    print( "------------------------------------------------------------------\n" )
  end
end


function mysql_session_opt( con )
  local my

  if( string.len( sysbench.opt.mysql_session_options ) > 0 ) then
    my = sysbench.opt.mysql_session_options
  else
    my = os.getenv( "MYSQL_SESSION_OPTIONS" )
    if( my == nil ) then
      mysql_check_charset( con )
      return(-1)
    end

    sysbench.opt.mysql_session_options = my
  end

  local i = 0
  local j = 1

  while true do
    i = string.find( my, ";", i+1 )
    if( i == nil ) then
      break
    end

    con:query( string.sub( my, j, i ))
    j= i + 1
  end

  if( j < string.len(my)) then
    con:query( string.sub( my, j ) .. ";" )
  end

  mysql_check_charset( con )
  return(0)
end


-- Note: error hooks.
function sysbench.hooks.sql_error_ignorable( err )
  if(  err.sql_errno == 2013      -- CR_SERVER_LOST
    or err.sql_errno == 2055      -- CR_SERVER_LOST_EXTENDED
    or err.sql_errno == 2006      -- CR_SERVER_GONE_ERROR
    or err.sql_errno == 1047      -- ER_UNKNOWN_COM_ERROR
    or err.sql_errno == 2011 )    -- CR_TCP_CONNECTION
  then
    do_reconnect()
    return( true )
  end
end


function check_reconnect()
  if( sysbench.opt.reconnect > 0 ) then
    events = (events or 0) + 1

    if( events >= sysbench.opt.reconnect ) then
      events = 0
      do_reconnect()
    end
  end
end


function do_reconnect()
  if( close_statements ~= nil ) then
    close_statements()
  end

  con:reconnect()

  if( prepare_statements ~= nil ) then
    prepare_statements()
  end
end


function check_opt_debug()
  if( sysbench.opt.opt_debug ) then
    local opt = {}

    for k,v in pairs( sysbench.opt ) do
      table.insert( opt, k )
    end

    table.sort( opt )

    print( "=> Sysbench Options debug.." )
    for k,v in pairs( opt ) do
      print( "   opt: " .. v .. " : " .. tostring( sysbench.opt[v] ))
    end
  end
end


function report_csv( stat, threads, tm, header )
  if( header )  then
    print( "time,thds,tps,qps,r,w,o,lat95,err/s,reconn/s" )
  end

  print( string.format( "%.0f,%u,%4.2f,%4.2f,%4.2f,%4.2f,%4.2f,%4.2f,%4.2f,%4.2f",
    stat.time_total, threads,
    stat.events / tm, (stat.reads + stat.writes + stat.other) / tm,
    stat.reads / tm, stat.writes / tm, stat.other / tm,
    stat.latency_pct * 1000, stat.errors / tm, stat.reconnects / tm )
  )
end


function inter_report_csv( stat )
  report_csv( stat, stat.threads_running, stat.time_interval, CSV_header )

  if( CSV_header )  then
    CSV_header = false
  end
end


function final_report_csv( stat )
  print( "\nFinal report :")
  report_csv( stat, sysbench.opt.threads, stat.time_total, true )
end


if( os.getenv( "SYSBENCH_REPORT_CSV" ) ~= nil )  then
  CSV_header = true
  sysbench.hooks.report_intermediate = inter_report_csv
end

if( os.getenv( "SYSBENCH_FINAL_REPORT_CSV" ) ~= nil )  then
  sysbench.hooks.report_cumulative = final_report_csv
end
