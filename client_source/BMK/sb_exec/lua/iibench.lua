-- Copyright (C) 2023-2024 Oracle Corp.
-- remastered and adapted for BMK-kit by Dimitri KRAVTCHUK <dimitri.kravtchuk@oracle.com>
-- BMK-kit howto : http://dimitrik.free.fr/blog/posts/mysql-perf-bmk-kit.html

-- Copyright (C) 2020-2022 Dmitrii Maximenko <d.s.maximenko@gmail.com>

-- Use of this source code is governed by an MIT-style
-- license that can be found in the LICENSE file or at
-- https://opensource.org/licenses/MIT

-- ----------------------------------------------------------------------
-- Index insertion benchmark
-- ----------------------------------------------------------------------


BMK_HOME = os.getenv( "BMK_HOME" )
if( BMK_HOME == nil ) then BMK_HOME= "/BMK" end
package.path = "?.lua;" .. BMK_HOME .. "/sb_exec/lua/?.lua;" .. package.path

require( "iibench_common" )


function prepare_statements()
  if( sysbench.opt.threads > sysbench.opt.insert_threads + sysbench.opt.delete_threads ) then
    prepare_market_queries()
    prepare_register_queries()
    prepare_pdc_queries()
    prepare_pk_queries()
  end

  if( sysbench.opt.table_size_max > 0 ) then
    prepare_deletes()
  end
end


function event()
  thread_event()     -- thread_event := function name for event()
  check_reconnect()
end
