#!/bin/bash
ARGS="$@"
echo "$@" | grep -q -- "-join"
if [[ $? -ne 0 ]]; then
    echo "setting initial advertise peer urls and initial cluster"
    SECONDS=0
    echo "resolving the container IP with Docker DNS..."
    while [ -z "$cip" ]; do
        cip=$(dig @127.0.0.11 +short $(hostname))
        # checking that the returned IP is really an IP
        echo "$cip" | egrep -qe "^[0-9\.]+$"
        if [ -z "$cip" ]; then
        sleep 1
        fi
        [[ $SECONDS -gt 10 ]] && break
    done
    echo "$cip" | egrep -qe "^[0-9\.]+$"
    if [ $? -ne 0 ]; then
        # if not resolved by Docker dns, there should be an entry in /etc/hosts
        echo "warning: unable to resolve this container's IP ($cip), switching back to /etc/hosts"
        cip=$(grep $(hostname) /etc/hosts |awk '{print $1}' | head -1)
        echo "found IP in /etc/hosts: $cip"
    else
        echo "resolved IP: $cip"
    fi
    TASK_FQDN=$(dig @127.0.0.11 +noall +answer -x $cip | awk '{ print $5 }')
    export SERVICE_NAME=$(dig @127.0.0.11 +noall +answer -x $cip | awk '{ print $5 }' | cut -d "." -f 1)

    if [[ -n "$SERVICE_NAME" ]]; then
        INITIAL_CLUSTER_TOKEN=$SERVICE_NAME

        echo "building a seeds list for cluster $SERVICE_NAME"
        # IP of the service tasks
        typeset -i nbt
        nbt=0
        SECONDS=0
        echo "waiting for the min seeds count ($MIN_SEEDS_COUNT)"
        while [[ $nbt -lt ${MIN_SEEDS_COUNT} ]]; do
            tips=$(dig +short tasks.$SERVICE_NAME)
            nbt=$(echo $tips | wc -w)
            [[ $SECONDS -gt 30 ]] && break
        done
        if [[ $nbt -lt ${MIN_SEEDS_COUNT} ]]; then
            echo "error: couldn't reach the min seeds count after $SECONDS sec, only $nbt tasks were found"
            exit 1
        else
            echo "$nbt seeds found"
        fi
        for tip in $tips; do
            [[ -z "$INITIAL_CLUSTER" ]] && INITIAL_CLUSTER="$tip:26257" || INITIAL_CLUSTER="$INITIAL_CLUSTER,$tip:26257"
        done
    else
        echo "error: no service name detected"
        exit 1
    fi
    ARGS="$ARGS --join=$INITIAL_CLUSTER"
fi
echo "$@" | grep -q -- "-store"
if [[ $? -ne 0 ]]; then
    ARGS="$ARGS --store=/data"
fi
echo "$@" | grep -q -- "-certs-dir"
if [[ $? -ne 0 ]]; then
    ARGS="$ARGS --certs-dir=/certs"
fi

echo "creating node certificate"
cockroach cert create-node \
    localhost \
    $(hostname) \
    $TASK_FQDN \
    $cip \
    cockroach \
    --certs-dir=/certs \
    --ca-key=/certs/ca.key

chmod 600 /certs/ca.key
chmod 600 /certs/client.root.key

cockroach cert list \
    --certs-dir=/certs

COCKROACH_INCONSISTENT_TIME_ZONES=1 cockroach start $ARGS --advertise-addr=$(hostname)
