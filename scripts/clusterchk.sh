#!/bin/bash

# Author:: Matteo Dessalvi
#
# Copyright:: 2017
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# 
# This script checks the status of a MySQL instance
# which has joined a Galera Cluster.
#
# It will return: 
# 
#    "HTTP/1.x 200 OK\r" (if the node status is 'Synced') 
# 
# - OR - 
# 
#    "HTTP/1.x 503 Service Unavailable\r" (for any other status) 
# 
# The return values from this script will be used by HAproxy 
# in order to know the (Galera) status of a node.
#

set -u

# Variables:
MYSQL_HOST="localhost"
MYSQL_PORT="3306"
MYSQL_DEFAULTS_FILE="/etc/mysql/debian.cnf"

#
# Detect the systemd unit name of the local database instance.
#
detect_mysql_unit () {
  local unit
  for unit in mysql.service mariadb.service mysqld.service; do
    if [ "$(/bin/systemctl is-active "$unit" 2>/dev/null)" = 'active' ]; then
      echo "$unit"
      return 0
    fi
  done
  return 1
}

#
# Node status looks fine, so return an 'HTTP 200' status code.
#
http_ok () {
  /bin/echo -e "HTTP/1.1 200 OK\r\n"
  /bin/echo -e "Content-Type: text/plain\r\n"
  /bin/echo -e "\r\n"
  /bin/echo -e "$1"
  /bin/echo -e "\r\n"
}

#
# Node status reports problems, so return an 'HTTP 503' status code.
#
http_no_access () {
  /bin/echo -e "HTTP/1.1 503 Service Unavailable\r\n"
  /bin/echo -e "Content-Type: text/plain\r\n"
  /bin/echo -e "\r\n"
  /bin/echo -e "$1"
  /bin/echo -e "\r\n"
}

#
# Run a SQL query on the local MySQL instance and print the value column.
# Returns non-zero (and prints nothing) if the query fails or is empty.
#
status_query () {
  local result
  result=$(/usr/bin/mysql --defaults-extra-file="$MYSQL_DEFAULTS_FILE" \
             --host="$MYSQL_HOST" --port="$MYSQL_PORT" \
             --silent --raw -N -e "$1" 2>/dev/null) || return 1
  [ -n "$result" ] || return 1
  # just remove the value label
  awk '{print $2}' <<< "$result"
}

#
# Safety check: verify if MySQL is up and running.
#
MYSQL_INSTANCE=$(detect_mysql_unit) || MYSQL_INSTANCE="inactive"
if [ "$MYSQL_INSTANCE" = 'inactive' ]; then
    http_no_access "MySQL instance is not active.\r\n"
    exit 1
fi

if [ ! -r "$MYSQL_DEFAULTS_FILE" ]; then
    http_no_access "Cannot read the defaults file $MYSQL_DEFAULTS_FILE.\r\n"
    exit 1
fi

#
# Check the node status against the Galera Cluster:
#
if ! GALERA_STATUS=$(status_query "SHOW STATUS LIKE 'wsrep_local_state_comment';"); then
  http_no_access "Unable to query wsrep_local_state_comment on the local MySQL instance.\r\n"
  exit 1
fi

#
# Check the method used for SST transfers:
#
SST_METHOD=$(status_query "SHOW VARIABLES LIKE 'wsrep_sst_method';") || SST_METHOD="unknown"

#
# Check if MySQL is in 'read-only' status:
#
if ! MYSQL_READONLY=$(status_query "SELECT @@global.read_only;"); then
  http_no_access "Unable to query read_only on the local MySQL instance.\r\n"
  exit 1
fi

# 
# If the (Galera) WSREP provider reports a status different than Synced
# it would be safe for HAproxy to reschedule SQL queries somewhere else.
#
# Node states:
# http://galeracluster.com/documentation-webpages/nodestates.html#node-state-changes
#
if [ "$GALERA_STATUS" == "Synced" ]; then
  if [ "$MYSQL_READONLY" == "0" ]; then
     http_ok "Galera status is $GALERA_STATUS\r\n"
  else
     http_no_access "Galera status is $GALERA_STATUS but the local MySQL instance is reported to be read-only.\r\n"
  fi
elif [ "$GALERA_STATUS" == "Donor/Desynced" ]; then # node is acting as 'Donor' for another node
  if [ "$SST_METHOD" == "mariabackup" ] || [ "$SST_METHOD" == "xtrabackup" ] || [ "$SST_METHOD" == "xtrabackup-v2" ]; then
     http_ok "Galera status is $GALERA_STATUS.\r\n" # xtrabackup is a non-blocking method
  else
     http_no_access "Galera status is $GALERA_STATUS.\r\n"
  fi
else
  http_no_access "Galera status is $GALERA_STATUS.\r\n"
fi
