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


-- hack: (dim) split threads per tables..
function get_table_num()
  if( sysbench.opt.threads >= sysbench.opt.tables ) then
    return sysbench.tid % sysbench.opt.tables + 1
  end

  return sysbench.rand.uniform( 1, sysbench.opt.tables )
end


function get_w_id_minmax()
  local min, max, step

  if( sysbench.opt.threads >= sysbench.opt.scale * sysbench.opt.tables ) then
    min = 1 + (sybench.tid - sysbench.tid % sysbench.opt.tables ) % sysbench.opt.scale
    max = min
  else
    step = math.floor( sysbench.opt.scale / sysbench.opt.threads ) * sysbench.opt.tables
    min = 1 + (sysbench.tid * step) % sysbench.opt.scale
    max = min + step

    if( max > sysbench.opt.scale ) then
      max = sysbench.opt.scale
    end
  end

  return min, max
end


function get_w_id()
  local min, max, w_id

  -- min, max = get_w_id_minmax()
  -- w_id = sysbench.rand.uniform( min, max )

  w_id = sysbench.rand.default( 1, sysbench.opt.scale )
  return w_id
end

--
-- produce the id of a valid warehouse other than home_ware
-- (assuming there is one)
--
function other_ware( home_ware )
  local tmp, min, max

  if( sysbench.opt.scale == 1 ) then
    return home_ware
  end

  -- min, max = get_w_id_minmax()
  --
  -- if( min < max ) then
  --   return (min + (home_ware + 1) % (max-min))
  -- end

  repeat
    tmp = sysbench.rand.uniform( 1, sysbench.opt.scale )
  until tmp == home_ware

  return tmp
end


function customer_by_name( table_num, w_id, d_id, c_last )
  local c_id, i

  -- "SELECT c_id\n" \
  -- "FROM customer\n" \
  -- "WHERE c_w_id = %d\n" \
  -- "  AND c_d_id = %d\n" \
  -- "  AND c_last = '%s'\n" \
  -- "ORDER BY c_first ASC\n" \
  --       "LIMIT 1"

  rs = con:query( string.format( [[
    SELECT c_id FROM customer%d
      WHERE c_w_id = %d
      AND c_d_id = %d
      AND c_last = '%s'
      ORDER BY c_first ASC
    ]], table_num, w_id, d_id, c_last
  ))

  if( rs.nrows == 0 ) then
    return NURand( 1023, 1, CUST_PER_DIST )
  end

  for i = 1, rs.nrows
  do
    row = rs:fetch_row()
    c_id = row[1]

    -- hack: (dim) if more than one customer, TPCC requires to use the middle one from the result..
    if( rs.nrows > 1 and i >= math.floor( rs.nrows / 2 )) then break end
  end

  return c_id
end


function ExecQuery( Query )
  rs = con:query( Query )

  if( rs.nrows == 0 ) then
    print( "-----------------------------------------------------")
    print( " ** EMPTY QUERY :\n" )
    print( Query )
    print( "-----------------------------------------------------")
    sleep( 1 )
  end
end


function new_order()
  -- prep work
  local table_num = get_table_num()
  local w_id = get_w_id()
  local other_w_id = other_ware( w_id )
  local d_id = sysbench.rand.uniform( 1, DIST_PER_WARE )
  local c_id = NURand( 1023, 1, CUST_PER_DIST )

  local ol_cnt = sysbench.rand.uniform( 5, 15 );
  local rbk = sysbench.rand.uniform( 1, 100 );
  local itemid = {}
  local supware = {}
  local qty = {}
  -- hack: (dim) TPCC requires 10% orders from diff Warehouse..
  local all_local = 0
  local i

  for i = 1, ol_cnt
  do
    itemid[i] = NURand( 8191, 1, MAXITEMS )

    -- if( (i == ol_cnt - 1) and (rbk == 1) ) then
    --   itemid[i] = -1
    -- end

    if( i < ol_cnt * 0.9 ) then
      supware[i] = w_id
    else
      supware[i] = other_w_id
    end

    qty[i] = sysbench.rand.uniform( 1, 10 )
  end

  con:query( "BEGIN" )

  -- "SELECT w_tax\n" \
  -- "FROM warehouse\n" \
  -- "WHERE w_id = %d"

  ExecQuery( string.format( [[
    SELECT w_tax FROM warehouse%d WHERE w_id = %d
    ]], table_num, w_id
  ))

  local w_tax

  for i = 1, rs.nrows
  do
    row = rs:fetch_row()
    w_tax = row[1]
  end

  -- SELECT d_next_o_id, d_tax INTO :d_next_o_id, :d_tax
  --   FROM district
  --   WHERE d_id = :d_id
  --   AND d_w_id = :w_id
  --   FOR UPDATE

  ExecQuery( string.format( [[
    SELECT d_next_o_id, d_tax FROM district%d
      WHERE d_w_id = %d AND d_id = %d %s
    ]], table_num, w_id, d_id, FOR_UPDATE1
  ))

  local d_next_o_id
  local d_tax

  for i = 1, rs.nrows
  do
    row = rs:fetch_row()
    d_next_o_id = row[1]
    d_tax = row[2]
  end

  -- UPDATE district SET d_next_o_id = :d_next_o_id + 1
  --                WHERE d_id = :d_id
  --                AND d_w_id = :w_id;

  con:query(
    "UPDATE district" .. table_num ..
    " SET d_next_o_id = " .. (d_next_o_id + 1) ..
    " WHERE d_id = " .. d_id .. " AND d_w_id = " .. w_id
  )

  --  SELECT c_discount, c_last, c_credit
  --  INTO :c_discount, :c_last, :c_credit
  --  FROM customer
  --  WHERE c_w_id = :w_id
  --  AND c_d_id = :d_id
  --  AND c_id = :c_id;

  ExecQuery(
    "SELECT c_discount, c_last, c_credit " ..
    "FROM customer" .. table_num ..
    " WHERE c_w_id = " .. w_id ..
    " AND c_d_id = " .. d_id ..
    " AND c_id = " .. c_id
  )

  local c_discount
  local c_last
  local c_credit

  for i = 1, rs.nrows
  do
    row = rs:fetch_row()
    c_discount = row[1]
    c_last = row[2]
    c_credit = row[3]
  end

  -- INSERT INTO orders (o_id, o_d_id, o_w_id, o_c_id,
  --                                    o_entry_d, o_ol_cnt, o_all_local)
  --                VALUES(:o_id, :d_id, :w_id, :c_id,
  --                       :datetime,
  --                       :o_ol_cnt, :o_all_local);

  -- hack: (dim) null_value
  con:query( string.format( [[
    INSERT INTO orders%d (o_id, o_d_id, o_w_id, o_c_id, o_entry_d, o_carrier_id, o_ol_cnt, o_all_local)
      VALUES (%d,%d,%d,%d,NOW(),%s,%d,%d)
    ]], table_num, d_next_o_id, d_id, w_id, c_id, null_value, ol_cnt, all_local
  ))

  -- INSERT INTO new_orders (no_o_id, no_d_id, no_w_id)
  --    VALUES (:o_id,:d_id,:w_id); */

  con:query( string.format( [[
    INSERT INTO new_orders%d ( no_o_id, no_d_id, no_w_id )
      VALUES (%d,%d,%d)
    ]], table_num, d_next_o_id, d_id, w_id
  ))

  for ol_number = 1, ol_cnt
  do
    local ol_supply_w_id = supware[ol_number]
    local ol_i_id = itemid[ol_number]
    local ol_quantity = qty[ol_number]

    -- SELECT i_price, i_name, i_data
    --  INTO :i_price, :i_name, :i_data
    --  FROM item
    --  WHERE i_id = :ol_i_id;*/

    ExecQuery(
      "SELECT i_price, i_name, i_data FROM item" .. table_num ..
      " WHERE i_id = " .. ol_i_id
    )

    local i_price
    local i_name
    local i_data

    if( rs.nrows == 0 ) then
      ffi.C.sb_counter_inc( sysbench.tid, ffi.C.SB_CNT_ERROR )
      con:query( "ROLLBACK" )
      return
    end

    for i = 1, rs.nrows do
      row = rs:fetch_row()
      i_price = row[1]
      i_name = row[2]
      i_data = row[3]
    end

    -- SELECT s_quantity, s_data, s_dist_01, s_dist_02,
    --    s_dist_03, s_dist_04, s_dist_05, s_dist_06,
    --    s_dist_07, s_dist_08, s_dist_09, s_dist_10
    --  INTO :s_quantity, :s_data, :s_dist_01, :s_dist_02,
    --       :s_dist_03, :s_dist_04, :s_dist_05, :s_dist_06,
    --       :s_dist_07, :s_dist_08, :s_dist_09, :s_dist_10
    --  FROM stock
    --  WHERE s_i_id = :ol_i_id
    --  AND s_w_id = :ol_supply_w_id
    --  FOR UPDATE;*/

    ExecQuery(
      "SELECT s_quantity, s_data, s_dist_" .. string.format( "%02d", d_id ) ..
      " s_dist FROM stock" .. table_num ..
      " WHERE s_i_id = " .. ol_i_id .. " AND s_w_id = " .. ol_supply_w_id ..
      FOR_UPDATE1
    )

    local s_quantity
    local s_data
    local ol_dist_info

    for i = 1, rs.nrows do
      row = rs:fetch_row()
      s_quantity = tonumber(row[1])
      s_data = row[2]
      ol_dist_info = row[3]
    end

    if( s_quantity > ol_quantity ) then
      s_quantity = s_quantity - ol_quantity
    else
      s_quantity = s_quantity - ol_quantity + 91
    end

    -- UPDATE stock SET s_quantity = :s_quantity
    --  WHERE s_i_id = :ol_i_id
    --  AND s_w_id = :ol_supply_w_id;*/

    con:query(
      "UPDATE stock" .. table_num ..
      " SET s_quantity = " .. s_quantity ..
      " WHERE s_i_id = " .. ol_i_id .. " AND s_w_id=" .. ol_supply_w_id
    )

    ol_amount = ol_quantity * i_price * (1 + w_tax + d_tax) * (1 - c_discount);

    -- INSERT INTO order_line (ol_o_id, ol_d_id, ol_w_id,
    --         ol_number, ol_i_id,
    --         ol_supply_w_id, ol_quantity,
    --         ol_amount, ol_dist_info)
    --  VALUES (:o_id, :d_id, :w_id, :ol_number, :ol_i_id,
    --    :ol_supply_w_id, :ol_quantity, :ol_amount,
    --    :ol_dist_info);

    -- hack: (dim) null_value
    con:query( string.format( [[
      INSERT INTO order_line%d
        (ol_o_id, ol_d_id, ol_w_id, ol_number, ol_i_id, ol_supply_w_id, ol_delivery_d, ol_quantity, ol_amount, ol_dist_info)
        VALUES (%d,%d,%d,%d,%d,%d, %s, %d,%d,'%s')
      ]], table_num, d_next_o_id, d_id, w_id, ol_number, ol_i_id, ol_supply_w_id, null_value,
          ol_quantity, ol_amount, ol_dist_info
    ))
  end

  con:query( "COMMIT" )
end


function payment()
  -- prep work
  local table_num = get_table_num()
  local w_id = get_w_id()
  local d_id = sysbench.rand.uniform( 1, DIST_PER_WARE )
  local c_id = NURand( 1023, 1, CUST_PER_DIST )
  local h_amount = sysbench.rand.uniform( 1, 5000 )
  local c_last = Lastname( NURand( 255, 0, 999 ))
  local c_w_id = w_id
  local c_d_id = d_id
  local i

  con:query( "BEGIN" )

  -- SELECT w_street_1, w_street_2, w_city, w_state, w_zip, w_name
  --    INTO :w_street_1, :w_street_2, :w_city, :w_state, :w_zip, :w_name
  --    FROM warehouse
  --    WHERE w_id = :w_id;*/

  ExecQuery(
    "SELECT w_street_1, w_street_2, w_city, w_state, w_zip, w_name" ..
    " FROM warehouse" .. table_num ..
    " WHERE w_id = " .. w_id .. FOR_UPDATE1
  )

  local w_street_1, w_street_2, w_city, w_state, w_zip, w_name

  for i = 1, rs.nrows
  do
    row = rs:fetch_row()
    w_street_1, w_street_2, w_city, w_state, w_zip, w_name = row[1], row[2], row[3], row[4], row[5], row[6]
  end

  --  UPDATE warehouse SET w_ytd = w_ytd + :h_amount
  --  WHERE w_id =:w_id

  con:query(
    "UPDATE warehouse" .. table_num ..
    " SET w_ytd = w_ytd + " .. h_amount ..
    " WHERE w_id = " .. w_id
  )

  ExecQuery(
    "SELECT d_street_1, d_street_2, d_city, d_state, d_zip, d_name" ..
    " FROM district" .. table_num ..
    " WHERE d_w_id = " .. w_id .. " AND d_id = " .. d_id ..
    FOR_UPDATE1
  )

  local d_street_1, d_street_2, d_city, d_state, d_zip, d_name

  for i = 1, rs.nrows
  do
    row = rs:fetch_row()
    d_street_1, d_street_2, d_city, d_state, d_zip, d_name = row[1], row[2], row[3], row[4], row[5], row[6]
  end

  -- UPDATE district SET d_ytd = d_ytd + :h_amount
  --    WHERE d_w_id = :w_id
  --    AND d_id = :d_id;*/

  con:query(
    "UPDATE district" .. table_num ..
    " SET d_ytd = d_ytd + " .. h_amount ..
    " WHERE d_w_id = " .. w_id .. " AND d_id = " .. d_id
  )

  if( sysbench.rand.uniform( 1, 100 ) <= 60 )
  then
    c_id = customer_by_name( table_num, w_id, d_id, c_last )
  end

  -- SELECT c_first, c_middle, c_last, c_street_1,
  --    c_street_2, c_city, c_state, c_zip, c_phone,
  --    c_credit, c_credit_lim, c_discount, c_balance,
  --    c_since
  --  FROM customer
  --  WHERE c_w_id = :c_w_id
  --  AND c_d_id = :c_d_id
  --  AND c_id = :c_id
  --  FOR UPDATE;

  ExecQuery( string.format( [[
    SELECT c_first, c_middle, c_last, c_street_1,
      c_street_2, c_city, c_state, c_zip, c_phone,
      c_credit, c_credit_lim, c_discount, c_balance, c_ytd_payment, c_since
      FROM customer%d
      WHERE c_w_id = %d
      AND c_d_id = %d
      AND c_id = %d
      %s
    ]], table_num, w_id, c_d_id, c_id, FOR_UPDATE1
  ))

  local c_first, c_middle, c_last, c_street_1, c_street_2, c_city, c_state, c_zip, c_phone, c_credit, c_credit_lim, c_discount, c_balance, c_ytd_payment, c_since

  for i = 1, rs.nrows
  do
    row = rs:fetch_row()
    c_first =       row[1]
    c_middle =      row[2]
    c_last =        row[3]
    c_street_1 =    row[4]
    c_street_2 =    row[5]
    c_city =        row[6]
    c_state =       row[7]
    c_zip =         row[8]
    c_phone =       row[9]
    c_credit =      row[10]
    c_credit_lim =  row[11]
    c_discount =    row[12]
    c_balance =     row[13]
    c_ytd_payment = row[14]
    c_since =       row[15]
  end

  c_balance = tonumber(c_balance) - h_amount
  c_ytd_payment = tonumber(c_ytd_payment) + h_amount

  if( c_credit == "BC" )
  then
    -- SELECT c_data
    --  INTO :c_data
    --  FROM customer
    --  WHERE c_w_id = :c_w_id
    --  AND c_d_id = :c_d_id
    --  AND c_id = :c_id; */

    ExecQuery(
      "SELECT c_data FROM customer" .. table_num ..
      " WHERE c_w_id = " .. w_id .. " AND c_d_id = " .. c_d_id ..
      " AND c_id = " .. c_id
    )

    local c_data

    for i = 1, rs.nrows
    do
      row = rs:fetch_row()
      c_data = row[1]
    end

    local c_new_data = string.sub( string.format( "| %4d %2d %4d %2d %4d $%7.2f %12s %24s",
                c_id, c_d_id, c_w_id, d_id, w_id, h_amount, os.time(), c_data ), 1, 500 );

    --    UPDATE customer
    --      SET c_balance = :c_balance, c_data = :c_new_data
    --      WHERE c_w_id = :c_w_id
    --      AND c_d_id = :c_d_id
    --      AND c_id = :c_id

    con:query(
      "UPDATE customer" .. table_num ..
      " SET c_balance = " .. c_balance .. ", c_ytd_payment = " .. c_ytd_payment ..
      ", c_data = '" .. c_new_data .. "'" ..
      " WHERE c_w_id = " .. w_id .. " AND c_d_id = " .. c_d_id ..
      " AND c_id = " .. c_id
    )
  else
    con:query(
      "UPDATE customer" .. table_num ..
      " SET c_balance = " ..c_balance .. ", c_ytd_payment = " .. c_ytd_payment ..
      " WHERE c_w_id = " .. w_id .. " AND c_d_id = " .. c_d_id ..
      " AND c_id = " .. c_id
    )
  end

  --  INSERT INTO history(h_c_d_id, h_c_w_id, h_c_id, h_d_id,
  --                         h_w_id, h_date, h_amount, h_data)
  --                  VALUES(:c_d_id, :c_w_id, :c_id, :d_id,
  --                   :w_id,
  --             :datetime,
  --             :h_amount, :h_data);*/

  con:query(
    "INSERT INTO history" .. table_num ..
    "(h_c_d_id, h_c_w_id, h_c_id, h_d_id, h_w_id, h_date, h_amount, h_data) " ..
    string.format( "VALUES (%d,%d,%d,%d,%d,NOW(),%d,'%s')",
      c_d_id, c_w_id, c_id, d_id, w_id, h_amount,
      string.format("%10s %10s   ", w_name, d_name)
    )
  )

  con:query( "COMMIT" )
end


function orderstatus()
  --prep
  local table_num = get_table_num()
  local w_id = get_w_id()
  local d_id = sysbench.rand.uniform( 1, DIST_PER_WARE )
  local c_id = NURand( 1023, 1, CUST_PER_DIST )
  local c_last = Lastname( NURand( 255, 0, 999 ) )

  local c_balance
  local c_first
  local c_middle
  local i

  con:query( "BEGIN" )

  if( sysbench.rand.uniform( 1, 100 ) <= 60 )
  then
    c_id = customer_by_name( table_num, w_id, d_id, c_last )
  end

  --    SELECT c_balance, c_first, c_middle, c_last
  --            FROM customer
  --            WHERE c_w_id = :c_w_id
  --      AND c_d_id = :c_d_id
  --      AND c_id = :c_id;*/

  ExecQuery( string.format( [[
    SELECT c_balance, c_first, c_middle, c_last
      FROM customer%d
      WHERE c_w_id = %d
      AND c_d_id = %d
      AND c_id = %d
    ]], table_num, w_id, d_id, c_id
  ))

  for i = 1, rs.nrows
  do
    row = rs:fetch_row()
    c_balance = row[1]
    c_first =   row[2]
    c_middle =  row[3]
    c_last =    row[4]
  end

  --[[ Query from tpcc standard
    EXEC SQL SELECT o_id, o_carrier_id, o_entry_d
    INTO :o_id, :o_carrier_id, :entdate
    FROM orders
    ORDER BY o_id DESC
  --]]

  con:query( string.format( [[
    SELECT o_id, o_carrier_id, o_entry_d
      FROM orders%d
      WHERE o_w_id = %d AND o_d_id = %d AND o_c_id = %d
      ORDER BY o_id DESC
    ]],
    table_num, w_id, d_id, c_id
  ))

  local o_id

  for i = 1, rs.nrows
  do
    row = rs:fetch_row()
    o_id = row[1]
  end

  --  SELECT ol_i_id, ol_supply_w_id, ol_quantity, ol_amount, ol_delivery_d
  --    FROM order_line
  --    WHERE ol_w_id = :c_w_id
  --    AND ol_d_id = :c_d_id
  --    AND ol_o_id = :o_id;*/

  ExecQuery( string.format( [[
    SELECT ol_i_id, ol_supply_w_id, ol_quantity, ol_amount, ol_delivery_d
      FROM order_line%d %s
      WHERE ol_w_id = %d
      AND ol_d_id = %d
      AND ol_o_id = %d
    ]], table_num, FORCE_PRIMARY, w_id, d_id, d_id, o_id
  ))

  for i = 1, rs.nrows
  do
    row = rs:fetch_row()
    local ol_i_id =        row[1]
    local ol_supply_w_id = row[2]
    local ol_quantity =    row[3]
    local ol_amount =      row[4]
    local ol_delivery_d =  row[5]
  end

  con:query( "COMMIT" )
end


function delivery()
  --prep
  local table_num = get_table_num()
  local w_id = get_w_id()
  local o_carrier_id = sysbench.rand.uniform( 1, 10 )
  local i

  con:query( "BEGIN" )

  for d_id = 1, DIST_PER_WARE
  do
    ExecQuery( string.format( [[
      SELECT no_o_id
        FROM new_orders%d
        WHERE no_d_id = %d
        AND no_w_id = %d
        ORDER BY no_o_id ASC LIMIT 1
      ]] .. FOR_UPDATE1, table_num, d_id, w_id
    ))

    local no_o_id

    for i = 1, rs.nrows
    do
      row = rs:fetch_row()
      no_o_id = row[1]
    end

    if( no_o_id ~= nil )
    then
      --  DELETE FROM new_orders WHERE no_o_id = :no_o_id AND no_d_id = :d_id
      --  AND no_w_id = :w_id;*/

      con:query( string.format( [[
        DELETE FROM new_orders%d
          WHERE no_o_id = %d AND no_d_id = %d  AND no_w_id = %d
        ]], table_num, no_o_id, d_id, w_id
      ))

      --  SELECT o_c_id INTO :c_id FROM orders
      --                    WHERE o_id = :no_o_id AND o_d_id = :d_id
      --        AND o_w_id = :w_id;*/

      ExecQuery( string.format( [[
        SELECT o_c_id
          FROM orders%d
          WHERE o_id = %d
          AND o_d_id = %d
          AND o_w_id = %d
        ]] .. FOR_UPDATE2, table_num, no_o_id, d_id, w_id
      ))

      local o_c_id

      for i = 1, rs.nrows do
        row = rs:fetch_row()
        o_c_id = row[1]
      end

      --   UPDATE orders SET o_carrier_id = :o_carrier_id
      --                    WHERE o_id = :no_o_id AND o_d_id = :d_id AND
      --        o_w_id = :w_id;*/

      con:query( string.format( [[
        UPDATE orders%d SET o_carrier_id = %d
          WHERE o_id = %d AND o_d_id = %d AND o_w_id = %d
        ]], table_num, o_carrier_id, no_o_id, d_id, w_id
      ))

      --   UPDATE order_line
      --                    SET ol_delivery_d = :datetime
      --                    WHERE ol_o_id = :no_o_id AND ol_d_id = :d_id AND
      --        ol_w_id = :w_id;*/

      con:query( string.format( [[
        UPDATE order_line%d %s
          SET ol_delivery_d = NOW()
          WHERE ol_o_id = %d AND ol_d_id = %d AND ol_w_id = %d
        ]], table_num, FORCE_PRIMARY, no_o_id, d_id, w_id
      ))

      --   SELECT SUM(ol_amount) INTO :ol_total
      --                    FROM order_line
      --                    WHERE ol_o_id = :no_o_id AND ol_d_id = :d_id
      --        AND ol_w_id = :w_id;*/

      ExecQuery( string.format( [[
        SELECT SUM(ol_amount) sm
          FROM order_line%d %s
          WHERE ol_o_id = %d AND ol_d_id = %d AND ol_w_id = %d
        ]], table_num, FORCE_PRIMARY, no_o_id, d_id, w_id
      ))

      local sm_ol_amount

      for i = 1, rs.nrows
      do
        row = rs:fetch_row()
        sm_ol_amount = row[1]
      end

      --  UPDATE customer SET c_balance = c_balance + :ol_total ,
      --                                 c_delivery_cnt = c_delivery_cnt + 1
      --                    WHERE c_id = :c_id AND c_d_id = :d_id AND
      --        c_w_id = :w_id;*/
      --        print(string.format("update customer table %d, cid %d, did %d, wid %d balance %f",table_num, o_c_id, d_id, w_id, sm_ol_amount))

      con:query( string.format( [[
        UPDATE customer%d SET c_balance = c_balance + %f, c_delivery_cnt = c_delivery_cnt + 1
          WHERE c_id = %d AND c_d_id = %d AND  c_w_id = %d
        ]], table_num, sm_ol_amount, o_c_id, d_id, w_id
      ))
    end
  end

  con:query( "COMMIT" )
end


function stocklevel()
  --prep
  local table_num = get_table_num()
  local w_id = get_w_id()
  local d_id = sysbench.rand.uniform( 1, DIST_PER_WARE )
  local level = sysbench.rand.uniform( 10, 20 )
  local i

  con:query( "BEGIN" )

  --  /*EXEC_SQL SELECT d_next_o_id
  --    FROM district
  --    WHERE d_id = :d_id
  --      AND d_w_id = :w_id;*/

  ExecQuery(
    "SELECT d_next_o_id FROM district" .. table_num ..
    " WHERE d_id = " .. d_id .. " AND d_w_id = " .. w_id
  )

  local d_next_o_id

  for i = 1, rs.nrows
  do
    row = rs:fetch_row()
    d_next_o_id = row[1]
  end

  -- "SELECT count(*)\n" \
  -- "FROM order_line, stock, district\n" \
  -- "WHERE d_id = %d\n" \
  -- "  AND d_w_id = %d\n" \
  -- "  AND d_id = ol_d_id\n" \
  -- "  AND d_w_id = ol_w_id\n" \
  -- "  AND ol_i_id = s_i_id\n" \
  -- "  AND ol_w_id = s_w_id\n" \
  -- "  AND s_quantity < %d\n" \
  -- "  AND ol_o_id BETWEEN (%d)\n" \
  -- "      AND (%d)"

  ExecQuery( string.format( [[
    SELECT count(*)
      FROM order_line%d, stock%d, district%d
      WHERE d_id = %d
      AND d_w_id = %d
      AND d_id = ol_d_id
      AND d_w_id = ol_w_id
      AND ol_i_id = s_i_id
      AND ol_w_id = s_w_id
      AND s_quantity < %d
      AND ol_o_id BETWEEN %d AND %d
    ]],
    table_num, table_num, table_num, d_id, w_id, level, (d_next_o_id - 20), d_next_o_id
  ))

  local cnt

  for i = 1, rs.nrows
  do
    row1 = rs:fetch_row()
    cnt = row1[1]
  end

  con:query( "COMMIT" )
end
