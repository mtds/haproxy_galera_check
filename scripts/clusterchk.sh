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

# Variables:
MYSQL_HOST="localhost"
MYSQL_PORT="3306"

#
# Read the Debian config file (INI format) for MySQL:
#
read_debian_config () {

  local DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
  source $DIR/read_ini.sh

  # Call the parser function over the debian.cnf file:
  read_ini -p DebCnf /etc/mysql/debian.cnf

  # Concatenate the parameters for the MySQL client:
  USEROPTIONS="--user=$DebCnf__client__user --password=$DebCnf__client__password"
}

#
# Node status looks fine, so return an 'HTTP 200' status code.
#
http_ok () {
  /bin/echo -e "HTTP/1.1 200 OK\r\n"
  /bin/echo -e "Content-Type: Content-Type: text/plain\r\n"
  /bin/echo -e "\r\n"
  /bin/echo -e "$1"
  /bin/echo -e "\r\n"
}

#
# Node status reports problems, so return an 'HTTP 503' status code.
#
http_no_access () {
  /bin/echo -e "HTTP/1.1 503 Service Unavailable\r\n"
  /bin/echo -e "Content-Type: Content-Type: text/plain\r\n"
  /bin/echo -e "\r\n"
  /bin/echo -e "$1"
  /bin/echo -e "\r\n"
}

#
# Run a SQL query on the local MySQL instance.
# 
status_query () {
  SQL_QUERY=`/usr/bin/mysql --host=$MYSQL_HOST --port=$MYSQL_PORT $USEROPTIONS --silent --raw -N -e "$1"`
  RESULT=`echo $SQL_QUERY|/usr/bin/cut -d ' ' -f 2` # just remove the value label
  echo $RESULT
}

#
# Safety check: verify if MySQL is up and running.
#
MYSQL_INSTANCE=`/bin/systemctl is-active mysql.service`
if [ "$MYSQL_INSTANCE" != 'active' ]; then
    http_no_access "MySQL instance is reported $MYSQL_STATUS.\r\n"
    exit 1
fi

#
# Acquire Debian user credentials:
#
read_debian_config

#
# Check the node status against the Galera Cluster:
#
GALERA_STATUS=$(status_query "SHOW STATUS LIKE 'wsrep_local_state_comment';")

#
# Check the method used for SST transfers:
#
SST_METHOD=$(status_query "SHOW VARIABLES LIKE 'wsrep_sst_method';")

#
# Check if MySQL is in 'read-only' status:
#
MYSQL_READONLY=$(status_query "SELECT @@global.read_only;")

# 
# If the (Galera) WSREP provider reports a status different than Synced
# it would be safe for HAproxy to reschedule SQL queries somewhere else.
#
# Node states:
# http://galeracluster.com/documentation-webpages/nodestates.html#node-state-changes
#
if [ "$GALERA_STATUS" == "Synced" ]; then
  if [ "$MYSQL_READONLY" -eq 0 ]; then
     http_ok "Galera status is $GALERA_STATUS\r\n"
  else
     http_no_access "Galera status is $GALERA_STATUS but the local MySQL instance is reported to be read-only.\r\n"
  fi
elif [ "$GALERA_STATUS" == "Donor" ]; then # node is acting as 'Donor' for another node
  if [ "$SST_METHOD" == "xtrabackup" ] || [ "$SST_METHOD" == "xtrabackup-v2" ]; then
     http_ok "Galera status is $GALERA_STATUS.\r\n" # xtrabackup is a non-blocking method
  else
     http_no_access "Galera status is $GALERA_STATUS.\r\n"
  fi
else
  http_no_access "Galera status is $GALERA_STATUS.\r\n"
fi
