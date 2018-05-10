#!/bin/bash
set -e

# first arg is `-f` or `--some-option`
if [ "${1:0:1}" = '-' ]; then
	set -- cassandra -f "$@"
fi

if [ "$1" = 'cassandra' ]; then
	# TODO detect if this is a restart if necessary
	: ${CASSANDRA_LISTEN_ADDRESS='auto'}
	if [ "$CASSANDRA_LISTEN_ADDRESS" = 'auto' ]; then
		CASSANDRA_LISTEN_ADDRESS="$(hostname --ip-address)"
	fi

	: ${CASSANDRA_BROADCAST_ADDRESS="$CASSANDRA_LISTEN_ADDRESS"}

	if [ "$CASSANDRA_BROADCAST_ADDRESS" = 'auto' ]; then
		CASSANDRA_BROADCAST_ADDRESS="$(hostname --ip-address)"
	fi
	: ${CASSANDRA_BROADCAST_RPC_ADDRESS:=$CASSANDRA_BROADCAST_ADDRESS}

	if [ -n "${CASSANDRA_NAME:+1}" ]; then
		: ${CASSANDRA_SEEDS:="cassandra"}
	fi
	: ${CASSANDRA_SEEDS:="$CASSANDRA_BROADCAST_ADDRESS"}
	
	sed -ri 's/(- seeds:) "127.0.0.1"/\1 "'"$CASSANDRA_SEEDS"'"/' "$CASSANDRA_CONFIG/cassandra.yaml"

	for yaml in \
		broadcast_address \
		broadcast_rpc_address \
		cluster_name \
		endpoint_snitch \
		listen_address \
		num_tokens \
	; do
		var="CASSANDRA_${yaml^^}"
		val="${!var}"
		if [ "$val" ]; then
			sed -ri 's/^(# )?('"$yaml"':).*/\2 '"$val"'/' "$CASSANDRA_CONFIG/cassandra.yaml"
		fi
	done

	for rackdc in dc rack; do
		var="CASSANDRA_${rackdc^^}"
		val="${!var}"
		if [ "$val" ]; then
			sed -ri 's/^('"$rackdc"'=).*/\1 '"$val"'/' "$CASSANDRA_CONFIG/cassandra-rackdc.properties"
		fi
	done


	####################################################################################
	if [ -e /init_scripts/handled ]; then
		echo "............... CQL scripts already handled ..............."
	elif [ ! "$(ls ./init_scripts/*.cql)" ]; then
		echo "............... No CQL scripts found ..............."
	else
		# Now it's time to try to execute CQL scripts found in /init_scripts 
		echo '* * * Initializing database with CQL scripts * * *'

		# We need to start temporarily cassandra in a background mode
		cassandra &

		# Making sure the server is up before sending CQL statments
		set +e
		sleep 5
		
		for i in {30..0}; do
			KS=$(cqlsh -e "DESCRIBE KEYSPACES" | grep "system ")
			if [ -n "$KS" ]; then
				echo "Cassandra started"
				break
			fi
			echo 'Cassandra init process in progress...'
			sleep 1
		done
		set -e
		if [ "$i" = 0 ] && [ -n "$KS" ]; then
			echo >&2 'Cassandra init process failed.'
			exit 1
		fi

		# Ok, since cassandra seems to be completely started, we may execute CQL scripts 
		echo
		for f in ./init_scripts/*; do
			case "$f" in
				*.cql) echo "$0: running $f"; cqlsh -f "$f" && echo ;;
				*)     echo "$0: ignoring $f" ;;
			esac
		echo
		done

		# Mark initialization scripts as handled to avoid re-execution when container restarts
		touch /init_scripts/handled

		# Stopping cassandra process
		pid=$(pgrep -f "java.*cassandra")

		kill -s TERM "$pid"

		for i in {30..0}; do
			if [ ! -e /proc/"$pid" ]; then
				echo "Intermediate Cassandra process $pid stopped"
		    	break
		    fi
		    echo ">>>>>>>> Intermediate Cassandra process $pid PID still running"
		    sleep 1
		done
	fi
	####################################################################################

fi

exec "$@"