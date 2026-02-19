-- Copyright (C) 2018-2024 Oracle Corp.
-- implemented and adapted for BMK-kit by Dimitri KRAVTCHUK <dimitri.kravtchuk@oracle.com>
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

-- -----------------------------------------------------------------------------
-- Common code for dbSTRESS benchmark.
-- v.0.1 : Apr.2018 initial code..
-- v.0.2 : Apr.2018 allow (tnum, ref ) execution args..
-- v.0.3 : Apr.2018 anti_dead feature to avoid artificial deadlocks..
-- v.0.4 : Apr.2018 same_ref feature to make transactions more "consistent"..
-- v.0.5 : Apr.2018 better fix for anti_dead REF generation..
-- v.0.6 : Apr.2018 try anti_dead REF generation from original old code..
-- v.0.7 : Apr.2018 more fair anti_dead REF generation from original old code..
-- v.0.8 : Apr.2018 keeping anti_dead REF generation from original old code + info messages
-- v.0.9 : Apr.2018 "hpk" option (HISTORY index PK)
-- v.1.0 : May.2019 first stable version + ordered_load option
-- v.1.1 : Aug.2019 adding proper RW-ratio feature..
-- v.1.2 : Jul.2022 less verbose output on initial data load..
-- -----------------------------------------------------------------------------

require( "mysql_common" )

function init()
  assert( event ~= nil, "this script is meant to be included by other " ..
  "OLTP scripts and should not be called directly." )
end


if sysbench.cmdline.command == nil  then
  error( "Command is required. Supported commands: create, prepare, warmup, run, cleanup. " )
end


-- >>: Command line options..
sysbench.cmdline.options = {
  obj_table_size =          { "Number of rows in OBJECT table (def:1000000)", 1000000 },
  obj_tables =              { "Number of OBJECT tables (def:1)", 1 },
  mysql_storage_engine =    { "Storage Engine to use for tables (def:InnoDB)", "InnoDB" },
  mysql_table_options  =    { "Extra table options, ex.: 'organization=heap'", "" },
  mysql_table_compression = { "Extra table transparent compression option, ex.: 'lz4'", "" },
  mysql_session_options =
    {"Extra session options, e.g. 'SET SESSION sort_buffer_size = 1000000;'", ""},
  mysql_check_charset  =
    { "Check current MySQL connection charset settings (def:false)", false },
  sync_file =
    { "Filename to use for all treads start synchronization (full path filename)", "" },
  sync_wait =
    { "Spin waits time in file synchronization loops (ms)", 10 },
  ordered_load =            { "Initial Load of data is ordered by PK (def:off)", false },
  SEL1 =                    { "Number of SEL1 queries per transaction (def:1)", 1 },
  SEL2 =                    { "Number of SEL2 queries per transaction (def:1)", 1 },
  updates =                 { "Number of UPDATE queries per transaction (def:1)", 1 },
  delete_inserts =          { "Number of DELETE/INSERT combination per transaction (def:1)", 1 },
  for_update =              { "Use FOR UPDATE in SELECTs yes/no (def:no)", false},
  rw_ratio =                { "Ratio between RO and RW transactions (def:1)", 1 },
  hpk =                     { "Use PRIMARY KEY for HISTORY table (def:off)", false },
  anti_dead =               { "Anti-deadlock: each session is using its own REF range (def:on)", true },
  same_ref =                { "Use the same REF value within the same transaction (def:on)", true },
  skip_trx =                { "Execute all queries in the AUTOCOMMIT mode (def:off)", false },
  opt_debug =
    { "enable Sysbench options debug output on test starting.. (def:off)", false }
}

-- >>: Global sizes
INS_RANGE = 100          -- range of OBJECTs to INSERT in single order
N_HISTORY = 20           -- number of HISTORY records per OBJECT

-- Create tables..
function cmd_create()
  local drv = sysbench.sql.driver()
  local con = drv:connect()

  -- >>: mysql session options..
  mysql_session_opt( con )

  if sysbench.tid == 0  then
    for i = 1, sysbench.opt.obj_tables  do
      create_tables( drv, con, i )
    end
  end
end


-- Prepare the dataset.. (in parallel if threads > 1)
function cmd_prepare()
  local tm = os.time()

  if( sysbench.opt.ordered_load ) then
    cmd_prepare_ordered()
  else
    cmd_prepare_normal()
  end

  print( string.format( "=> TOTAL OBJECTs/HISTORY LOAD TIME @thread-%02d : %5.2f min.",
   sysbench.tid, (os.time() - tm) / 60 )
  )
end


-- Prepare the dataset.. (in parallel if threads > 1)
function cmd_prepare_ordered()
  local drv = sysbench.sql.driver()
  local con = drv:connect()
  local m, n, i
  local t_start, v_start
  local t_end, v_end
  local v_size, v_step

  -- >>: mysql session options..
  mysql_session_opt( con )

  v_start = 0
  v_end = sysbench.opt.obj_table_size - 1
  v_step = INS_RANGE

  -- note: pll INSERT progresss, several OBJECT tables..
  if( sysbench.opt.threads > 1 and sysbench.opt.obj_tables > 1 ) then

    if( sysbench.opt.threads == sysbench.opt.obj_tables ) then
      t_start = sysbench.tid + 1
      t_end = t_start
    end

    if( sysbench.opt.threads < sysbench.opt.obj_tables ) then
      t_start = sysbench.tid * math.floor(sysbench.opt.obj_tables / sysbench.opt.threads) + 1
      t_end = t_start + math.floor(sysbench.opt.obj_tables / sysbench.opt.threads) - 1
    end

    if( sysbench.opt.threads > sysbench.opt.obj_tables ) then
      t_start = (sysbench.tid + 1) % sysbench.opt.obj_tables + 1
      t_end = t_start
      v_step = INS_RANGE * math.floor( sysbench.opt.threads / sysbench.opt.obj_tables )
      v_start = INS_RANGE * (sysbench.tid % math.floor( sysbench.opt.threads / sysbench.opt.obj_tables ))
    end

    -- print( string.format( "=> PLL thread-%02d : tab[%d,%d] val[%d + step %d]",
    --   sysbench.tid, t_start, t_end, v_start, v_step )
    -- )

    for i = t_start, t_end do
      for n = v_start, v_end, v_step  do
        m = INS_RANGE - 1

        if( n + m > v_end ) then
          m = v_end - n
        end

        load_data( con, i, n, n+m )
      end
    end

    return
  end

  -- note: wider INSERT progresss, single OBJECT table..
  if( sysbench.opt.threads > 1 ) then
    v_start = sysbench.tid * INS_RANGE
    v_step  = INS_RANGE * sysbench.opt.threads

    -- print( string.format( "=> PLL thread-%02d : tab[%d,%d] val[%d + step %d]",
    --   sysbench.tid, 1, sysbench.opt.obj_tables, v_start, v_step )
    -- )

    for i = 1, sysbench.opt.obj_tables  do
      for n = v_start, v_end, v_step  do
        m = INS_RANGE - 1

        if( n + m > v_end ) then
          m = v_end - n
        end

        load_data( con, i, n, n+m )
      end
    end

    return
  end

  -- note: INSERT single thread..
  -- print( string.format( "=> SINGLE thread-%02d : tab[%d,%d] val[%d,%d]",
  --   sysbench.tid, 1, sysbench.opt.obj_tables, v_start, v_end )
  -- )

  for i = 1, sysbench.opt.obj_tables  do
    for n = v_start, v_end, v_step  do
      m = INS_RANGE - 1

      if( n + m > v_end ) then
        m = v_end - n
      end

      load_data( con, i, n, n+m )
    end
  end

  return
end


-- Prepare the dataset.. (in parallel if threads > 1)
function cmd_prepare_normal()
  local drv = sysbench.sql.driver()
  local con = drv:connect()
  local m, n, i
  local t_start, v_start
  local t_end, v_end
  local v_size

  -- >>: mysql session options..
  mysql_session_opt( con )

  v_start = 0
  v_end = sysbench.opt.obj_table_size - 1

  -- note: pll INSERT progresss, several OBJECT tables..
  if( sysbench.opt.threads > 1 and sysbench.opt.obj_tables > 1 ) then

    if( sysbench.opt.threads == sysbench.opt.obj_tables ) then
      t_start = sysbench.tid + 1
      t_end = sysbench.tid + 1
    end

    if( sysbench.opt.threads < sysbench.opt.obj_tables ) then
      t_start = sysbench.tid * math.floor(sysbench.opt.obj_tables / sysbench.opt.threads) + 1
      t_end = t_start + math.floor(sysbench.opt.obj_tables / sysbench.opt.threads) - 1
    end

    if( sysbench.opt.threads > sysbench.opt.obj_tables ) then
      t_start = (sysbench.tid + 1) % sysbench.opt.obj_tables + 1
      t_end = t_start
      v_size = math.floor(sysbench.opt.obj_table_size / ( sysbench.opt.threads / sysbench.opt.obj_tables ))
      v_start = math.floor( sysbench.tid / sysbench.opt.obj_tables ) * v_size
      v_end = v_start + v_size -1
    end

    -- print( string.format( "=> PLL thread-%02d : tab[%d,%d] val[%d,%d]",
    --   sysbench.tid, t_start, t_end, v_start, v_end )
    -- )

    for i = t_start, t_end do
      for n = v_start, v_end, INS_RANGE  do
        m = INS_RANGE - 1

        if( n + m > v_end ) then
          m = v_end - n
        end

        load_data( con, i, n, n+m )
      end
    end

    return
  end

  -- note: wider INSERT progresss, single OBJECT table..
  if( sysbench.opt.threads > 1 ) then
    v_start = sysbench.tid * sysbench.opt.obj_table_size / sysbench.opt.threads
    v_end   = v_start + sysbench.opt.obj_table_size / sysbench.opt.threads - 1

    -- print( string.format( "=> PLL thread-%02d : tab[%d,%d] val[%d,%d]",
    --   sysbench.tid, 1, sysbench.opt.obj_tables, v_start, v_end )
    -- )

    for i = 1, sysbench.opt.obj_tables  do
      for n = v_start, v_end, INS_RANGE  do
        m = INS_RANGE - 1

        if( n + m > v_end ) then
          m = v_end - n
        end

        load_data( con, i, n, n+m )
      end
    end

    return
  end

  -- note: INSERT single thread..
  -- print( string.format( "=> SINGLE thread-%02d : tab[%d,%d] val[%d,%d]",
  --   sysbench.tid, 1, sysbench.opt.obj_tables, v_start, v_end )
  -- )

  for i = 1, sysbench.opt.obj_tables  do
    for n = v_start, v_end, INS_RANGE  do
      m = INS_RANGE - 1

      if( n + m > v_end ) then
        m = v_end - n
      end

      load_data( con, i, n, n+m )
    end
  end

  return
end


-- Warmup..
function cmd_warmup()
  local drv = sysbench.sql.driver()
  local con = drv:connect()

  assert( drv:name() == "mysql", "warmup is currently MySQL only" )

  -- Do not create on disk tables for subsequent queries
  con:query( "SET tmp_table_size=2*1024*1024*1024" )
  con:query( "SET max_heap_table_size=2*1024*1024*1024" )

  for i = sysbench.tid % sysbench.opt.threads + 1, sysbench.opt.obj_tables, sysbench.opt.threads  do
    local t = "OBJECT" .. i
    print( "Preloading table: " .. t )
    con:query( "ANALYZE TABLE " .. t )
    con:query( "SELECT * FROM " .. t )

    t = "HISTORY" .. i
    print( "Preloading table: " .. t )
    con:query( "ANALYZE TABLE " .. t )
    con:query( "SELECT * FROM " .. t )
  end
end


-- >>: Implement parallel prepare and warmup commands
sysbench.cmdline.commands = {
  create  = { cmd_create,  sysbench.cmdline.PARALLEL_COMMAND },
  prepare = { cmd_prepare, sysbench.cmdline.PARALLEL_COMMAND },
  warmup  = { cmd_warmup,  sysbench.cmdline.PARALLEL_COMMAND },
  prewarm = { cmd_warmup,  sysbench.cmdline.PARALLEL_COMMAND }
}


function create_tables( drv, con, no )
  local engine = ""
  local ext = ""
  local hpk = ""
  local query = ""

  if drv:name() ~= "mysql"  then
    error( "Unsupported database driver:" .. drv:name() )
  end

  engine = sysbench.opt.mysql_storage_engine
  ext = sysbench.opt.mysql_table_options

  if( string.len( sysbench.opt.mysql_table_compression ) > 0 ) then
    ext = ext .. " compression='" .. sysbench.opt.mysql_table_compression .. "' "
  end

  print( "* Creating OBJECT set #" .. no .. "... [engine: " .. engine .. " ext: " .. ext .. "]" )

  query = string.format( [[
    CREATE TABLE ZONE%d
    (
      REF                 CHAR(2)            not null,
      NAME                CHAR(40)           not null
    )
    ENGINE=%s %s
    ]], no, engine, ext
  )
  con:query( query )

  query = string.format( [[
    CREATE TABLE STAT%d
    (
      REF                 CHAR(3)            not null,
      NAME                CHAR(40)           not null,
      NUMB                INT                not null
    )
    ENGINE=%s %s
    ]], no, engine, ext
  )
  con:query( query )

  query = string.format( [[
    CREATE TABLE SECTION%d
    (
      REF                 CHAR(2)            not null,
      REF_ZONE            CHAR(2)            not null,
      NAME                CHAR(40)           not null
    )
    ENGINE=%s %s
    ]], no, engine, ext
  )
  con:query( query )

  query = string.format( [[
    CREATE TABLE OBJECT%d
    (
      REF                 CHAR(10)              not null,
      REF_SECTION         CHAR(2)               not null,
      NAME                CHAR(30)              not null,
      CREATE_DATE         CHAR(12)              not null,
      NOTE                CHAR(100)
    )
    ENGINE=%s %s
    ]], no, engine, ext
  )
  con:query( query )

  query = string.format( [[
    CREATE TABLE HISTORY%d
    (
      REF_OBJECT          CHAR(10)              not null,
      HORDER              INT                   not null,
      REF_STAT            CHAR(3)               not null,
      BEGIN_DATE          CHAR(12)              not null,
      END_DATE            CHAR(12)                      ,
      NOTE                CHAR(100)
    )
    ENGINE=%s %s
    ]], no, engine, ext
  )
  con:query( query )

  -- >>: add indexes..
  print( "* Creating indexes in set #" .. no .. " [hpk:" .. tostring(sysbench.opt.hpk) .. "]..." )
  con:query( "create unique index zone_ref_idx on ZONE" .. no .. "( ref )" )
  con:query( "create unique index stat_ref_idx on STAT" .. no .. "( ref )" )
  con:query( "create unique index section_ref_idx on SECTION" .. no .. "( ref )" )
  con:query( "create unique index object_ref_idx on OBJECT" .. no .. "( ref )" )

  if( sysbench.opt.hpk ) then hpk = "unique" end
  con:query( "create " .. hpk .. " index history_ref_idx on HISTORY" .. no .. "( ref_object, horder )" )

  print( "* Populating reference tables in set #" .. no .. "..." )

  -- >>: STAT table..
  query = "INSERT INTO STAT" .. no .. " VALUES"
  con:bulk_insert_init( query )

  for i = 0, 999  do
    query = string.format( "( '%03d', 'Status %03d XXXXXXXXXXXXXXXXXXXXXXXXXXXXX', 0 )", i, i )
    con:bulk_insert_next(query)
  end
  con:bulk_insert_done()

  -- >>: SECTION table..
  query = "INSERT INTO SECTION" .. no .. " VALUES"
  con:bulk_insert_init( query )

  for i = 0, 99  do
    query = string.format( "( '%02d', '%02d', 'Section %02d XXXXXXXXXXXXXXXXXXXXXXXXXXX' )", i, i%10, i )
    con:bulk_insert_next(query)
  end
  con:bulk_insert_done()

  -- >>: ZONE table..
  query = "INSERT INTO ZONE" .. no .. " VALUES"
  con:bulk_insert_init( query )

  for i = 0, 9  do
    query = string.format( "( '%02d', 'Zone %02d XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' )", i, i )
    con:bulk_insert_next(query)
  end
  con:bulk_insert_done()

  print( "* Done. Ready for 'prepare' step... \n" )
end


function load_data( con, no, a, b )
  local query, i, j

  if( a % 100000 < INS_RANGE )  then
    print( string.format( "Loading DATA OBJECT#%d => %.1fM | range [%dK,+100K]...",
      no, sysbench.opt.obj_table_size / 1000000, a / 1000 )
    )
  end

  -- >>: OBJECT table..
  query = "INSERT INTO OBJECT" .. no .. " VALUES"
  con:bulk_insert_init( query )

  for i = a, b  do
    query = string.format( "( '%010d', '%02d', '%010d NAME XXXXXXXXXXXX', '%02d/%02d/19%02d', '%010d NOTES XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' )",
      i, i%100, i, (i%28)+1, (i%12)+1, i%100, i
    )
    con:bulk_insert_next(query)
  end
  con:bulk_insert_done()

  -- >>: HISTORY table..
  query = "INSERT INTO HISTORY" .. no .. " VALUES"
  con:bulk_insert_init( query )

  for i = a, b  do
    for j = 0, N_HISTORY-1  do
      query = string.format( "( '%010d', %d, '%03d', '%02d/%02d/19%02d', '%02d/%02d/19%02d', '%010d_%02d HISTORY NOTES XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' )",
        i, j, (i+(10*j))%1000,
        ((i+j)%28)+1, ((i+j)%12)+1, (i+j)%100,
        ((i+j)%28)+1, ((i+j)%12)+1, (i+j)%100,
        i, j
      )
      con:bulk_insert_next(query)
    end
  end
  con:bulk_insert_done()
end


function prepare_begin()
  stmt.begin = con:prepare( "BEGIN" )
end


function prepare_commit()
  stmt.commit = con:prepare( "COMMIT" )
end


function prepare_for_each_set( key )
  local t, p

  for t = 1, sysbench.opt.obj_tables  do
    stmt[t][key] = con:prepare( string.format( stmt_defs[key][1], t, t, t ) )

    local nparam = #stmt_defs[key] - 1

    if nparam > 0  then
      param[t][key] = {}
    end

    for p = 1, nparam  do
      local btype = stmt_defs[key][p+1]
      local len

      if type(btype) == "table"  then
        len = btype[2]
        btype = btype[1]
      end

      if btype == sysbench.sql.type.VARCHAR or btype == sysbench.sql.type.CHAR  then
        param[t][key][p] = stmt[t][key]:bind_create( btype, len )
      else
        param[t][key][p] = stmt[t][key]:bind_create( btype )
      end
    end

    if nparam > 0  then
      stmt[t][key]:bind_param( unpack(param[t][key]) )
    end
  end
end


function prepare_SEL1()
  prepare_for_each_set( "SEL1" )
end


function prepare_SEL2()
  prepare_for_each_set( "SEL2" )
end


function prepare_INSDEL()
  prepare_INSERT()
  prepare_DELETE()
end


function prepare_INSERT()
  prepare_for_each_set( "INSERT" )
end


function prepare_DELETE()
  prepare_for_each_set( "DELETE" )
end


function prepare_UPDATE()
  prepare_for_each_set( "UPDATE" )
end


function thread_init()
  drv = sysbench.sql.driver()
  con = drv:connect()
  ops = 0
  local tno

  -- >>: SQL Queries..
  local t = sysbench.sql.type
  local upd = ""

  if( sysbench.opt.for_update ) then
    upd = "FOR UPDATE "
  end

  stmt_defs = {
    SEL1 = {
      "SELECT S.REF as sref, S.NAME as snm, Z.REF as zref, Z.NAME as znm, O.NAME as onm, O.CREATE_DATE as ocd, O.NOTE as onote from OBJECT%d O, SECTION%d S, ZONE%d Z where S.REF = O.REF_SECTION and Z.REF = S.REF_ZONE and O.REF = ? " .. upd,
      {t.CHAR, 10}
    },

    SEL2 = {
      "SELECT S.REF as stref, S.NAME as stnm, H.HORDER as hord, H.BEGIN_DATE as hbeg, H.END_DATE as hend, H.NOTE as hnote from HISTORY%d H, STAT%d S where S.REF = H.REF_STAT and H.REF_OBJECT = ? order by H.HORDER " .. upd,
      {t.CHAR, 10}
    },

    UPDATE = {
      "UPDATE HISTORY%d SET REF_STAT = ?, BEGIN_DATE = ?, END_DATE = ?, NOTE = ? WHERE REF_OBJECT = ? AND HORDER = ? ",
        {t.CHAR, 3}, {t.CHAR, 12}, {t.CHAR, 12}, {t.CHAR, 100}, {t.CHAR, 10}, t.INT
    },

    DELETE = {
      "DELETE FROM HISTORY%d WHERE REF_OBJECT = ? AND HORDER = ? ",
        {t.CHAR, 10}, t.INT
    },

    INSERT = {
      "INSERT INTO HISTORY%d VALUES ( ?, ?, ?, ?, ?, ? )",
        {t.CHAR, 10}, t.INT, {t.CHAR, 3}, {t.CHAR, 12}, {t.CHAR, 12}, {t.CHAR, 100}
    }
  }

  if( sysbench.opt.rw_ratio == nil or sysbench.opt.rw_ratio < 1 ) then
    sysbench.opt.rw_ratio = 1
  end

  -- >>: mysqlsession options..
  mysql_session_opt( con )

  if( sysbench.tid == 0 ) then
    print( "* THREADS      : [" .. tostring( sysbench.opt.threads ) .. "]" )
    print( "* OBJ SIZE     : [" .. tostring( sysbench.opt.obj_table_size / 1000000 ) .. "M]" )
    print( "* OBJ SETS     : [" .. tostring( sysbench.opt.obj_tables ) .. "]" )
    print( "* anti_dead    : [" .. tostring( sysbench.opt.anti_dead ) .. "]" )
    print( "* same_ref     : [" .. tostring( sysbench.opt.same_ref )  .. "]" )
    print( "* SEL1         : [" .. tostring( sysbench.opt.SEL1 )      .. "]" )
    print( "* SEL2         : [" .. tostring( sysbench.opt.SEL2 )      .. "]" )
    print( "* UPDATE       : [" .. tostring( sysbench.opt.updates )   .. "]" )
    print( "* INSDEL       : [" .. tostring( sysbench.opt.delete_inserts )   .. "]" )
    print( "* RW-ratio     : [" .. tostring( sysbench.opt.rw_ratio )   .. "]" )
    print( "* SESSION-ops  : [" .. tostring( sysbench.opt.mysql_session_options )   .. "]" )

    check_opt_debug()
  end

  -- Create global nested tables for prepared statements and their
  -- parameters. We need a statement and a parameter set for each combination
  -- of connection/table/query
  stmt = {}
  param = {}

  for tno = 1, sysbench.opt.obj_tables  do
    stmt[tno] = {}
    param[tno] = {}
  end

  -- This function is a 'callback' defined by individual benchmark scripts
  prepare_statements()

  -- >>: SYNC_file
  if( string.len( sysbench.opt.sync_file ) > 0 )  then
    require( "SYNC_file" )
    SYNC_wait( sysbench.opt.sync_file, sysbench.opt.sync_wait )
  end
end


function thread_done()
  local t

  -- Close prepared statements
  for t = 1, sysbench.opt.obj_tables  do
    for k, s in pairs( stmt[t] )  do
      stmt[t][k]:close()
    end
  end

  if( stmt.begin ~= nil )  then
    stmt.begin:close()
  end

  if( stmt.commit ~= nil )  then
    stmt.commit:close()
  end

  con:disconnect()
end


function cleanup()
  local drv = sysbench.sql.driver()
  local con = drv:connect()
  local i

  for i = 1, sysbench.opt.obj_tables  do
    print( "Dropping OBJECT set #" .. i .. " ..."  )
    con:query( "DROP TABLE IF EXISTS OBJECT"  .. i )
    con:query( "DROP TABLE IF EXISTS HISTORY" .. i )
    con:query( "DROP TABLE IF EXISTS STAT"    .. i )
    con:query( "DROP TABLE IF EXISTS SECTION" .. i )
    con:query( "DROP TABLE IF EXISTS ZONE"    .. i )
  end
end


function get_set_num()
  return sysbench.rand.uniform( 1, sysbench.opt.obj_tables )
end


function get_ref()
  return get_ref_v05()
end


function get_ref_v07()
  local ref = sysbench.rand.default( 0, sysbench.opt.obj_table_size - 1 )

  if( sysbench.opt.anti_dead ) then
    ref = ref - ref % (sysbench.opt.threads * 2) + sysbench.tid + 1
  end

  return string.format( "%010d", ref )
end


function get_ref_v06()
  local ref = sysbench.rand.default( 0, sysbench.opt.obj_table_size - 1 )

  if( sysbench.opt.anti_dead ) then
    ref = ref - ref % 2000 + sysbench.tid + 1
  end

  return string.format( "%010d", ref )
end


function get_ref_v05()
  local ref

  if( sysbench.opt.anti_dead ) then
    ref = sysbench.rand.default( 5, sysbench.opt.obj_table_size / sysbench.opt.threads - 5 )
    ref = ref + sysbench.tid * sysbench.opt.obj_table_size / sysbench.opt.threads
  else
    ref = sysbench.rand.default( 0, sysbench.opt.obj_table_size - 1 )
  end

  return string.format( "%010d", ref )
end


local function get_horder()
  return sysbench.rand.uniform( 0, N_HISTORY-1 )
end


local function get_state()
  return string.format( "%03d", sysbench.rand.uniform( 0, 999 ) )
end


local function get_date()
  local d = sysbench.rand.uniform( 0, 99 )
  return string.format( "%02d/%02d/19%02d", d%28+1, d%12+1, d%100 )
end


function execute_begin()
  stmt.begin:execute()
end


function execute_commit()
  stmt.commit:execute()
end


function execute_SEL1( tnum, ref )
  local i

  if( tnum == nil ) then  tnum = get_set_num()  end
  if( ref  == nil ) then  ref  = get_ref()      end

  for i = 1, sysbench.opt.SEL1 do
    if( i > 1 ) then  ref = get_ref()  end

    param[tnum].SEL1[1]:set( ref )
    stmt[tnum].SEL1:execute()
  end
end


function execute_SEL2( tnum, ref )
  local i

  if( tnum == nil ) then  tnum = get_set_num()  end
  if( ref  == nil ) then  ref  = get_ref()      end

  for i = 1, sysbench.opt.SEL2 do
    if( i > 1 ) then  ref = get_ref()  end

    param[tnum].SEL2[1]:set( ref )
    stmt[tnum].SEL2:execute()
  end
end


function execute_INSDEL( tnum, ref )
  local xx = "XXXXXXXXXXXXXXXXXXXXXXXX"
  local i

  if( ops % sysbench.opt.rw_ratio ~= 0 ) then
    return(-1)
  end

  if( tnum == nil ) then  tnum = get_set_num()  end
  if( ref  == nil ) then  ref  = get_ref()      end

  for i = 1, sysbench.opt.delete_inserts do
    if( i > 1 ) then  ref = get_ref()  end

    local horder = get_horder()
    local state  = get_state()
    local date   = get_date()
    local note   = string.format( "%s NOTE State %s FOR REF#%s-%d %s %s %s %s",
          date, state, ref, horder, xx, xx, xx, xx )
    note = string.sub( note, 1, 100 )

    param[tnum].DELETE[1]:set( ref )
    param[tnum].DELETE[2]:set( horder )

    stmt[tnum].DELETE:execute()

    param[tnum].INSERT[1]:set( ref )
    param[tnum].INSERT[2]:set( horder )
    param[tnum].INSERT[3]:set( state )
    param[tnum].INSERT[4]:set( date )
    param[tnum].INSERT[5]:set( date )
    param[tnum].INSERT[6]:set( note )

    stmt[tnum].INSERT:execute()
  end
end


function execute_UPDATE( tnum, ref )
  local xx = "XXXXXXXXXXXXXXXXXXXXXXXX"
  local i

  if( ops % sysbench.opt.rw_ratio ~= 0 ) then
    return(-1)
  end

  if( tnum == nil ) then  tnum = get_set_num()  end
  if( ref  == nil ) then  ref  = get_ref()      end

  for i = 1, sysbench.opt.updates do
    if( i > 1 ) then  ref = get_ref()  end

    local horder = get_horder()
    local state  = get_state()
    local date   = get_date()
    local note   = string.format( "%s NOTE State %s FOR REF#%s-%d %s %s %s %s",
          date, state, ref, horder, xx, xx, xx, xx )
    note = string.sub( note, 1, 100 )

    param[tnum].UPDATE[1]:set( state )
    param[tnum].UPDATE[2]:set( date )
    param[tnum].UPDATE[3]:set( date )
    param[tnum].UPDATE[4]:set( note )
    param[tnum].UPDATE[5]:set( ref )
    param[tnum].UPDATE[6]:set( horder )

    stmt[tnum].UPDATE:execute()
  end
end
