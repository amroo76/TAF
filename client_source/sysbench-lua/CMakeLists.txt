cmake_minimum_required(VERSION 2.6)
if(COMMAND cmake_policy)
   cmake_policy(SET CMP0003 NEW)
endif(COMMAND cmake_policy)

if(WIN32)
   message(FATAL_ERROR "sysbench doesnot support Windows")
endif(WIN32)

project(sysbench-lua)

option( WITH_MYSQL "with-mysql"  OFF )
  set ( PACKAGE \"sysbench\" )
  set ( PACKAGE_NAME \"sysbench\" )
  set ( PACKAGE_TARNAME \"sysbench\" )
  set ( PACKAGE_STRING \"sysbench 1.1.0\" )
  set ( PACKAGE_VERSION \"1.1.0\" )
  set (PACKAGE_URL \"https://github.com/akopytov/sysbench\")
  set ( VERSION \"1.1.0\" )
  set ( SB_GIT_SHA \"-2e6b7d5\" )
  set ( SB_WITH_LUAJIT \"bundled\")
  set ( SB_WITH_CK \"bundled\")

message("Add thirparty luajit")
add_subdirectory(third_party/luajit/luajit)
add_library(luajit STATIC IMPORTED)
set_property(TARGET luajit PROPERTY IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/third_party/luajit/luajit/src/libluajit.a)
#add_dependencies(luajit sysbench)

include_directories(${CMAKE_CURRENT_SOURCE_DIR}/third_party/luajit/luajit/src ${CMAKE_CURRENT_SOURCE_DIR}/third_party/luajit/luajit)

message("Add thirparty concurrency_kit")
add_subdirectory(third_party/concurrency_kit/ck)
add_library(lib_ck STATIC IMPORTED)
set_property(TARGET lib_ck  PROPERTY IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/third_party/concurrency_kit/ck/src/libck.a)
#add_dependencies(lib_ck sysbench)

include_directories(${CMAKE_CURRENT_SOURCE_DIR}/third_party/concurrency_kit/ck ${CMAKE_CURRENT_SOURCE_DIR}/third_party/concurrency_kit/ck/src ${CMAKE_CURRENT_SOURCE_DIR}/third_party/concurrency_kit/ck/include)


if(WITH_MYSQL)
  if ("${MYSQLH_PATH}" STREQUAL "")
    if(DEFINED ENV{INC})
        find_path(MYSQLH_PATH mysql.h  ENV INC)
        message("mysql.h directory = ${MYSQLH_PATH}")
    else(DEFINED ENV{INC})
        message( FATAL_ERROR "MYSQLH_PATH not set, and Env var INC not set, CMake will exit." )
    endif(DEFINED ENV{INC})
  endif("${MYSQLH_PATH}" STREQUAL "")
endif(WITH_MYSQL)
if(WITH_MYSQL)
  if ("${MYSQLH_PATH}" STREQUAL "")
    if(DEFINED ENV{INC})
        find_path(MYSQLH_PATH mysql.h  ENV INC)
        message("mysql.h directory = ${MYSQLH_PATH}")
    else(DEFINED ENV{INC})
        message( FATAL_ERROR "MYSQLH_PATH not set, and Env var INC not set, CMake will exit." )
    endif(DEFINED ENV{INC})
  endif("${MYSQLH_PATH}" STREQUAL "")
endif(WITH_MYSQL)

if (UNIX)
  # Initial Linux build for sysbench against MySQL & NULL
  # TODO: Add Oracle & PgSQL
  # Replicates original autotools implementation wrt config.h
  include( CheckLibraryExists )
  include( CheckIncludeFiles )
  include( CheckFunctionExists )
  include( CheckSymbolExists )
  include( CheckCSourceCompiles )
  include( CheckCSourceRuns )
  include( CheckTypeSize )
  # ISO C89, ISO C99, POSIX.1, POSIX.2, BSD, SVID, X/Open, LFS, and GNU extensions.
  #ADD_DEFINITIONS(-D_GNU_SOURCE -DDATADIR=\"/usr/local/share/sysbench\" -DLIBDIR=\"/usr/local/lib/sysbench\")
  ADD_DEFINITIONS(-D_GNU_SOURCE)
  ADD_DEFINITIONS(-DDATADIR=\"\")
  ADD_DEFINITIONS(-DLIBDIR=\"\")
  ADD_DEFINITIONS(-DHAVE_CONFIG_H)

 include_directories(${CMAKE_SOURCE_DIR}/src/lua/internal ${CMAKE_SOURCE_DIR}/src )
  add_executable(sysbench 
	src/sysbench.c
	src/sysbench.h
	src/sb_timer.c
	src/sb_timer.h
	src/sb_options.c
	src/sb_options.h
	src/sb_logger.c
	src/sb_logger.h
	src/sb_list.h
	src/db_driver.h
	src/db_driver.c
	src/sb_histogram.c
	src/sb_histogram.h
	src/sb_rand.c
	src/sb_rand.h
	src/sb_thread.c
	src/sb_thread.h
	src/sb_barrier.c
	src/sb_barrier.h
	src/sb_lua.c
	src/sb_ck_pr.h
	src/sb_lua.h
	src/sb_util.h
	src/sb_util.c
	src/sb_counter.h
	src/sb_counter.c
	src/xoroshiro128plus.h
  )

  ##############################
  # Do checks, create config.h #
  ##############################

  # Hacks could not find how to check
  set ( HAVE_DECL_O_SYNC "1" )
  set ( LT_OBJDIR \".libs/\" )
  #set (HAVE_ISATTY "1")
  # Hacks end

  check_type_size( off_t OFF_T_SIZE )
  check_type_size( size_t SIZE_T_SIZE )
  check_type_size( "size_t" SIZEOF_SIZE_T )
  set( CMAKE_REQUIRED_INCLUDES math.h )
  set( CMAKE_REQUIRED_LIBRARIES m )

  if(WITH_MYSQL)
      if ("${LIBMYSQL_LIB}" STREQUAL "")
          if(DEFINED ENV{LIB})
             if(APPLE)
                 find_file(LIBMYSQL_LIB libmysqlclient.dylib ENV LIB)
             else(APPLE)
                 find_file(LIBMYSQL_LIB libmysqlclient.so ENV LIB)
             endif(APPLE)
          else(DEFINED ENV{INC})
             message( FATAL_ERROR "LIBMYSQL_LIB not set, and Env var LIB not set, CMake will exit." )
          endif(DEFINED ENV{LIB})
      endif("${LIBMYSQL_LIB}" STREQUAL "")
      message("mysqlclient = ${LIBMYSQL_LIB}")
      if(MYSQLH_PATH AND LIBMYSQL_LIB)
          set(USE_MYSQL 1)
          message("USE_MYSQL = ${USE_MYSQL}")
      endif(MYSQLH_PATH AND LIBMYSQL_LIB)
  endif(WITH_MYSQL)
  if(WITH_NULL)
    set(USE_NULL 1)
  endif(WITH_NULL)
  find_package (Threads)
  if (Threads_FOUND)
    if (CMAKE_USE_PTHREADS_INIT)
      set (HAVE_LIBPTHREAD 1)
    else  (CMAKE_USE_PTHREADS_INIT)
      set (HAVE_LIBPTHREAD 0)
    endif (CMAKE_USE_PTHREADS_INIT)
  endif (Threads_FOUND)

  check_include_files ( malloc.h      HAVE_MALLOC_H )
  check_include_files ( dlfcn.h       HAVE_DLFCN_H )
  check_include_files ( fcntl.h       HAVE_FCNTL_H )
  check_include_files ( errno.h       HAVE_ERRNO_H )
  check_include_files ( inttypes.h    HAVE_INTTYPES_H )
  check_include_files ( math.h        HAVE_MATH_H )
  check_include_files ( memory.h      HAVE_MEMORY_H )
  check_include_files ( pthread.h     HAVE_PTHREAD_H )
  check_include_files ( libaio.h      HAVE_LIBAIO_H )
  check_include_files ( sched.h       HAVE_SCHED_H )
  check_include_files ( "sys/aio.h"   HAVE_SYS_AIO_H )
  check_include_files ( signal.h      HAVE_SIGNAL_H )
  check_include_files ( stdint.h      HAVE_STDINT_H )
  check_include_files ( stdlib.h      HAVE_STDLIB_H )
  check_include_files ( strings.h     HAVE_STRINGS_H )
  check_include_files ( string.h      HAVE_STRING_H )
  check_include_files ( "sys/ipc.h"   HAVE_SYS_IPC_H )
  check_include_files ( "sys/mman.h"  HAVE_SYS_MMAN_H )
  check_include_files ( "sys/shm.h"   HAVE_SYS_SHM_H )
  check_include_files ( "sys/param.h" HAVE_SYS_PARAM_H)
  check_include_files ( "sys/types.h" HAVE_SYS_TYPES_H )
  check_include_files ( "sys/stat.h"  HAVE_SYS_AIO_H )
  check_include_files ( "sys/ipc.h"   HAVE_SYS_STAT_H )
  check_include_files ( "sys/time.h"  HAVE_SYS_TIME_H )
  check_include_files ( thread.h      HAVE_THREAD_H )
  check_include_files ( unistd.h      HAVE_UNISTD_H )
  check_include_files ("stdlib.h;stdarg.h;string.h;float.h" STDC_HEADERS)
  check_include_files ("limit.h" HAVE_LIMITS_H)


  check_function_exists ( alarm              HAVE_ALARM )
  check_function_exists ( strerror_r         HAVE_STRERROR_R )
  check_function_exists ( malloc             HAVE_MALLOC )
  check_function_exists ( fdatasync          HAVE_FDATASYNC )
  check_function_exists ( getpagesize        HAVE_GETPAGESIZE )
  check_function_exists ( gettimeofday       HAVE_GETTIMEOFDAY )
  check_function_exists ( isatty             HAVE_ISATTY )
  check_function_exists ( lrand48            HAVE_LRAND48 )
  check_function_exists ( memset             HAVE_MEMSET )
  check_function_exists ( memalign           HAVE_MEMALIGN )
  check_function_exists ( mmap               HAVE_MMAP )
  check_function_exists ( posix_memalign     HAVE_POSIX_MEMALIGN )
  check_function_exists ( pthread_cancel     PTHREAD_CANCEL )
  check_function_exists ( pthread_yield      HAVE_PTHREAD_YIELD )
  check_function_exists ( setvbuf            HAVE_SETVBUF )
  check_function_exists ( sqrt               HAVE_SQRT )
  check_function_exists ( strdup             HAVE_STRDUP )
  check_function_exists ( thr_setconcurrency HAVE_THR_SETCONCURRENCY )
  check_function_exists ( valloc             HAVE_VALLOC )
  check_function_exists (directio HAVE_DIRECTIO)
  check_function_exists (format HAVE_FUNC_ATTRIBUTE_FORMAT)
  check_function_exists (unused HAVE_FUNC_ATTRIBUTE_FORMAT)
  check_function_exists (getevents HAVE_OLD_GETEVENTS)

  check_symbol_exists ( gettimeofday  sys/time.h HAVE_GETTIMEOFDAY)
  check_symbol_exists ( isatty     unistd.h HAVE_ISATTY)
  check_symbol_exists ( SHM_HUGETLB   sys/shm.h  HAVE_DECL_SHM_HUGETLB )
  if(HAVE_DECL_SHM_HUGETLB)
    SET(HAVE_LARGE_PAGES 1)
    SET(HUGETLB_USE_PROC_MEMINFO 1)
    SET(HAVE_LARGE_PAGE_OPTION 1)
  endif(HAVE_DECL_SHM_HUGETLB)

  check_symbol_exists ( PTHREAD_CREATE_JOINABLE pthread.h HAVE_PTHREAD_CREATE_JOINABLE)
  if (NOT HAVE_PTHREAD_CREATE_JOINABLE)
        CHECK_SYMBOL_EXISTS(PTHREAD_CREATE_DETACHED pthread.h HAVE_PTHREAD_CREATE_DETACHED)
        if (HAVE_PTHREAD_CREATE_DETACHED)
        set(PTHREAD_CREATE_JOINABLE "PTHREAD_CREATE_DETACHED")
        endif (HAVE_PTHREAD_CREATE_DETACHED)
  endif (NOT HAVE_PTHREAD_CREATE_JOINABLE)

  check_library_exists(aio io_queue_init "" HAVE_LIBAIO)
  check_library_exists(m pow             "" HAVE_LIBM )

  # Check whether time and sys/time can both be included
  check_c_source_compiles(
    "#include <sys/time.h>
     #include <time.h>
     int main(int argc, char** argv) {return 0;}"
     TIME_WITH_SYS_TIME
  )
 check_c_source_compiles("
     __thread int tls;
     int main(void) {
      return 0;
  }" TLS)

  set(save_cmake_required_flags "${CMAKE_REQUIRED_FLAGS}")
  set(CMAKE_REQUIRED_FLAGS "${cmake_required_flags} -Wall -Wextra -Werror")
  check_c_source_compiles(
    "#include <string.h>
     int main() {
     char * c;
     c = strerror_r(0,c,0);
     return 0;}"
     STRERROR_R_CHAR_P
   )
  set(CMAKE_REQUIRED_FLAGS "${save_cmake_required_flags}")

  if( STRERROR_R_CHAR_P )
    set( HAVE_DECL_STRERROR_R 1 )
  endif( STRERROR_R_CHAR_P )

  if( NOT HAVE_MALLOC )
   set( malloc rpl_malloc )
  endif( NOT HAVE_MALLOC )

  # Inspired from https://cmake.org/Wiki/CMakeTestInline
  # removed, because inline was removed between 1.0.12 and 1.0.20

  set(LFS_TEST_PROGRAM
    "#include <sys/types.h>
     #define LARGE_OFF_T (((off_t) 1 << 62) - 1 + ((off_t) 1 << 62))
     int off_t_is_large[(LARGE_OFF_T % 2147483629 == 721 && LARGE_OFF_T % 2147483647 == 1) ? 1 : -1];
     int main() { return 0; } ")
  check_c_source_compiles("${LFS_TEST_PROGRAM}" NO_LFS_MACROS_REQUIRED)
  if(NOT NO_LFS_MACROS_REQUIRED)
    if(NOT DEFINED FILE_OFFSET_BITS_LFS_MACRO_REQUIRED)
      check_c_source_compiles("#define _FILE_OFFSET_BITS 64 ${LFS_TEST_PROGRAM}" FILE_OFFSET_BITS_LFS_MACRO_REQUIRED)
      if(FILE_OFFSET_BITS_LFS_MACRO_REQUIRED)
        add_definitions(-D_FILE_OFFSET_BITS=64)
      elseif(NOT DEFINED LARGE_FILES_LFS_MACRO_REQUIRED)
        check_c_source_compiles("#define _LARGE_FILES 1 ${LFS_TEST_PROGRAM}" LARGE_FILES_LFS_MACRO_REQUIRED)
        if(LARGE_FILES_LFS_MACRO_REQUIRED)
          add_definitions(-D_LARGE_FILES=1)
        endif(LARGE_FILES_LFS_MACRO_REQUIRED)
      endif(FILE_OFFSET_BITS_LFS_MACRO_REQUIRED)
    endif(NOT DEFINED FILE_OFFSET_BITS_LFS_MACRO_REQUIRED)
  endif(NOT NO_LFS_MACROS_REQUIRED)
  unset(LFS_TEST_PROGRAM)

  configure_file(${CMAKE_CURRENT_SOURCE_DIR}/config/config.h.cmake ${CMAKE_CURRENT_SOURCE_DIR}/config.h)

  SET(CMAKE_C_FLAGS
    "-std=gnu99 ${CMAKE_C_FLAGS} -Wall -Wextra -Wformat-security -Wvla -Wwrite-strings -Wdeclaration-after-statement")
  SET(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -g -fno-omit-frame-pointer -std=c++11")
endif (UNIX)

target_link_libraries (sysbench luajit)
target_link_libraries (sysbench ${CMAKE_DL_LIBS})
target_link_libraries (sysbench lib_ck)

if(USE_NULL)
  message("Adding null db driver")
  add_subdirectory(src/drivers/nulldb)
  target_link_libraries (sysbench sbnull)
  message("Add done")
endif(USE_NULL)

if(USE_MYSQL)
  message("Adding MySQL db driver")
  set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DUSE_MYSQL")
  include_directories(${MYSQLH_PATH} ${CMAKE_SOURCE_DIR} )
  add_subdirectory(src/drivers/mysql)
  target_link_libraries (sysbench sbmysql)
  if(HAVE_LIBAIO)
    target_link_libraries (sysbench ${LIBMYSQL_LIB} ${CMAKE_THREAD_LIBS_INIT} m aio)
  else()
    target_link_libraries (sysbench ${LIBMYSQL_LIB} ${CMAKE_THREAD_LIBS_INIT} m)
  endif()
  message("Add done")
endif(USE_MYSQL)

if(USE_PGSQL)
  message("Adding pgsql driver")
  if(UNIX)
    message( FATAL_ERROR "UNIX/Linux not yet supported, CMake will exit.")
  endif(UNIX)
  set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DUSE_PGSQL")
  include_directories(${PGSQLH_PATH})
  add_subdirectory(src/drivers/pgsql)
  target_link_libraries (sysbench sbpgsql)
  target_link_libraries (sysbench ${LIBPGSQL_LIB})
  message("Add done")
endif(USE_PGSQL)

if(USE_ORACLE)
  message("Adding oracle driver")
  if(UNIX)
    message( FATAL_ERROR "UNIX/Linux not yet supported, CMake will exit.")
  endif(UNIX)
  set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DUSE_ORACLE")
  include_directories(${ORACLEH_PATH})
  add_subdirectory(src/drivers/oracle)
  target_link_libraries (sysbench sboracle)
  target_link_libraries (sysbench ${LIBORACLE_LIB})
  message("Add done")
endif(USE_ORACLE)

include_directories(${CMAKE_CURRENT_SOURCE_DIR} ${CMAKE_CURRENT_SOURCE_DIR}/src/tests/cpu ${CMAKE_CURRENT_SOURCE_DIR}/src/tests/fileio)

message("Adding test cpu")
add_subdirectory(src/tests/cpu)
target_link_libraries (sysbench sbcpu)
message("Add done")

message("Adding test fileio")
add_subdirectory(src/tests/fileio)
target_link_libraries (sysbench sbfileio)
message("Add done")

message("Adding test mutex")
add_subdirectory(src/tests/mutex)
target_link_libraries (sysbench sbmutex)
message("Add done")

message("Adding test threads")
add_subdirectory(src/tests/threads)
target_link_libraries (sysbench sbthreads)
message("Add done")

message("Adding test memory")
add_subdirectory(src/tests/memory)
target_link_libraries (sysbench sbmemory)
message("Add done")

if (Threads_FOUND)
  target_link_libraries(sysbench ${CMAKE_THREAD_LIBS_INIT})
endif()

if (HAVE_LIBM)
  target_link_libraries (sysbench m)
endif()

if (HAVE_LIBAIO)
  target_link_libraries (sysbench aio)
endif()

message("script complete")

