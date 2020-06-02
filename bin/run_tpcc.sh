#!/usr/bin/env bash

set -euo pipefail

readonly tpcc_checkout_dir=$HOME/tpcc
tpcc_work_time_sec=600
tpcc_scale_factor=100
tpcc_terminals=$(( tpcc_scale_factor * 10 ))
tpcc_loader_batch_size=64
tpcc_loader_threads=24

install_yum_packages() {
  local yum_packages=(
    java-1.8.0-openjdk-devel
    screen
    ant
    git
  )
  ( set -x; sudo yum install -y "${yum_packages[@]}" )
}

install_tpcc() {
  if [[ ! -d $tpcc_checkout_dir ]]; then
    ( set -x; git clone https://github.com/yugabyte/tpcc "$tpcc_checkout_dir" )
  fi
  (
    set -x
    cd "$tpcc_checkout_dir"
    git checkout master
    git fetch origin
    git reset --hard origin/master

    ant bootstrap
    ant resolve
    ant build
  )
}

create_tpcc_conf() {
  local server_addrs
  # Only works for 3-node clusters.
  server_addrs=( $(
    sudo cat /home/yugabyte/tserver/conf/server.conf | grep tserver_master_addrs | sed 's/.*=//g; s/:7100//g; s/,/ /g'
  ) )
  local ip
  local db_urls=""
  for ip in "${server_addrs[@]}"; do
    if [[ ! $ip =~ ^[0-9]+([.][0-9]+){3}$ ]]; then
      echo >&2 "Invalid IP address: $ip"
      exit 1
    fi
    if [[ -n $db_urls ]]; then
      db_urls+=","
    fi
    db_urls+="jdbc:postgresql://$ip:5433/yugabyte"
  done

  cat >"$tpcc_checkout_dir/config/workload_all.xml" <<-EOT
<?xml version="1.0"?>
<parameters>
    <dbtype>postgres</dbtype>
    <driver>org.postgresql.Driver</driver>
    <DBUrl>$db_urls</DBUrl>
    <username>yugabyte</username>
    <password></password>
    <isolation>TRANSACTION_REPEATABLE_READ</isolation>

    <!-- The number of warehouses -->
    <scalefactor>$tpcc_scale_factor</scalefactor>
    <!-- Number of threads used for loading data -->
    <loaderThreads>$tpcc_loader_threads</loaderThreads>
    <!-- TPC-C 4.2.2: The number of terminals should be 10 per warehouse -->
    <terminals>$tpcc_terminals</terminals>
    <batchSize>$tpcc_loader_batch_size</batchSize>

    <useKeyingTime>true</useKeyingTime>
    <useThinkTime>true</useThinkTime>
    <enableForeignKeysAfterLoad>true</enableForeignKeysAfterLoad>

        <transactiontypes>
        <transactiontype>
                <name>NewOrder</name>
        </transactiontype>
        <transactiontype>
                <name>Payment</name>
        </transactiontype>
        <transactiontype>
                <name>OrderStatus</name>
        </transactiontype>
        <transactiontype>
                <name>Delivery</name>
        </transactiontype>
        <transactiontype>
                <name>StockLevel</name>
        </transactiontype>
        </transactiontypes>
    <works>
        <work>
          <time>$tpcc_work_time_sec</time>
          <rate>10000</rate>
          <ratelimited bench="tpcc">true</ratelimited>
          <weights>45,43,4,4,4</weights>
        </work>
    </works>

</parameters>
EOT
  (
    set -x
    cd "$tpcc_checkout_dir"
    git diff -w
    time ./tpccbenchmark -c config/workload_all.xml --create=true --load=true --execute=true
  )
}

(
  install_yum_packages
  install_tpcc
  create_tpcc_conf
) 2>&1 | tee ~/tpcc.log
