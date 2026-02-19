-- Copyright (C) 2018-2024 Oracle Corp.
-- remastered and adapted for BMK-kit by Dimitri KRAVTCHUK <dimitri.kravtchuk@oracle.com>
-- BMK-kit howto : http://dimitrik.free.fr/blog/posts/mysql-perf-bmk-kit.html

-- Copyright (C) 2006-2017 Alexey Kopytov <akopytov@gmail.com>

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
-- Common code for OLTP benchmarks.
-- -----------------------------------------------------------------------------

require( "mysql_common" )

-- >>: Template strings of random digits with 11-digit groups separated by dashes

-- 10 groups, 119 characters, random
local temp_rnd1 = "###########-###########-###########-" ..
   "###########-###########-###########-" ..
   "###########-###########-###########-" ..
   "###########"

-- 5 groups, 59 characters, random
local temp_rnd2 = "###########-###########-###########-" ..
   "###########-###########"

-- 10 groups, 119 characters, fixed
local temp_fix1 = "1234567890X-1234567890X-1234567890X-" ..
   "1234567890X-1234567890X-1234567890X-" ..
   "1234567890X-1234567890X-1234567890X-" ..
   "1234567890X"

-- 5 groups, 59 characters, fixed
local temp_fix2 = "1234567890X-1234567890X-1234567890X-" ..
   "1234567890X-1234567890X"

-- final templates according to rand_data %
local c_value_template = ""
local pad_value_template = ""


function setup_templates()
  local n

  if( sysbench.opt.rand_data < 0 or sysbench.opt.rand_data > 100 ) then
    error( "rand_data value (%) should be within [0,100]% interval !!" )
  end

  n = math.floor( sysbench.opt.rand_data * 119 / 100 )
  c_value_template = string.sub( temp_rnd1, 1, n ) .. string.sub( temp_fix1, 1, 119-n )

  n = math.floor( sysbench.opt.rand_data * 59 / 100 )
  pad_value_template = string.sub( temp_rnd2, 1, n ) .. string.sub( temp_fix2, 1, 59-n )

  if( sysbench.tid == 0 ) then
    print( "=> rand_data: " .. sysbench.opt.rand_data .. "(%)" )
    -- print( "=> temp.c   : " .. c_value_template .. "\n" )
    -- print( "=> temp.pad : " .. pad_value_template .. "\n" )
  end
end


function init()
  assert( event ~= nil,
    "this script is meant to be included by other OLTP scripts and " ..
    "should not be called directly." )
end


if sysbench.cmdline.command == nil then
   error("Command is required. Supported commands: create, prepare, warmup, run, cleanup, help")
end

-- >>: Command line options
sysbench.cmdline.options = {
  table_size =
    {"Number of rows per table", 10000},
  table_name =
    {"base name for table(s)", "sbtest"},
  extra_cols =
    {"number of extra columns to add to the table", 0},
  extra_cols_type =
    {"extra columns type", "VARCHAR(32)"},
  extra_cols_default =
    {"extra columns default value", "1234567890-1234567890-1234567890"},
  extra_cols_options =
    {"extra columns options", ""},
  extra_query_before =
    {"extra SQL query to execute before EVENT", ""},
  extra_query_after =
    {"extra SQL query to execute after EVENT", ""},
  range_size =
    {"Range size for range SELECT queries", 100},
  update_range_size =
    {"Range size for range UPDATE queries", 0},
  tables =
    {"Number of tables", 1},
  point_selects =
    {"Number of point SELECT queries per transaction", 10},
  simple_ranges =
    {"Number of simple range SELECT queries per transaction", 1},
  sum_ranges =
    {"Number of SELECT SUM() queries per transaction", 1},
  order_ranges =
    {"Number of SELECT ORDER BY queries per transaction", 1},
  distinct_ranges =
    {"Number of SELECT DISTINCT queries per transaction", 1},
  index_updates =
    {"Number of UPDATE index queries per transaction", 1},
  non_index_updates =
    {"Number of UPDATE non-index queries per transaction", 1},
  delete_inserts =
    {"Number of DELETE/INSERT combination per transaction", 1},
  inserts_only =
    {"Number of auto-inc INSERT queries per transaction", 1},
  select_cols =
    {"column names to use in SELECT for point-selects and simple/ordered range queries (def: c)", "c"},
  by_secidx =
    {"use sec.index column value in WHERE clauses (def: false)", false},
  range_selects =
    {"Enable/disable all range SELECT queries", true},
  rand_loop =
    {"Use random-loop instead of rand() : 0=def, 1=chunk, 2=shift, 3=loop (def:0)", 0},
  rand_data =
    {"Percentage (%) of random data in row values : 1 .. 100 (def:100)", 100},
  auto_inc =
  {"Use AUTO_INCREMENT column as Primary Key (for MySQL), " ..
     "or its alternatives in other DBMS. When disabled, use " ..
     "client-generated IDs", true},
  skip_trx =
    {"Don't start explicit transactions and execute all queries in the AUTOCOMMIT mode", false},
  sleep_before_commit =
    {"Sleep given time (usec) before COMMIT (for advanced test scenarios simulation)", 0},
  sleep_after_query =
    {"Sleep given time (usec) after each Query execution (for advanced test scenarios simulation)", 0},
  secondary =
    {"Use a secondary index in place of the PRIMARY KEY", false},
  create_secondary =
    {"Create a secondary index in addition to the PRIMARY KEY", true},
  mysql_storage_engine =
    {"Storage engine, if MySQL is used", "innodb"},
  mysql_table_options  =
    { "Extra table options, ex.: 'organization=heap'", "" },
  mysql_session_options =
    {"Extra session options, ex. 'set session sort_buffer_size=256000; set session ... '", ""},
  mysql_query_hint =
    {"Extra query hint, ex. 'RESOURCE_GROUP(FAST)'", ""},
  mysql_table_compression  =
    { "Extra table transparent compression option, ex.: 'lz4'", "" },
  mysql_table_partitions  =
    { "Extra table partitions option, ex.: 10 (def:0)", 0 },
  mysql_check_charset  =
    { "Check current MySQL connection charset settings (def:false)", false },
  load_mode =
    { "Initial Data Load Mode [original, parallel, parallel_ordered] (def:parallel)", "parallel" },
  load_bulk_size =
    { "Number of rows to use in BULK_INSERT during parallel* Load of data (def:1000)", 1000 },
  trx_retry =
    { "Retry to replay the same transaction again in case of ROLLBACK/DEDALOCK (def:off)", false },
  sync_file =
    { "Filename to use for all treads start synchronization (full path filename)", "" },
  sync_wait =
    { "Spin waits time in file synchronization loops (ms)", 10 },
  opt_debug =
    { "enable Sysbench options debug output on test starting.. (def:off)", false },
  pgsql_variant =
    {"Use this PostgreSQL variant when running with the " ..
        "PostgreSQL driver. The only currently supported " ..
        "variant is 'redshift'. When enabled, " ..
        "create_secondary is automatically disabled, and " ..
        "delete_inserts is set to 0"}
}


--------------------------------------------------------------------
-- (dim) Parallel DATA LOAD ported from dbSTRESS code..
--------------------------------------------------------------------

-- Global sizes
INS_RANGE = 1000     -- number of rows per INSERT

-- Create tables..
function cmd_create()
  local drv = sysbench.sql.driver()
  local con = drv:connect()

  -- >>: mysql session options..
  mysql_session_opt( con )

  if sysbench.tid == 0  then
    for i = 1, sysbench.opt.tables  do
      create_tables( drv, con, i )
    end
  end
end


-- Prepare the dataset.. (in parallel if threads > 1)
function cmd_prepare()
  local tm = os.time()
  setup_templates()

  local drv = sysbench.sql.driver()
  local con = drv:connect()

  -- >>: mysql session options..
  mysql_session_opt( con )

  if( sysbench.tid == 0 ) then
    print( string.format( "=> TABLE LOAD MODE : [%s]", sysbench.opt.load_mode ))
  end

  if( sysbench.opt.load_mode == "original" ) then
    cmd_prepare_original( drv, con )
  else
    if( sysbench.opt.load_bulk_size > 0 and sysbench.opt.load_bulk_size <= sysbench.opt.table_size ) then
      INS_RANGE = sysbench.opt.load_bulk_size
    end

    if( sysbench.opt.load_mode == "parallel" ) then
      cmd_prepare_parallel( drv, con )
    else
      cmd_prepare_ordered( drv, con )
    end
  end

  print( string.format( "=> TOTAL TABLE(s) LOAD TIME @thread-%02d : %5.2f min.",
   sysbench.tid, (os.time() - tm) / 60 )
  )
end


-- Prepare the dataset.. (in parallel if threads > 1)
function cmd_prepare_ordered( drv, con )
  local m, n, i
  local t_start, v_start
  local t_end, v_end
  local v_size, v_step

  v_start = 0
  v_end = sysbench.opt.table_size - 1
  v_step = INS_RANGE

  -- note: pll INSERT progresss, several tables..
  if( sysbench.opt.threads > 1 and sysbench.opt.tables > 1 ) then

    if( sysbench.opt.threads == sysbench.opt.tables ) then
      t_start = sysbench.tid + 1
      t_end = t_start
    end

    if( sysbench.opt.threads < sysbench.opt.tables ) then
      t_start = sysbench.tid * math.floor(sysbench.opt.tables / sysbench.opt.threads) + 1
      t_end = t_start + math.floor(sysbench.opt.tables / sysbench.opt.threads) - 1
    end

    if( sysbench.opt.threads > sysbench.opt.tables ) then
      t_start = (sysbench.tid + 1) % sysbench.opt.tables + 1
      t_end = t_start
      v_step = INS_RANGE * math.floor( sysbench.opt.threads / sysbench.opt.tables )
      v_start = INS_RANGE * (sysbench.tid % math.floor( sysbench.opt.threads / sysbench.opt.tables ))
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

  -- note: wider INSERT progresss, single table..
  if( sysbench.opt.threads > 1 ) then
    v_start = sysbench.tid * INS_RANGE
    v_step  = INS_RANGE * sysbench.opt.threads

    -- print( string.format( "=> PLL thread-%02d : tab[%d,%d] val[%d + step %d]",
    --   sysbench.tid, 1, sysbench.opt.tables, v_start, v_step )
    -- )

    for i = 1, sysbench.opt.tables  do
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
  --   sysbench.tid, 1, sysbench.opt.tables, v_start, v_end )
  -- )

  for i = 1, sysbench.opt.tables  do
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
function cmd_prepare_parallel( drv, con )
  local m, n, i
  local t_start, v_start
  local t_end, v_end
  local v_size

  v_start = 0
  v_end = sysbench.opt.table_size - 1

  -- note: pll INSERT progresss, several tables..
  if( sysbench.opt.threads > 1 and sysbench.opt.tables > 1 ) then

    if( sysbench.opt.threads == sysbench.opt.tables ) then
      t_start = sysbench.tid + 1
      t_end = sysbench.tid + 1
    end

    if( sysbench.opt.threads < sysbench.opt.tables ) then
      t_start = sysbench.tid * math.floor(sysbench.opt.tables / sysbench.opt.threads) + 1
      t_end = t_start + math.floor(sysbench.opt.tables / sysbench.opt.threads) - 1
    end

    if( sysbench.opt.threads > sysbench.opt.tables ) then
      t_start = (sysbench.tid + 1) % sysbench.opt.tables + 1
      t_end = t_start
      v_size = math.floor(sysbench.opt.table_size / ( sysbench.opt.threads / sysbench.opt.tables ))
      v_start = math.floor( sysbench.tid / sysbench.opt.tables ) * v_size
      v_end = v_start + v_size -1
    end

    -- print( string.format( "=> PLL thread-%02d : tab[%d,%d] val[%d,%d]",
    --   sysbench.tid, t_start, t_end, v_start, v_end )
    -- )

    for i = t_start, t_end do
      load_range( con, i, v_start, v_end, INS_RANGE )
    end

    return
  end

  -- note: wider INSERT progresss, single table..
  if( sysbench.opt.threads > 1 ) then
    v_start = sysbench.tid * sysbench.opt.table_size / sysbench.opt.threads
    v_end   = v_start + sysbench.opt.table_size / sysbench.opt.threads - 1

    -- print( string.format( "=> PLL thread-%02d : tab[%d,%d] val[%d,%d]",
    --   sysbench.tid, 1, sysbench.opt.tables, v_start, v_end )
    -- )

    for i = 1, sysbench.opt.tables  do
      load_range( con, i, v_start, v_end, INS_RANGE )
    end

    return
  end

  -- note: INSERT single thread..
  -- print( string.format( "=> SINGLE thread-%02d : tab[%d,%d] val[%d,%d]",
  --   sysbench.tid, 1, sysbench.opt.tables, v_start, v_end )
  -- )

  for i = 1, sysbench.opt.tables  do
    load_range( con, i, v_start, v_end, INS_RANGE )
  end

  return
end


function load_range( con, tabno, v_start, v_end, v_range )
  local n, m
  local save_id = 0
  local prev_id = 0

  n = v_start

  -- using "while" to workaround "for" bug...
  while true do
    m = v_range - 1

    if( n + m > v_end ) then
      m = v_end - n
    end

    -- print( string.format( "=> LOAD thread-%02d : tab#%d id[%d,...] save:%d prev:%d\n",
    --   sysbench.tid, tabno, n+1, save_id+1, prev_id+1 )
    -- )

    load_data( con, tabno, n, n+m )
    prev_id = save_id
    save_id = n

    n = n + v_range
    if( n > v_end )  then
      break
    end
  end

end


function cmd_prepare_original( drv, con )
  local i

  for i = sysbench.tid % sysbench.opt.threads + 1, sysbench.opt.tables, sysbench.opt.threads do
    load_data_original( con, i )
  end
end


function load_data_original( con, table_num )
  local query

  print(string.format("Inserting %d records into '%s%d'",
    sysbench.opt.table_name, sysbench.opt.table_size, table_num))

  if sysbench.opt.auto_inc then
    query = "INSERT INTO " .. sysbench.opt.table_name .. table_num .. "(k, c, pad) VALUES"
  else
    query = "INSERT INTO " .. sysbench.opt.table_name .. table_num .. "(id, k, c, pad) VALUES"
  end

  con:bulk_insert_init(query)

  local c_val
  local pad_val
  local i

  for i = 1, sysbench.opt.table_size do
    c_val = get_c_value()
    pad_val = get_pad_value()

    if (sysbench.opt.auto_inc) then
      query = string.format("(%d, '%s', '%s')",
      sysbench.rand.uniform( 1, sysbench.opt.table_size ), c_val, pad_val)
    else
      query = string.format("(%d, %d, '%s', '%s')",
      i, sysbench.rand.uniform( 1, sysbench.opt.table_size ), c_val, pad_val)
    end

    con:bulk_insert_next(query)
  end

  con:bulk_insert_done()

  if sysbench.opt.create_secondary then
    print(string.format("Creating a secondary index on '%s%d'...", sysbench.opt.table_name, table_num))
    con:query(string.format("CREATE INDEX k_%d ON %s%d(k)", sysbench.opt.table_name, table_num, table_num))
  end
end


-- Preload the dataset into the server cache. This command supports parallel
-- execution, i.e. will benefit from executing with --threads > 1 as long as
-- --tables > 1
--
-- PS. Currently, this command is only meaningful for MySQL/InnoDB benchmarks
function cmd_warmup()
  local drv = sysbench.sql.driver()
  local con = drv:connect()
  local i

  assert(drv:name() == "mysql", "warmup is currently MySQL only")

  -- Do not create on disk tables for subsequent queries
  con:query("SET tmp_table_size=2*1024*1024*1024")
  con:query("SET max_heap_table_size=2*1024*1024*1024")

  for i = sysbench.tid % sysbench.opt.threads + 1, sysbench.opt.tables, sysbench.opt.threads
  do
    local t = sysbench.opt.table_name .. i
    print("Preloading table " .. t )
    con:query("ANALYZE TABLE " .. t )

    con:query(string.format(
      "SELECT AVG(id) FROM " ..
        "(SELECT * FROM %s FORCE KEY (PRIMARY) " ..
        "LIMIT %u) t",
      t, sysbench.opt.table_size))

    con:query(string.format(
      "SELECT COUNT(*) FROM " ..
        "(SELECT * FROM %s WHERE k LIKE '%%0%%' LIMIT %u) t",
      t, sysbench.opt.table_size))
  end
end


-- Implement parallel prepare and warmup commands, define 'prewarm' as an alias
-- for 'warmup'
sysbench.cmdline.commands = {
   create  = {cmd_create,  sysbench.cmdline.PARALLEL_COMMAND},
   prepare = {cmd_prepare, sysbench.cmdline.PARALLEL_COMMAND},
   warmup  = {cmd_warmup,  sysbench.cmdline.PARALLEL_COMMAND},
   prewarm = {cmd_warmup,  sysbench.cmdline.PARALLEL_COMMAND}
}


function get_c_value()
   return sysbench.rand.string(c_value_template)
end


function get_pad_value()
   return sysbench.rand.string(pad_value_template)
end


function create_tables( drv, con, table_num )
  local id_index_def, id_def
  local engine_def = ""
  local extra_table_options = ""
  local extra_cols = ""
  local parts = ""
  local query

  -- setup_templates()

  if sysbench.opt.secondary then
    id_index_def = "KEY xid"
  else
    id_index_def = "PRIMARY KEY"
  end

  if drv:name() == "mysql" or drv:name() == "attachsql" or drv:name() == "drizzle"
  then
    if sysbench.opt.auto_inc then
      id_def = "BIGINT NOT NULL AUTO_INCREMENT"
    else
      id_def = "BIGINT NOT NULL"
    end

    engine_def = "ENGINE = " .. sysbench.opt.mysql_storage_engine
    extra_table_options = sysbench.opt.mysql_table_options

    if( string.len( sysbench.opt.mysql_table_compression ) > 0 ) then
      extra_table_options = extra_table_options .. " compression='" ..
        sysbench.opt.mysql_table_compression .. "' "
    end

  elseif drv:name() == "pgsql"
  then
    if not sysbench.opt.auto_inc then
      id_def = "INTEGER NOT NULL"
    elseif pgsql_variant == 'redshift' then
      id_def = "INTEGER IDENTITY(1,1)"
    else
      id_def = "SERIAL"
    end
  else
    error("Unsupported database driver:" .. drv:name())
  end

  print(string.format( "Creating table '%s%d' [%s]...",
    sysbench.opt.table_name, table_num, extra_table_options ))

  -- >>: partitions..
  if( sysbench.opt.mysql_table_partitions > 1 )
  then
    local no, size

    print( "with " .. sysbench.opt.mysql_table_partitions .. " partitions" )
    size = math.floor(sysbench.opt.table_size / sysbench.opt.mysql_table_partitions) + 1

    parts = "partition by range( id ) ( \n"
    for no = 1, sysbench.opt.mysql_table_partitions - 1
    do
      parts = parts .. "   partition p" .. no .. " values less than (" .. no * size .. "),\n"
    end

    parts = parts .. "   partition p00 values less than (MAXVALUE)\n)\n"
  end

  if( sysbench.opt.extra_cols > 0 )
  then
    local no

    for no = 1, sysbench.opt.extra_cols
    do
      extra_cols = extra_cols .. "col" .. no .. " " .. sysbench.opt.extra_cols_type .. " " .. sysbench.opt.extra_cols_options .. ", "
    end
  end

  query = string.format([[
      CREATE TABLE %s%d(
        id %s,
        k BIGINT DEFAULT '0' NOT NULL,
        c CHAR(120) DEFAULT '' NOT NULL,
        pad CHAR(60) DEFAULT '' NOT NULL,
        %s
        %s (id)
      ) %s %s %s ]],
      sysbench.opt.table_name, table_num, id_def, extra_cols, id_index_def, engine_def, extra_table_options, parts )

  -- print( "QUERY: " .. query )
  con:query(query)

  if sysbench.opt.create_secondary and sysbench.opt.load_mode ~= "original" then
    print( string.format( "Creating a secondary index on '%s%d'...",
      sysbench.opt.table_name, table_num ))
    con:query( string.format( "CREATE INDEX k_%d ON %s%d(k)",
      table_num, sysbench.opt.table_name, table_num ))
  end
end


function load_data( con, no, a, b )
  local query, bsize, i
  local c_val
  local pad_val

  a = a + 1
  b = b + 1

  bsize = math.floor( sysbench.opt.table_size / 5 )

  if( a % bsize < INS_RANGE )  then
    print( string.format( "Loading DATA TABLE#%d => %.1fM @bulk_size %dK | range [%5.1fM + %.1fM]...",
      no, sysbench.opt.table_size / 1000000, INS_RANGE / 1000, a / 1000000, bsize / 1000000 )
    )
  end

  if sysbench.opt.auto_inc then
    query = "INSERT INTO " .. sysbench.opt.table_name .. no .. "(k, c, pad"
  else
    query = "INSERT INTO " .. sysbench.opt.table_name .. no .. "(id, k, c, pad"
  end

  if( sysbench.opt.extra_cols > 0 )
  then
    local no

    for no = 1, sysbench.opt.extra_cols
    do
      query = query .. ", col" .. no
    end
  end
  query = query .. ") VALUES"

  con:bulk_insert_init(query)

  for i = a, b
  do
    c_val = get_c_value()
    pad_val = get_pad_value()

    if( sysbench.opt.auto_inc ) then
      query = string.format("(%d, '%s', '%s' ",
      sysbench.rand.uniform( 1, sysbench.opt.table_size ), c_val, pad_val )
    else
      query = string.format("(%d, %d, '%s', '%s' ",
      i, sysbench.rand.uniform( 1, sysbench.opt.table_size ), c_val, pad_val )
    end

    if( sysbench.opt.extra_cols > 0 )
    then
      local no

      for no = 1, sysbench.opt.extra_cols
      do
        query = query .. ",'" .. sysbench.rand.string( sysbench.opt.extra_cols_default ) .. "' "
      end
    end

    query = query .. ")"
    con:bulk_insert_next(query)
  end

  con:bulk_insert_done()
end


function prepare_begin()
  if( sysbench.tid == 0 ) then
    print( "=> using BEGIN" )
  end
  stmt.begin = con:prepare( "BEGIN" )
end


function prepare_commit()
  if( sysbench.tid == 0 ) then
    print( "=> using COMMIT" )
  end
  stmt.commit = con:prepare( "COMMIT" )
end


function prepare_for_each_table( key )
  for t = 1, sysbench.opt.tables do
    stmt[t][key] = con:prepare(string.format(stmt_defs[key][1], t))

    local nparam = #stmt_defs[key] - 1

    if( nparam > 0 ) then
      param[t][key] = {}
    end

    for p = 1, nparam do
      local btype = stmt_defs[key][p+1]
      local len

      if( type(btype) == "table" ) then
        len = btype[2]
        btype = btype[1]
      end

      if( btype == sysbench.sql.type.VARCHAR or btype == sysbench.sql.type.CHAR ) then
        param[t][key][p] = stmt[t][key]:bind_create(btype, len)
      else
        param[t][key][p] = stmt[t][key]:bind_create(btype)
      end
    end

    if( nparam > 0 ) then
      stmt[t][key]:bind_param(unpack(param[t][key]))
    end
  end
end


function prepare_point_selects()
  if( sysbench.tid == 0 ) then
    print( "=> using point-SELECTs: " .. sysbench.opt.point_selects )
  end
  prepare_for_each_table( "point_selects" )
end


function prepare_simple_ranges()
  if( sysbench.tid == 0 ) then
    print( "=> using simple-range-SELECTs: " .. sysbench.opt.simple_ranges )
  end
  prepare_for_each_table( "simple_ranges" )
end


function prepare_sum_ranges()
  if( sysbench.tid == 0 ) then
    print( "=> using sum-range-SELECTs: " .. sysbench.opt.sum_ranges )
  end
  prepare_for_each_table( "sum_ranges" )
end


function prepare_order_ranges()
  if( sysbench.tid == 0 ) then
    print( "=> using order-range-SELECTs: " .. sysbench.opt.order_ranges )
  end
  prepare_for_each_table( "order_ranges" )
end


function prepare_distinct_ranges()
  if( sysbench.tid == 0 ) then
    print( "=> using distinct-range-SELECTs: " .. sysbench.opt.distinct_ranges )
  end
  prepare_for_each_table( "distinct_ranges" )
end


function prepare_index_updates()
  if( sysbench.opt.update_range_size > 0 ) then
    if( sysbench.tid == 0 ) then
      print( "=> using index-UPDATE-ranges: " .. sysbench.opt.index_updates ..
        " update-range-size: " .. sysbench.opt.update_range_size )
    end
    prepare_for_each_table( "index_updates_range" )
  else
    if( sysbench.tid == 0 ) then
      print( "=> using index-UPDATEs: " .. sysbench.opt.index_updates )
    end
    prepare_for_each_table( "index_updates" )
  end
end


function prepare_non_index_updates()
  if( sysbench.opt.update_range_size > 0 ) then
    if( sysbench.tid == 0 ) then
      print( "=> using non-index-UPDATE-ranges: " .. sysbench.opt.non_index_updates ..
        " update-range-size: " .. sysbench.opt.update_range_size )
    end
    prepare_for_each_table( "non_index_updates_range" )
  else
    if( sysbench.tid == 0 ) then
      print( "=> using non-index-UPDATEs: " .. sysbench.opt.non_index_updates )
    end
    prepare_for_each_table( "non_index_updates" )
  end
end


function prepare_delete_inserts()
  if( sysbench.tid == 0 ) then
    print( "=> using DELETE+INSERTs, delete-inserts: " .. sysbench.opt.delete_inserts )
  end
  prepare_for_each_table( "deletes" )
  prepare_inserts_only()
end


function prepare_inserts_only()
  if( sysbench.tid == 0 ) then
    print( "=> using INSERTs, inserts-only: " .. sysbench.opt.inserts_only )
  end
  prepare_for_each_table( "inserts" )
end


function thread_init()
  local t = sysbench.sql.type
  local hint = ""
  local key = "id"

  if( string.len(sysbench.opt.mysql_query_hint) > 0 ) then
    hint= "/*+ " .. sysbench.opt.mysql_query_hint .. " */ "
    if( sysbench.tid == 0 ) then
      print( "=> Using Query HINT : " .. hint )
    end
  end

  if( sysbench.opt.by_secidx ) then
    key = "k"
  end

  POINT_SELECT_QUERY = string.format( "SELECT %s%s FROM %s%%u WHERE %s = %%d ",
    hint, sysbench.opt.select_cols, sysbench.opt.table_name, key )

  -- >>: SQL queries..
  stmt_defs = {
    point_selects = {
      string.format( "SELECT %s%s FROM %s%%u WHERE %s = ?",
      hint, sysbench.opt.select_cols, sysbench.opt.table_name, key ),
      t.INT},

    simple_ranges = {
      string.format( "SELECT %s%s FROM %s%%u WHERE %s BETWEEN ? AND ?",
      hint, sysbench.opt.select_cols, sysbench.opt.table_name, key ),
      t.INT, t.INT},

    sum_ranges = {
      string.format( "SELECT %s SUM(k) FROM %s%%u WHERE %s BETWEEN ? AND ?",
      hint, sysbench.opt.table_name, key ),
      t.INT, t.INT},

    order_ranges = {
      string.format( "SELECT %s%s FROM %s%%u WHERE %s BETWEEN ? AND ? ORDER BY c",
      hint, sysbench.opt.select_cols, sysbench.opt.table_name, key ),
      t.INT, t.INT},

    distinct_ranges = {
      string.format( "SELECT %s DISTINCT c FROM %s%%u WHERE %s BETWEEN ? AND ? ORDER BY c",
      hint, sysbench.opt.table_name, key ),
      t.INT, t.INT},

    index_updates = {
      string.format( "UPDATE %s%s%%u SET k=k+1 WHERE id = ?",
      hint, sysbench.opt.table_name ),
      t.INT},

    non_index_updates = {
      string.format( "UPDATE %s%s%%u SET c=? WHERE %s = ?",
      hint, sysbench.opt.table_name, key ),
      {t.CHAR, 120}, t.INT},

    index_updates_range = {
      string.format( "UPDATE %s%s%%u SET k=k+1 WHERE id BETWEEN ? AND ?",
      hint, sysbench.opt.table_name ),
      t.INT, t.INT},

    non_index_updates_range = {
      string.format( "UPDATE %s%s%%u SET c=? WHERE %s BETWEEN ? AND ?",
      hint, sysbench.opt.table_name, key ),
      {t.CHAR, 120}, t.INT, t.INT},

    deletes = {
      string.format( "DELETE %s FROM %s%%u WHERE id = ?",
      hint, sysbench.opt.table_name ),
      t.INT},

    inserts = {
      string.format( "INSERT %s INTO %s%%u (id, k, c, pad) VALUES (?, ?, ?, ?)",
      hint, sysbench.opt.table_name ),
      t.INT, t.INT, {t.CHAR, 120}, {t.CHAR, 60}},
  }

  drv = sysbench.sql.driver()
  con = drv:connect()

  -- Create global nested tables for prepared statements and their
  -- parameters. We need a statement and a parameter set for each combination
  -- of connection/table/query
  stmt = {}
  param = {}

  -- >>: (dim) list of IDs to replay in case of error
  list_id = {}

  rand_loop = 0
  rand_count = 0

  -- >>: mysql session options..
  mysql_session_opt( con )

  for t = 1, sysbench.opt.tables do
    stmt[t] = {}
    param[t] = {}
  end

  setup_templates()

  -- This function is a 'callback' defined by individual benchmark scripts
  prepare_statements()

  if( sysbench.tid == 0 ) then
    print( "=> rand-type: " .. sysbench.opt.rand_type )
    print( "=> rand-loop: " .. sysbench.opt.rand_loop )
    print( "=> where-id-key: " .. key )
    print( "=> select-cols: " .. sysbench.opt.select_cols )
    print( "=> session-ops: " .. sysbench.opt.mysql_session_options )
    print( "=> sleep-after-query: " .. sysbench.opt.sleep_after_query )
    print( "=> sleep-before-commit: " .. sysbench.opt.sleep_before_commit )
    print( "=> extra-query-before-event: " .. sysbench.opt.extra_query_before )
    print( "=> extra-query-after-event: " .. sysbench.opt.extra_query_after )

    -- >>: debug-opt..
    check_opt_debug()
  end

  -- >>: SYNC_file
  if( string.len( sysbench.opt.sync_file ) > 0 )  then
    require( "SYNC_file" )
    SYNC_wait( sysbench.opt.sync_file, sysbench.opt.sync_wait )
  end
end


function thread_done()
   -- Close prepared statements
  for t = 1, sysbench.opt.tables do
    for k, s in pairs(stmt[t]) do
      stmt[t][k]:close()
    end
  end

  if (stmt.begin ~= nil) then
    stmt.begin:close()
  end

  if (stmt.commit ~= nil) then
    stmt.commit:close()
  end

  con:disconnect()
end


function cleanup()
  local drv = sysbench.sql.driver()
  local con = drv:connect()

  for i = 1, sysbench.opt.tables do
    print(string.format("Dropping table '%s%d'...", sysbench.opt.table_name, i ))
    con:query("DROP TABLE IF EXISTS " .. sysbench.opt.table_name .. i )
  end
end


-- hack: (dim) split threads per tables..
function get_table_num()
  if sysbench.opt.threads >= sysbench.opt.tables then
    return sysbench.tid % sysbench.opt.tables + 1
  end

  return sysbench.rand.uniform(1, sysbench.opt.tables)
end


function get_id_orig()
  return sysbench.rand.default( 1, sysbench.opt.table_size )
end


-- hack: (dim) rand_loop
function get_id_dim()

  -- note: id by default
  if( sysbench.opt.rand_loop == 0 ) then
    return sysbench.rand.default( 1, sysbench.opt.table_size )
  end

  -- note: id by loop
  if( sysbench.opt.rand_loop == 3 ) then
    if( rand_loop == 0 or rand_count > 1000000 ) then
      rand_loop = sysbench.rand.default( 1, sysbench.opt.table_size )
      rand_count = 0
    end

    rand_loop = rand_loop + 77777
    rand_count = rand_count + 1

    return rand_loop % sysbench.opt.table_size + 1
  end

  -- note: id by shift
  if( sysbench.opt.rand_loop == 2 ) then
    local shift = sysbench.opt.table_size / sysbench.opt.threads
    local id = sysbench.rand.default( 1, sysbench.opt.table_size )

    return id - id % shift + sysbench.tid + 1
  end

  -- note: id by chunks
  if( sysbench.opt.rand_loop == 1 ) then
    local range = sysbench.opt.table_size / sysbench.opt.threads

    if( sysbench.opt.threads < sysbench.opt.tables ) then
      return sysbench.rand.default( 1 + sysbench.tid * range, range + sysbench.tid * range )
    end

    local nb = sysbench.opt.threads / sysbench.opt.tables
    range = sysbench.opt.table_size / nb
    local chunk_no = math.floor( sysbench.tid / sysbench.opt.tables )

    return sysbench.rand.default( 1 + range * chunk_no , range + range * chunk_no )
  end

  error( "## rand_loop must be in [0-3] interval.." )
end


-- hack: (dim) allow retry..
function get_id()
  local id

  if( not sysbench.opt.trx_retry ) then
    return get_id_dim()
  end

  if #list_id < list_id_no then
    list_id[ list_id_no ] = get_id_dim()
  end

  id = list_id[ list_id_no ]
  list_id_no = list_id_no + 1
  return id
end


function start_id()
  list_id_no = 1
end


function reset_id()
  list_id = {}
end


function begin()
  start_id()
  stmt.begin:execute()
end


function commit()
  check_sleep_before_commit()
  stmt.commit:execute()
  reset_id()
end


-- >>: reconnect
function prepare_point_selects_reconnect()
end


function check_extra_query_before()
  if( string.len( sysbench.opt.extra_query_before ) > 0 )  then
    con:query( sysbench.opt.extra_query_before )
  end
end


function check_extra_query_after()
  if( string.len( sysbench.opt.extra_query_after ) > 0 )  then
    con:query( sysbench.opt.extra_query_after )
  end
end


function check_sleep_before_commit()
  if( sysbench.opt.sleep_before_commit > 0 ) then
    usleep( sysbench.opt.sleep_before_commit )
  end
end


function check_sleep_after_query()
  if( sysbench.opt.sleep_after_query > 0 ) then
    usleep( sysbench.opt.sleep_after_query )
  end
end


function execute_point_selects_reconnect( trx )
  local tnum = get_table_num()
  local i

  con:disconnect()
  con = drv:connect()

  if( trx )  then con:query( "BEGIN" ) end

  for i = 1, sysbench.opt.point_selects do
    con:query( string.format( POINT_SELECT_QUERY, tnum, get_id() ))
    check_sleep_after_query()
  end

  if( trx )  then con:query( "COMMIT" ) end
end


function execute_point_selects()
  local tnum = get_table_num()
  local i

  for i = 1, sysbench.opt.point_selects do
    param[tnum].point_selects[1]:set(get_id())
    stmt[tnum].point_selects:execute()
    check_sleep_after_query()
  end
end


function execute_range( key )
  local tnum = get_table_num()

  for i = 1, sysbench.opt[key] do
    local id = get_id()

    param[tnum][key][1]:set(id)
    param[tnum][key][2]:set(id + sysbench.opt.range_size - 1)

    stmt[tnum][key]:execute()
    check_sleep_after_query()
  end
end


function execute_simple_ranges()
  execute_range( "simple_ranges" )
end


function execute_sum_ranges()
  execute_range( "sum_ranges" )
end


function execute_order_ranges()
  execute_range( "order_ranges" )
end


function execute_distinct_ranges()
  execute_range( "distinct_ranges" )
end


function execute_index_updates()
  local tnum = get_table_num()

  if( sysbench.opt.update_range_size > 0 ) then
    local id = get_id()

    for i = 1, sysbench.opt.index_updates do
      param[tnum].index_updates_range[1]:set(id)
      param[tnum].index_updates_range[2]:set(id + sysbench.opt.update_range_size - 1)
      stmt[tnum].index_updates_range:execute()
      check_sleep_after_query()
    end
  else
    for i = 1, sysbench.opt.index_updates do
      param[tnum].index_updates[1]:set(get_id())
      stmt[tnum].index_updates:execute()
      check_sleep_after_query()
    end
  end
end


function execute_non_index_updates()
  local tnum = get_table_num()

  if( sysbench.opt.update_range_size > 0 ) then
    local id = get_id()

    for i = 1, sysbench.opt.non_index_updates do
      param[tnum].non_index_updates_range[1]:set_rand_str(c_value_template)
      param[tnum].non_index_updates_range[2]:set(id)
      param[tnum].non_index_updates_range[3]:set(id + sysbench.opt.update_range_size - 1)
      stmt[tnum].non_index_updates_range:execute()
      check_sleep_after_query()
    end
  else
    for i = 1, sysbench.opt.non_index_updates do
      param[tnum].non_index_updates[1]:set_rand_str(c_value_template)
      param[tnum].non_index_updates[2]:set(get_id())
      stmt[tnum].non_index_updates:execute()
      check_sleep_after_query()
    end
  end
end


function execute_delete_inserts()
  local tnum = get_table_num()

  for i = 1, sysbench.opt.delete_inserts do
    local id = get_id()
    local k = get_id()

    param[tnum].deletes[1]:set(id)

    param[tnum].inserts[1]:set(id)
    param[tnum].inserts[2]:set(k)
    param[tnum].inserts[3]:set_rand_str(c_value_template)
    param[tnum].inserts[4]:set_rand_str(pad_value_template)

    stmt[tnum].deletes:execute()
    check_sleep_after_query()
    stmt[tnum].inserts:execute()
    check_sleep_after_query()
  end
end


function execute_inserts_only()
  local tnum = get_table_num()

  for i = 1, sysbench.opt.inserts_only do
    local id = 0
    local k = get_id()

    param[tnum].inserts[1]:set(id)
    param[tnum].inserts[2]:set(k)
    param[tnum].inserts[3]:set_rand_str(c_value_template)
    param[tnum].inserts[4]:set_rand_str(pad_value_template)

    stmt[tnum].inserts:execute()
    check_sleep_after_query()
  end
end
