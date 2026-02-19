-- Copyright (C) 2023-2024 Oracle Corp.
-- remastered and adapted for BMK-kit by Dimitri KRAVTCHUK <dimitri.kravtchuk@oracle.com>
-- BMK-kit howto & download : http://dimitrik.free.fr/blog/posts/mysql-perf-bmk-kit.html

-- Copyright (C) 2020-2022 Dmitrii Maximenko <d.s.maximenko@gmail.com>

-- Use of this source code is governed by an MIT-style
-- license that can be found in the LICENSE file or at
-- https://opensource.org/licenses/MIT

-- ----------------------------------------------------------------------
-- Index insertion benchmark
-- ----------------------------------------------------------------------

-- >>: (dim) TODO :
-- ++ define only insert && delete threads (any others are selects)
-- ++ force index ??
-- ++ DELETE query where transactionid < tail
-- ++ build DOUBLE values via int.int string
-- ++ random and "original" price
-- ++ table_num depends on type + #threads (inserts/selects/deletes)
-- ++ option to execute only one SELECT type
-- ++ delete threads (independent to inserts)
-- ++ delete rate
-- ++ manage exec rate by measuring time inside event()
-- ++ tm_get() function based on libc gettimeofday()
-- print progress along initial data load ?? => once ported parallel load !!


require( "mysql_common" )


function init()
  assert( event ~= nil,
    "this script is meant to be included by other scripts and should not be called directly.")
end


if( sysbench.cmdline.command == nil ) then
  error( "Command is required. Supported commands: prepare, run, help" )
end


-- >>: Command line options
sysbench.cmdline.options = {

  -- Subject field parameters
  cashregisters =  {"# cash registers", 1000},
  products      =  {"# products", 10000},
  customers     =  {"# customers", 100000},
  max_price     =  {"Maximum value for price column", 500},
  random_price  =  {"Use full random price range instead of original", true},

  -- Query parameters
  insert_threads =
    {"# of threads for INSERTs, def:1", 1},
  rows_per_insert =
    {"Rows INSERTed per INSERT query, def:1000", 1000},
  insert_rate =
    {"Target QPS rate for each INSERTs thread, def:0", 0},
  select_query =
    {"Use only one SELECT query (1:market, 2:pdc, 3:register, 4:pk) def:0 means all", 0},
  rows_per_select =
    {"Limit of rows per SELECT query, def:10", 10},
  select_rate =
    {"Target QPS rate for each SELECT thread, def:0", 0},
  force_index =
    {"Force index use in select queries, def:true", true},
  delete_threads =
    {"# of threads for DELETEs, def: 0 means insert threads are doing DELETEs, def:0", 0},
  delete_rate =
    {"Target QPS rate for each DELETE thread, def:1", 1},
  batch_rate =
    {"Using batch rate approach instead of per-query, def:true", true},
  reconnect =
    {"Reconnect every N queries, def:0", 0},

  -- Table parameters
  tables =
    {"# of tables", 1},
  table_size =
    {"# of rows in table", 10000},
  table_size_max =
    {"Max # of rows for table. Once reached, delete older rows (def: 0 -- unlimited)", 0},
  data_size_max =
    {"Data column : max size of data", 10},
  data_size_min =
    {"Data column : min size of data", 10},
  data_random_pct =
    {"Data column : % of random data in row", 50},
  num_secondary_indexes =
    {"# of secondary indexes (0 to 3)", 3},
  num_partitions =
    {"Use range partitioning when not 0", 0},
  rows_per_partition =
    {"# of rows per partition", 0},
  fill_table =
    {"Load table_size rows in table", true},
  secondary_at_end =
    {"Create secondary index at end", false},

  -- Other options
  reconnect =
    {"Reconnect after every N events. The default (0) is to not reconnect", 0},
  mysql_storage_engine =
    {"Storage engine, if MySQL is used", "innodb"},
  create_table_options =
    {"Options passed to CREATE TABLE statement", ""},
  opt_debug =
    { "enable Sysbench options debug output on test starting.. (def:off)", false }

}


-- Prepare the dataset. This command supports parallel execution, i.e. will
-- benefit from executing with --threads > 1 as long as --tables > 1
function cmd_prepare()
  local drv = sysbench.sql.driver()
  local con = drv:connect()

  for i = sysbench.tid + 1, sysbench.opt.tables, sysbench.opt.threads do
    create_table( drv, con, i )
  end
end


-- Implement parallel prepare and warmup commands, define 'prewarm' as an alias
-- for 'warmup'
sysbench.cmdline.commands = {
  prepare = {cmd_prepare, sysbench.cmdline.PARALLEL_COMMAND},
}


function create_table( drv, con, table_num )
  local id_def
  local engine_def =  "/*! ENGINE = " .. sysbench.opt.mysql_storage_engine .. " */"
  local extra_table_options = ""
  local query, insert
  local partition_options = ""
  local rows_per_part = 0
  local i
  local n
  local range

  if( sysbench.opt.num_partitions > 0 ) then
    print( string.format( "==> Using %d partitions", sysbench.opt.num_partitions ))
    if( sysbench.opt.rows_per_partition > 0 ) then
      rows_per_part = sysbench.opt.rows_per_partition
    else
      error( "ERROR : if you want to use partitions, you need to provide rows # per partition..")
    end

    partition_options = "partition by range( transactionid ) ("

    for i = 1, sysbench.opt.num_partitions - 1 do
      partition_options = partition_options ..
        string.format( " partition p%d values less than (%d),\n", i, i * rows_per_part )
    end

    partition_options = partition_options ..
      string.format( " partition p%d values less than (MAXVALUE)\n)", sysbench.opt.num_partitions )
  end

  print(string.format( "Creating table 'sbtest%d'...", table_num ))

  query = string.format( [[
    CREATE TABLE sbtest%d(
    transactionid BIGINT NOT NULL AUTO_INCREMENT,
    dateandtime datetime NOT NULL,
    cashregisterid int NOT NULL,
    customerid int NOT NULL,
    productid int NOT NULL,
    price float NOT NULL,
    data varchar(%d) NOT NULL,
    primary key( transactionid )
    ) %s %s %s
    ]],
    table_num, sysbench.opt.data_size_max, engine_def, sysbench.opt.create_table_options, partition_options)

  con:query( query )

  if( not sysbench.opt.secondary_at_end ) then
    create_index( drv, con, table_num )
  end

  if( sysbench.opt.table_size > 0 and sysbench.opt.fill_table ) then
    print( string.format( "Inserting %d records into 'sbtest%d'",
      sysbench.opt.table_size, table_num))

    query = string.format( "INSERT INTO sbtest%d( dateandtime, cashregisterid, customerid, productid, price, data ) VALUES", table_num )

    range = sysbench.opt.table_size
    if( sysbench.opt.rows_per_insert > 0 )  then
      range = sysbench.opt.rows_per_insert
    end

    for i = 1, sysbench.opt.table_size, range do
      con:bulk_insert_init( query )

      for n = 1, range do
        insert = make_insert_query_string()
        con:bulk_insert_next( insert )
      end

      con:bulk_insert_done()
    end
  end

  if( sysbench.opt.secondary_at_end ) then
    create_index( drv, con, table_num )
  end
end


function create_index( drv, con, table_num )
  local index_ddl

  if( sysbench.opt.num_secondary_indexes > 0 ) then
    -- >>: original market index..
    --index_ddl = string.format( "alter table sbtest%d add index sbtest%d_marketsegment (price, customerid) ", table_num, table_num, table_num)

    -- >>: new market index..
    index_ddl = string.format( "alter table sbtest%d add index sbtest%d_marketsegment (productid, customerid, price) ", table_num, table_num, table_num)

    if( sysbench.opt.num_secondary_indexes > 1 ) then
      index_ddl = index_ddl .. string.format( ", add index sbtest%d_registersegment (cashregisterid, price, customerid) ", table_num, table_num)

      if( sysbench.opt.num_secondary_indexes > 2 ) then
        index_ddl = index_ddl .. string.format(", add index sbtest%d_pdc (price, dateandtime, customerid)", table_num, table_num)
       end
    end

    print( string.format( "Creating %d secondary indexes in 'sbtest%d' table..",
      sysbench.opt.num_secondary_indexes, table_num))

    con:query( index_ddl )
  end
end


function make_insert_query_string()
  return string.format( "('%s', %d, %d, %d, %.2f, '%s')", create_insert_data())
end


-- (dim) split threads per tables according thread_type
function get_table_num()
  local numb = sysbench.opt.threads - (sysbench.opt.delete_threads + sysbench.opt.insert_threads)

  if( thread_type == 1 ) then numb = sysbench.opt.insert_threads end
  if( thread_type == 2 ) then numb = sysbench.opt.delete_threads end

  if( numb >= sysbench.opt.tables ) then
    return( sysbench.tid % sysbench.opt.tables + 1 )
  end

  return( sysbench.rand.uniform( 1, sysbench.opt.tables ))
end


function get_product_id()
  return( sysbench.rand.uniform( 1, sysbench.opt.products ))
end


function get_customer_id()
  return( sysbench.rand.uniform( 1, sysbench.opt.customers ))
end


function get_cashregister_id()
  return( sysbench.rand.uniform( 1, sysbench.opt.cashregisters ))
end


function get_transaction_id( max_id )
  local size = sysbench.opt.table_size

  if( sysbench.opt.table_size_max > 0 ) then
    size = sysbench.opt.table_size_max
  end

  if( max_id < size ) then
    return( sysbench.rand.uniform( 1, max_id ))
  end

  return( max_id - sysbench.rand.uniform( 1, size ))
end


function get_transaction_id_max( tnum )
  local i, row, rs
  local max = 1

  rs = con:query( string.format( "SELECT max(transactionid) from sbtest%d", tnum ))

  if( rs.nrows > 0 ) then
    for i = 1, rs.nrows
    do
      row = rs:fetch_row()
      max = row[1]
    end
  end

  return( tonumber(max) )
end


function get_price( customerid )
  if( sysbench.opt.random_price ) then
    return(
      tonumber(
        sysbench.rand.uniform( 0, sysbench.opt.max_price) ..
        string.format( ".%02d", customerid % 100)
      )
    )
  end

  return( (sysbench.rand.uniform( 0, sysbench.opt.max_price) + customerid) / 100 )
end


function create_insert_data()
  local dateandtime      = os.date( '%Y-%m-%d %H:%M:%S' )
  local cashregisterid   = get_cashregister_id()
  local customerid       = get_customer_id()
  local productid        = sysbench.rand.uniform( 1, sysbench.opt.products )
  local price            = get_price( customerid )

  local data_size = sysbench.rand.uniform( sysbench.opt.data_size_min, sysbench.opt.data_size_max )
  local rand_data_size = math.floor( sysbench.opt.data_random_pct * data_size / 100 )

  if( data_size == rand_data_size ) then
    rand_data_size = rand_data_size - 1    -- because last letter is always a
  end

  local data = string.rep( 'a', data_size - rand_data_size - 1) ..
    sysbench.rand.varstring( rand_data_size, rand_data_size ) .. 'a'

  -- print( "=> INSERT: ", dateandtime, cashregisterid, customerid, productid, price, data )

  return dateandtime, cashregisterid, customerid, productid, price, data
end


-- >>: SQL queries..
local t = sysbench.sql.type
local stmt_defs = {

  -- >>: original market query..
  -- market_queries = {
  --   [[
  --     SELECT price, customerid FROM sbtest%u %s
  --       where (price >= ?) ORDER BY price, customerid LIMIT ?
  --   ]], t.INT, t.INT
  -- },

  -- >>: new market query..
  market_queries = {
    [[
      SELECT productid, customerid, price FROM sbtest%u %s
        where (productid >= ?) ORDER BY productid, customerid, price LIMIT ?
    ]], t.INT, t.INT
  },

  register_queries = {
    [[
      SELECT cashregisterid, price, customerid FROM sbtest%u %s
        where (cashregisterid > ?) ORDER BY cashregisterid, price, customerid LIMIT ?
    ]], t.INT, t.INT
  },

  pdc_queries = {
    [[
      SELECT price, dateandtime, customerid FROM sbtest%u %s
        where (price >= ?) ORDER BY price, dateandtime, customerid LIMIT ?
    ]], t.INT, t.INT
  },

  deletes = {
    [[
      DELETE FROM sbtest%u where transactionid < ?
    ]], t.INT
  }
}


function prepare_begin()
  stmt.begin = con:prepare( "BEGIN" )
end


function prepare_commit()
  stmt.commit = con:prepare( "COMMIT" )
end


function prepare_for_each_table( key, index )
  local t

  for t = 1, sysbench.opt.tables
  do
    if( key == "deletes" ) then
      stmt[t][key] = con:prepare(string.format(stmt_defs[key][1], t))
    elseif( sysbench.opt.force_index ) then
      stmt[t][key] = con:prepare(string.format(stmt_defs[key][1], t, string.format(index, t)))
    else
      stmt[t][key] = con:prepare(string.format(stmt_defs[key][1], t, ""))
    end

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


function prepare_deletes()
  prepare_for_each_table( "deletes" )
end


function prepare_market_queries()
  prepare_for_each_table( "market_queries", "FORCE INDEX (sbtest%u_marketsegment)" )
end


function prepare_pdc_queries()
  prepare_for_each_table( "pdc_queries", "FORCE INDEX (sbtest%u_pdc)" )
end


function prepare_register_queries()
  prepare_for_each_table( "register_queries", "FORCE INDEX (sbtest%u_registersegment)" )
end


function prepare_pk_queries()
  local pk = "pk_queries"
  local points = string.rep( "?, ", sysbench.opt.rows_per_select - 1) .. "?"

  for t = 1, sysbench.opt.tables  do
    stmt[t][pk] = con:prepare(string.format(
      "SELECT transactionid, productid, data FROM sbtest%d WHERE transactionid IN (%s)",
      t, points))

    param[t][pk] = {}

    for i = 1, sysbench.opt.rows_per_select do
      param[t][pk][i] = stmt[t][pk]:bind_create( sysbench.sql.type.INT )
    end

    stmt[t][pk]:bind_param( unpack( param[t][pk] ))
  end
end


function thread_init()
  if( sysbench.opt.delete_threads > 0 and sysbench.opt.table_size_max == 0 ) then
    error( "\n## ERROR : DELETE threads cannot be used without setting --table-size-max=N limit..\n" )
  end

  if( sysbench.opt.delete_threads > 0 and sysbench.opt.insert_threads > 0
    and sysbench.opt.insert_rate < sysbench.opt.delete_rate ) then
    error( "\n## ERROR : DELETE rate should not be higher than INSERT rate..\n" )
  end

  drv = sysbench.sql.driver()
  con = drv:connect()
  con:query( "SET autocommit=1" )

  -- Create global nested tables for prepared statements and their
  -- parameters. We need a statement and a parameter set for each combination
  -- of connection/table/query
  stmt = {}
  param = {}

  for t = 1, sysbench.opt.tables do
    stmt[t] = {}
    param[t] = {}
  end

  -- This function is a 'callback' defined by individual benchmark scripts
  prepare_statements()

  -- >>: Global thread stuff..
  -- 1 : insert_threads
  -- 2 : delete_threads
  -- 3 : select_threads
  thread_type = 0
  query_eta_usec = 0
  query_exec = 0
  query_batch_rate = 0

  if( sysbench.tid < sysbench.opt.insert_threads ) then
    -- inserts..
    thread_type = 1
    -- thread_event = execute_none
    thread_event = execute_inserts

    if( sysbench.opt.insert_rate > 0 ) then
      query_eta_usec = 1000000 / sysbench.opt.insert_rate
      query_batch_rate = sysbench.opt.insert_rate
      tm_sec_last, tm_usec_last = get_tm()
    end

  elseif( sysbench.tid < sysbench.opt.insert_threads + sysbench.opt.delete_threads ) then
    -- deletes..
    thread_type = 2
    thread_event = execute_deletes

    if( sysbench.opt.delete_rate > 0 ) then
      query_eta_usec = 1000000 / sysbench.opt.delete_rate
      query_batch_rate = sysbench.opt.delete_rate
      tm_sec_last, tm_usec_last = get_tm()
    end
  else
    -- selects..
    thread_type = 3
    thread_event = execute_selects

    thread_select = {}
    thread_select[1] = execute_market_queries
    thread_select[2] = execute_pdc_queries
    thread_select[3] = execute_register_queries
    thread_select[4] = execute_pk_queries
    thread_select_no = 0

    if( sysbench.opt.select_rate > 0 ) then
      query_eta_usec = 1000000 / sysbench.opt.select_rate
      query_batch_rate = sysbench.opt.select_rate
      tm_sec_last, tm_usec_last = get_tm()
    end
  end

  if( sysbench.tid == 0 ) then
    print( "=> table size max   : " .. sysbench.opt.table_size_max )
    print( "=> random price     : " .. tostring( sysbench.opt.random_price ))
    print( "=> use batch rate   : " .. tostring( sysbench.opt.batch_rate ))
    print( "=> insert threads   : " .. sysbench.opt.insert_threads )
    print( "=> rows per insert  : " .. sysbench.opt.rows_per_insert )
    print( "=> insert rate      : " .. sysbench.opt.insert_rate )
    print( "=> delete threads   : " .. sysbench.opt.delete_threads )
    print( "=> delete rate      : " .. sysbench.opt.delete_rate )
    print( "=> select threads   : " .. sysbench.opt.threads - (sysbench.opt.delete_threads + sysbench.opt.insert_threads ))
    print( "=> rows per select  : " .. sysbench.opt.rows_per_select )
    print( "=> select rate      : " .. sysbench.opt.select_rate )
    print( "=> select query     : " .. sysbench.opt.select_query )
    print( "=> force index      : " .. tostring( sysbench.opt.force_index ))
    print( "=> reconnect        : " .. sysbench.opt.reconnect )

    check_opt_debug()
  end
end


-- Close prepared statements
function close_statements()
  for t = 1, sysbench.opt.tables do
    for k, s in pairs(stmt[t]) do
      stmt[t][k]:close()
    end
  end

  if( stmt.commit ~= nil ) then stmt.commit:close() end
  if( stmt.begin  ~= nil ) then stmt.begin:close() end
end


function thread_done()
  close_statements()
  con:disconnect()
end


function cleanup()
  local drv = sysbench.sql.driver()
  local con = drv:connect()

  for i = 1, sysbench.opt.tables do
    print(string.format( "Dropping table 'sbtest%d'...", i))
    con:query( "DROP TABLE IF EXISTS sbtest" .. i )
  end
end


function begin()
  stmt.begin:execute()
end


function commit()
  stmt.commit:execute()
end


function execute_market_queries()
  local tnum = get_table_num()

  -- >>: old market..
  -- local customer_id = get_customer_id()
  -- local price = get_price( customer_id )
  --
  -- param[tnum].market_queries[1]:set( price )
  -- param[tnum].market_queries[2]:set( sysbench.opt.rows_per_select )

  -- >>: new market..
  local product_id = get_product_id()

  param[tnum].market_queries[1]:set( product_id )
  param[tnum].market_queries[2]:set( sysbench.opt.rows_per_select )

  stmt[tnum].market_queries:execute()
end


function execute_pdc_queries()
  local tnum = get_table_num()
  local customer_id = get_customer_id()
  local price = get_price( customer_id )

  param[tnum].pdc_queries[1]:set( price )
  param[tnum].pdc_queries[2]:set( sysbench.opt.rows_per_select )

  stmt[tnum].pdc_queries:execute()
end


function execute_register_queries()
  local tnum = get_table_num()
  param[tnum].register_queries[1]:set( get_cashregister_id() )
  param[tnum].register_queries[2]:set( sysbench.opt.rows_per_select )

  stmt[tnum].register_queries:execute()
end


function execute_pk_queries()
  local tnum = get_table_num()

  pk_exec = (pk_exec or 1000) + 1
  if( pk_exec > 1000 ) then
    pk_max_id = get_transaction_id_max( tnum )   -- >>: refresh global pk_max_id every 1K pk_exec
    pk_exec = 0
  end

  for i = 1, sysbench.opt.rows_per_select do
    param[tnum].pk_queries[i]:set( get_transaction_id( pk_max_id ) )
  end

  stmt[tnum].pk_queries:execute()
end


function check_eta_rate()
  if( sysbench.opt.batch_rate ) then
    if( query_batch_rate > 0 ) then
      -- >>: using batch rate ETA..
      query_exec = query_exec + 1

      if( query_exec >= query_batch_rate ) then
        tm_sec_curr, tm_usec_curr = get_tm()
        usleep( 1000000 - (tm_sec_curr - tm_sec_last) * 1000000 + tm_usec_curr - tm_usec_last )
        tm_sec_last, tm_usec_last = get_tm()
        query_exec = 0
      end
    end
  elseif( query_eta_usec > 0 ) then
    -- >>: this approach can be too expensive..
    -- query is expected to be executed once per query_eta_usec time interval
    -- so, we just need to usleep during (query_eta_usec - $(Time.Spent.Until.Now))
    tm_sec_curr, tm_usec_curr = get_tm()
    usleep( query_eta_usec - (tm_sec_curr - tm_sec_last) * 1000000 + tm_usec_curr - tm_usec_last )
    tm_sec_last, tm_usec_last = get_tm()
  end
end


function execute_none()
  check_eta_rate()
end


function execute_selects()
  if( sysbench.opt.select_query > 0 and sysbench.opt.select_query < 5 ) then
    thread_select[ sysbench.opt.select_query ]()
  else
    thread_select[ thread_select_no + 1 ]()
    thread_select_no = (thread_select_no + 1) % 4
  end

  check_eta_rate()
end


function execute_inserts()
  local tnum = get_table_num()
  local query = string.format( "INSERT INTO sbtest%d(dateandtime, cashregisterid, customerid, productid, price, data) VALUES", tnum )

  con:bulk_insert_init( query )

  for i = 1, sysbench.opt.rows_per_insert do
    query = make_insert_query_string()
    con:bulk_insert_next( query )
  end

  con:bulk_insert_done()

  if( sysbench.opt.table_size_max > 0 and sysbench.opt.delete_threads == 0 ) then
    execute_deletes( tnum )
  end

  check_eta_rate()
end


function execute_deletes( tnum )
  local i, max, row, rs

  if( tnum == nil ) then
    tnum = get_table_num()
  end

  max = get_transaction_id_max( tnum )

  param[tnum].deletes[1]:set( max - sysbench.opt.table_size_max )
  stmt[tnum].deletes:execute()

  -- delete rate is only considered for delete threads..
  if( sysbench.opt.delete_threads > 0 ) then
    check_eta_rate()
  end
end
