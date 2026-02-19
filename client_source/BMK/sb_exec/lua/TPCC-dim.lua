-- ----------------------------------------------------------------------
-- TPCC-like
-- ----------------------------------------------------------------------

BMK_HOME = os.getenv( "BMK_HOME" )
if( BMK_HOME == nil ) then BMK_HOME= "/BMK" end
package.path = "?.lua;" .. BMK_HOME .. "/sb_exec/lua/?.lua;" .. package.path 
 

-- include tpcc.lua -----------------------------------------------------
-- Copyright (C) 2018-2024 Oracle Corp.
-- remastered and adapted for BMK-kit by Dimitri KRAVTCHUK <dimitri.kravtchuk@oracle.com>
-- BMK-kit howto : http://dimitrik.free.fr/blog/posts/mysql-perf-bmk-kit.html

-- This program is free software; you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation; either version 2 of the License, or
-- (at your option) any later version.

-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.

-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

-- ----------------------------------------------------------------------
-- TPCC-like workload
-- ----------------------------------------------------------------------

require( "tpcc_common" )
require( "tpcc_run" )
require( "tpcc_check" )

function thread_init()
  trx_name = { "new_order", "payment", "orderstatus", "delivery", "stocklevel" }
  FORCE_PRIMARY = ""
  FOR_UPDATE1 = ""
  FOR_UPDATE2 = ""
  null_value = "DEFAULT"

  if( sysbench.opt.force_primary >= 1 ) then  FORCE_PRIMARY = " force index (primary)" end
  if( sysbench.opt.force_null == 1 ) then  null_value  = "NULL" end
  if( sysbench.opt.for_update >= 1 ) then  FOR_UPDATE1 = " FOR UPDATE" end
  if( sysbench.opt.for_update >= 2 ) then  FOR_UPDATE2 = " FOR UPDATE" end

  if( sysbench.tid == 0 ) then
    print( "** Using FOR UPDATE : " .. sysbench.opt.for_update )
    print( "** FORCE_PRIMARY : " .. sysbench.opt.force_primary )
    print( "** FORCE_NULL : " .. sysbench.opt.force_null )

    if( sysbench.opt.trx_debug > 0 and sysbench.opt.trx_debug < 6 ) then
      trx= trx_name[ sysbench.opt.trx_debug ]
      print( "** DEBUG TRX : " .. trx .. " (trx_debug: " .. sysbench.opt.trx_debug .. ")" )
    end
  end

  drv = sysbench.sql.driver()
  con = drv:connect()

  set_isolation_level( drv, con )
  con:query( "SET autocommit=0" )

  -- >>: mysql session options..
  mysql_session_opt( con )

  if( sysbench.tid == 0 ) then
    print( "=> Using SESSION ops: " .. sysbench.opt.mysql_session_options )
  end

  -- >>: SYNC_file
  if( string.len( sysbench.opt.sync_file ) > 0 )  then
    require( "SYNC_file" )
    SYNC_wait( sysbench.opt.sync_file, sysbench.opt.sync_wait )
  end
end


function event()
  local trx
  -- print( NURand (1023,1,3000))
  -- local trx_type = sysbench.rand.uniform(1,23)
  --
  -- if( trx_type <= 10 )       then    trx= "new_order"
  -- elseif( trx_type <= 20 )   then    trx= "payment"
  -- elseif( trx_type <= 21 )   then    trx= "orderstatus"
  -- elseif( trx_type <= 22 )   then    trx= "delivery"
  -- elseif( trx_type <= 23 )   then    trx= "stocklevel"
  -- end

  if( sysbench.opt.trx_debug > 0 and sysbench.opt.trx_debug < 6 ) then
    trx= trx_name[ sysbench.opt.trx_debug ]
  else
    -- hack: (dim) respect TPCC/DBT2 ratio
    local trx_type = sysbench.rand.uniform( 1, 100 )

    if(     trx_type <= 45 )   then    trx= trx_name[1]
    elseif( trx_type <= 88 )   then    trx= trx_name[2]
    elseif( trx_type <= 92 )   then    trx= trx_name[3]
    elseif( trx_type <= 96 )   then    trx= trx_name[4]
    elseif( trx_type <= 100)   then    trx= trx_name[5]
    end
  end


  -- NOTE: (dim) for debug, let it crash on error..
  -- _G[trx]()

  if( sysbench.opt.trx_retry ) then
    -- Repeat transaction execution until success
    while not pcall( function () _G[trx]() end ) do
      con:query("ROLLBACK")
    end
  else
    -- (dim) just rollback on error..
    if not pcall( function () _G[trx]() end ) then
      con:query("ROLLBACK")
    end
  end

end


-- function sysbench.hooks.report_intermediate( stat )
--   -- print("my stat: ", val)
--   sysbench.report_csv( stat )
-- end
