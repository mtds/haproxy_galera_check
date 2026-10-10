#
# SST user used by mariabackup on the donor side, and the monitoring
# user consumed by the clusterchk sidecars.
#
CREATE USER IF NOT EXISTS 'sst'@'localhost' IDENTIFIED BY 'sstpass';
GRANT RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'sst'@'localhost';

CREATE USER IF NOT EXISTS 'clustercheck'@'%' IDENTIFIED BY 'ccheckpass';
GRANT USAGE ON *.* TO 'clustercheck'@'%';

FLUSH PRIVILEGES;
