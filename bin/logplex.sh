#!/bin/sh

export USER=logplex
export DIR=/opt/logplex
export SERVER_UID=`id -u $USER`
export SERVER_GID=`id -g $USER`
export HOME=/root

ulimit -n 65535
cd $DIR
erl +K true +A30 +P500000 -kernel inet_dist_listen_min 9100 -kernel inet_dist_listen_max 9200 -env ERL_FULLSWEEP_AFTER 0 -env ERL_MAX_PORTS 65535 -name logplex@`hostname --fqdn` -pa ebin -pa deps/*/ebin -noshell -boot release/logplex-1.0 | logger -p local5.info -t $USER