--
-- (dim) SYNC-file stuff..
--

-- check if file exists
function SYNC_file_exists( fname )
  local f = io.open( fname, "r" )

  if( f ~= nil ) then
    io.close(f)
    return(true)
  else
    return(false)
  end
end


-- make file
function SYNC_make_file( fname )
  local f = io.open( fname, "w+" )

  if( f ~= nil ) then
    return(false)
  else
    io.close(f)
    return(true)
  end
end


function SYNC_wait_file( fname, exist, wait_ms )
  if( exist ) then
    while( SYNC_file_exists( fname )) do
      usleep( wait_ms * 1000 )
    end
  else
    while( not SYNC_file_exists( fname )) do
      usleep( wait_ms * 1000 )
    end
  end
end


-- drop file
function SYNC_drop_file( fname )
  os.remove( fname )
end


function SYNC_wait( fname, ms )
  -- >>: thread-zero => Master
  if( sysbench.tid == 0 ) then
    local TID

    print( "=> SYNC-file : synchronization via " .. fname )

    for TID = 1, sysbench.opt.threads - 1 do
      SYNC_wait_file( fname .. "." .. TID, false, 5 )
      SYNC_drop_file( fname .. "." .. TID )
    end

    SYNC_make_file( fname )
    SYNC_make_file( fname .. ".0" )

    print( "=> SYNC-file : ready to start.." )

    SYNC_wait_file( fname, true, ms )
    SYNC_drop_file( fname .. ".0" )

    print( "=> SYNC-file : started " .. os.date("%Y-%m-%d %T") .. " !!!" )
    return(0)
  end

  -- >>: non-zero thread..
  SYNC_make_file( fname .. "." .. sysbench.tid )
  SYNC_wait_file( fname .. ".0", false, ms )
  SYNC_wait_file( fname, true, ms )
end
