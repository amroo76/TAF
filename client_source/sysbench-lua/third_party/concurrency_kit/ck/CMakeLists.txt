#Copyright (c) 2018 Oracle and/or its affiliates. All rights reserved.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

INCLUDE_DIRECTORIES(${CMAKE_CURRENT_SOURCE_DIR} ${CMAKE_CURRENT_SOURCE_DIR}/src ${CMAKE_CURRENT_SOURCE_DIR}/include)
execute_process ( COMMAND ./configure  --prefix=${CMAKE_CURRENT_SOURCE_DIR} WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
execute_process ( COMMAND make clean WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/src)
execute_process ( COMMAND make  WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/src)
execute_process ( COMMAND chmod 644 ${CMAKE_CURRENT_SOURCE_DIR}/src/libck.a WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/src)
execute_process ( COMMAND make install WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/src)
