#!/bin/bash
# Get secrets
if [ -f /run/secrets/user ]; then USER=$(cat /run/secrets/user); fi
USER="${USER:=$(cat /dev/urandom | base64 | tr -d "/+" | head -c8)}"
if [ -f /run/secrets/password ]; then PASSWORD=$(cat /run/secrets/password); fi
PASSWORD="${PASSWORD:=$(cat /dev/urandom | base64 | head -c16)}"
if [ -f /run/secrets/user ]; then APIKEY=$(cat /run/secrets/apikey); fi
APIKEY="${APIKEY:=$(cat /dev/urandom | base64 | tr -d "/+" | head -c32)}"

# Set directory paths
STACK_DIR="${STACK_DIR:=/srv/default}"
STORAGE_CLUSTER_DIR="${STORAGE_CLUSTER_DIR:=$STACK_DIR/cluster}"
STORAGE_LOCAL_DIR="${STORAGE_LOCAL_DIR:=$STACK_DIR/local}"

STORAGE_CLUSTER_SERVICE="${STORAGE_CLUSTER_SERVICE:=syncthing}"
case $STORAGE_CLUSTER_SERVICE in
    resilio) echo "GENERAL: INFO: Using Resilio Sync for clustered storage." ;;
    syncthing) echo "GENERAL: INFO: Using Syncthing for clustered storage." ;;
    *)
        echo "GENERAL: ERROR: STORAGE_CLUSTER_SERVICE defined is not supported."
        echo "GENERAL: INFO: Defaulting to Syncthing for clustered storage."
        STORAGE_CLUSTER_SERVICE=syncthing
    ;;
esac

MIN_SEEDS_COUNT=3
STORAGE_CLUSTER_NEEDED=(authelia cockroach letsencrypt)

for name in ${STORAGE_CLUSTER_NEEDED[@]}; do
    declare "STORAGE_CLUSTER_${name^^}_DIR=$STORAGE_CLUSTER_DIR/$name"
    echo "GENERAL: INFO: Waiting for $STORAGE_CLUSTER_DIR/$name to be created..."
    while [ ! -d $STORAGE_CLUSTER_DIR/$name ]; do sleep 1; done
done
echo "GENERAL: INFO: ... all directories found."

SECONDS=0
echo "GENERAL: INFO: resolving this container's IP with Docker DNS..."
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
    echo "GENERAL: WARNING: unable to resolve this container's IP ($cip), switching back to /etc/hosts"
    cip=$(grep $(hostname) /etc/hosts |awk '{print $1}' | head -1)
    echo "GENERAL: INFO: found IP in /etc/hosts: $cip"
else
    echo "GENERAL: INFO: resolved IP: $cip"
fi
export SERVICE_NAME=$(dig @127.0.0.11 +noall +answer -x $cip | awk '{ print $5 }' | cut -d "." -f 1)
if [[ -z "$SERVICE_NAME" ]]; then
    echo "GENERAL ERROR: no service name detected"
    exit 1
fi
export STACK_NAME=$(echo $(echo $SERVICE_NAME | awk -F_ '{$NF="";print $0}') | tr -d ' ')

format_json() {
    if [[ $1 =~ ^\[.* ]] || [[ $1 =~ ^\{.* ]]; then
        echo "$@"
    else
        if  [[ "$2" =~ ^\[.* ]] || [[ "$2" =~ ^\{.* ]] || [[ $2 == true ]] || [[ $2 == false ]] || [[ $2 == 0 ]] || [[ $2 -lt 0 ]] || [[ $2 -gt 0 ]]; then 
            echo "{\"$1\":${@:2}}"
        else 
            echo "{\"$1\":\"${@:2}\"}"
        fi
    fi
}
# $1 = HTTP Request Type
# $2 = API Key
# $3 = Host Address
# $4 = API Path
# $5+ = (optional) Payload Data
syncthing_curl() {
    case $1 in
        GET)
            curl -sk -X GET -H "X-API-Key: $2" https://$3:$SYNCTHING_API_PORT/rest/$4
        ;;
        *)
            if [ -f $5 ]; then
                echo "SYNCTHING: "$1"ing $4 on $3" 1>&2
                curl -sk -X $1 -H 'Content-Type: application/json' -H "X-API-Key: $2" --data-binary @$5 https://$3:$SYNCTHING_API_PORT/rest/$4
            else
                payload=$(format_json ${@:5})
                echo "SYNCTHING: "$1"ing $4 on $3" 1>&2
                curl -sk -X $1 -H 'Content-Type: application/json' -H "X-API-Key: $2" --data $payload https://$3:$SYNCTHING_API_PORT/rest/$4
            fi
        ;;
    esac
}
syncthing_api() {
    syncthing_curl $1 $APIKEY ${@:2}
}
syncthing_manager() {
    SYNCTHING_API_PORT="${SYNCTHING_API_PORT:=8384}"
    SYNCTHING_DISCOVERY_TASKS_DOMAIN="tasks."$STACK_NAME"_syncthing-discovery."
    SYNCTHING_TASKS_DOMAIN="tasks."$STACK_NAME"_syncthing."
    SYNCTHING_SLEEP=5
    mkdir -p /configs/devices

    echo "SYNCTHING: INFO: Waiting for discovery server..."
    while [ -z "$(dig $SYNCTHING_DISCOVERY_TASKS_DOMAIN +short)" ]; do sleep 1; done
    echo "SYNCTHING: INFO: Discovery server running"
    SYNCTHING_DEVICE_IDS=()
    while true; do
        SYNCTHING_RESET_SLEEP=0
        SYNCTHING_CONTAINER_IPS=($(dig $SYNCTHING_TASKS_DOMAIN +short))

        if [ ${#SYNCTHING_CONTAINER_IPS[@]} -gt 0 ] && [[ -z $SYNCTHING_CONTAINER_FIRST ]]; then
            SYNCTHING_CONTAINER_FIRST=${#SYNCTHING_CONTAINER_IPS[0]}
        fi
        
        if [ ${#SYNCTHING_CONTAINER_IPS[@]} -gt 1 ]; then 
            for SYNCTHING_CONTAINER_IP in ${SYNCTHING_CONTAINER_IPS[@]}; do
                SYNCTHING_CONTAINER_FQDN=$(dig @127.0.0.11 +noall +answer +short -x $SYNCTHING_CONTAINER_IP)
                SYNCTHING_CONTAINER_NODE_ID=$(echo $SYNCTHING_CONTAINER_FQDN | awk -F. '{print $2}')
                SYNCTHING_CONTAINER_ID=$(echo $SYNCTHING_CONTAINER_FQDN | awk -F. '{print $3}')

                SYNCTHING_CONTAINER_CONFIG=$(syncthing_api GET $SYNCTHING_CONTAINER_IP config | jq -c '.')
                
                SYNCTHING_CONTAINER_DEVICE_ID=$(syncthing_api GET $SYNCTHING_CONTAINER_IP system/status | jq -r '.myID')
                if [[ -z $(echo "${SYNCTHING_DEVICES[@]}" | grep "$SYNCTHING_CONTAINER_DEVICE_ID") ]]; then
                    SYNCTHING_DEVICES+=("$SYNCTHING_CONTAINER_DEVICE_ID:$SYNCTHING_CONTAINER_ID:$SYNCTHING_CONTAINER_IP")
                    SYNCTHING_RESET_SLEEP=1
                fi
                if [ ${#SYNCTHING_DEVICES[@]} -gt 1 ]; then
                    SYNCTHING_FOLDER_DEVICES="{\"deviceID\":\"$SYNCTHING_DEVICE_ID\"}"
                    for SYNCTHING_DEVICE in ${SYNCTHING_DEVICES[@]}; do
                        SYNCTHING_DEVICE_ID=($(echo $SYNCTHING_DEVICE | awk -F: '{print $1}'))
                        SYNCTHING_DEVICE_NAME=($(echo $SYNCTHING_DEVICE | awk -F: '{print $2}'))
                        SYNCTHING_DEVICE_IP=($(echo $SYNCTHING_DEVICE | awk -F: '{print $3}'))
                        if [[ -z $(echo $SYNCTHING_CONTAINER_CONFIG | jq -r ".devices[].deviceID" | grep $SYNCTHING_DEVICE_ID) ]]; then
                            syncthing_api PUT $SYNCTHING_CONTAINER_IP config/devices/$SYNCTHING_DEVICE_ID \
                                "{\"deviceID\":\"$SYNCTHING_DEVICE_ID\",\"name\":\"$SYNCTHING_DEVICE_NAME\",\"addresses\":[\"tcp://$SYNCTHING_DEVICE_IP\"],\"autoAcceptFolders\":true}"
                            SYNCTHING_RESET_SLEEP=1
                        else
                            if [[ $(echo $SYNCTHING_CONTAINER_CONFIG | jq -r ".devices[] | select(.deviceID==\"$SYNCTHING_DEVICE_ID\") | .addresses[]") != "tcp://$SYNCTHING_DEVICE_IP" ]]; then
                                syncthing_api PATCH $SYNCTHING_CONTAINER_IP config/devices/$SYNCTHING_DEVICE_ID \
                                    "{\"addresses\":[\"tcp://$SYNCTHING_DEVICE_IP\"]}"
                                SYNCTHING_RESET_SLEEP=1
                            fi
                            if [[ $(echo $SYNCTHING_CONTAINER_CONFIG | jq -r ".devices[] | select(.deviceID==\"$SYNCTHING_DEVICE_ID\") | .name") != $SYNCTHING_DEVICE_NAME ]]; then
                                syncthing_api PATCH $SYNCTHING_CONTAINER_IP config/devices/$SYNCTHING_DEVICE_ID \
                                    "{\"name\":\"$SYNCTHING_DEVICE_NAME\"}"
                                SYNCTHING_RESET_SLEEP=1
                            fi
                        fi
                        SYNCTHING_FOLDER_DEVICES="$SYNCTHING_FOLDER_DEVICES,{\"deviceID\":\"$SYNCTHING_DEVICE_ID\"}"
                    done
                    SYNCTHING_CONTAINER_CONFIG_FOLDERS=($(echo $SYNCTHING_CONTAINER_CONFIG | jq -r ".folders[].id"))
                    for SYNCTHING_FOLDER_ID in ${SYNCTHING_CONTAINER_CONFIG_FOLDERS[@]}; do
                        for SYNCTHING_DEVICE in ${SYNCTHING_DEVICES[@]}; do
                            SYNCTHING_DEVICE_ID=($(echo $SYNCTHING_DEVICE | awk -F: '{print $1}'))
                            if [[ -z $(echo $SYNCTHING_CONTAINER_CONFIG | jq -r ".folders[] | select(.id==\"$SYNCTHING_FOLDER_ID\") | .devices[].deviceID" | grep $SYNCTHING_DEVICE_ID) ]]; then
                                syncthing_api PATCH $SYNCTHING_CONTAINER_IP config/folders/$SYNCTHING_FOLDER_ID "{\"devices\":[$SYNCTHING_FOLDER_DEVICES]}"
                                SYNCTHING_RESET_SLEEP=1
                                break 1
                            fi
                        done
                    done
                fi
                # Restart if necessary
                if [[ $(syncthing_api GET $SYNCTHING_CONTAINER_IP system/config/insync | jq -r '.configInSync') != "true" ]]; then
                    syncthing_api POST $SYNCTHING_CONTAINER_IP system/restart
                    SYNCTHING_RESET_SLEEP=1
                fi
            done
        else
            if [ ${#SYNCTHING_CONTAINER_IP[@]} -eq 0 ]; then
                echo "SYNCTHING: WARNING: No nodes are in a Running state yet"
                sleep 15
            else
                echo "SYNCTHING: WARNING: Not enough nodes spooled (${#SYNCTHING_CONTAINER_IP[@]})"
                sleep $SYNCTHING_SLEEP
            fi
            SYNCTHING_RESET_SLEEP=1
        fi
        
        if [[ $SYNCTHING_RESET_SLEEP = 0 ]]; then 
            if [ $SYNCTHING_SLEEP -lt 300 ]; then
                (( SYNCTHING_SLEEP += 5 ))
            fi
        else
            SYNCTHING_SLEEP=0
        fi
        sleep $SYNCTHING_SLEEP
    done
}

resilio_curl() {
    curl -Ls \
        "http://$1:$RESILIO_API_PORT/gui/?$3" \
        -u $USER:$PASSWORD \
        -X POST \
        -H "Host: $1:$RESILIO_API_PORT" \
        -H "Referer: http://$1:$RESILIO_API_PORT/gui/" \
        -H "User-Agent: test bash binding" \
        -H "Cookie: GUID=$2" \
        -H 'X-Requested-With: XMLHttpRequest' \
        -H 'Accept-Language: en-US,en;q=0.5' \
        -H 'Accept: application/json, text/javascript, */*; q=0.01' \
        "${@:4}"
}
resilio_api() {
    RESILIO_API_PORT="${RESILIO_API_PORT:=8888}"
    now=$(date +%s)
    session=$(curl -Lsi \
                "http://$1:$RESILIO_API_PORT/gui/token.html?t=$now" \
                -u $USER:$PASSWORD \
                -X GET \
                -H "Host: $1:$RESILIO_API_PORT" \
                -H "Referer: http://$1:$RESILIO_API_PORT/gui/" \
                -H "User-Agent: test bash binding" \
            )
    cookie=$(echo "$session" | grep GUID | awk '{print $2}')
    url="token="$(echo "$session" | grep "<html>" | sed -e 's/[<>]/\n/g' | grep -iE '[a-z0-9_-]{10,}')
    url="$url&action=$2"
    for data in "${@:3}"; do
        key=$(echo $data | sed -n -e 's/\=.*$//p')
        if [ -z "$key" ]; then
            key=$data
        fi
        value=$(printf %s $(echo $data | sed -e 's/^[^\=]*\=//') | jq -sRr @uri)
        url=$url"&"$key"="$value
    done
    url="$url&t=$now"
    resilio_curl $1 $cookie $url
}
resilio_manager() {
    RESILIO_TASKS_DOMAIN="tasks."$STACK_NAME"_resilio."
    RESILIO_SLEEP=5
    while true; do
        RESILIO_UPDATES_APPLIED=0
        RESILIO_CONTAINER_IPS=($(dig $RESILIO_TASKS_DOMAIN +short))

        if [ ${#RESILIO_CONTAINER_IPS[@]} -gt 0 ] && [[ -z $RESLIO_CONTAINER_FIRST ]]; then
            RESLIO_CONTAINER_FIRST=${#RESILIO_CONTAINER_IPS[0]}
        fi
        
        if [ ${#RESILIO_CONTAINER_IPS[@]} -ge 3 ]; then 
            for RESILIO_CONTAINER_IP in ${RESILIO_CONTAINER_IPS[@]}; do
                RESILIO_CONTAINER_FQDN=$(dig @127.0.0.11 +noall +answer +short -x $RESILIO_CONTAINER_IP)
                RESILIO_CONTAINER_NODE_ID=$(echo $RESILIO_CONTAINER_FQDN | awk -F. '{print $2}')
                RESILIO_CONTAINER_ID=$(echo $RESILIO_CONTAINER_FQDN | awk -F. '{print $3}')
                
                # License agreement
                RESILIO_CONTAINER_LICENSEAGREED=$(resilio_api $RESILIO_CONTAINER_IP licenseagreed)
                if [ -z "$RESILIO_CONTAINER_LICENSEAGREED" ]; then
                    echo "RESILIO: WARNING: $RESILIO_CONTAINER_IP is not ready"
                    continue
                fi
                if [[ $(echo $RESILIO_CONTAINER_LICENSEAGREED | jq -r ".value.licenseagreed") = "false" ]]; then
                    echo "RESILIO: Agreeing to user terms"
                    RESILIO_CONTAINER_SETLICENSEAGREEMENT=$(resilio_api $RESILIO_CONTAINER_IP setlicenseagreed value=true)
                    if [[ $(echo $RESILIO_CONTAINER_SETLICENSEAGREEMENT | jq -r ".value.error") != "0" ]]; then
                        echo "RESILIO: ERROR: setlicenseagreed: "$(echo $RESILIO_CONTAINER_SETLICENSEAGREEMENT | jq -r ".error")
                    fi
                    RESILIO_UPDATES_APPLIED=1
                fi

                # User identity
                RESILIO_CONTAINER_USERIDENTITY=$(resilio_api $RESILIO_CONTAINER_IP useridentity)
                if [[ $(echo $RESILIO_CONTAINER_USERIDENTITY | jq -r ".value") = "{}" ]] || [[ $(echo $RESILIO_CONTAINER_USERIDENTITY | jq -r ".value.username") != $RESILIO_CONTAINER_NODE_ID ]]; then
                    echo "RESILIO: Setting user identity"
                    RESILIO_CONTAINER_SETUSERIDENTITY=$(resilio_api $RESILIO_CONTAINER_IP setuseridentity username=$RESILIO_CONTAINER_NODE_ID)
                    if [[ $(echo $RESILIO_CONTAINER_SETUSERIDENTITY | jq -r ".status") != "200" ]]; then
                        echo "RESILIO: ERROR: setuseridentity: "$(echo $RESILIO_CONTAINER_SETUSERIDENTITY | jq -r ".error")
                    fi
                    RESILIO_CONTAINER_USERIDENTITY=$(resilio_api $RESILIO_CONTAINER_IP useridentity)
                    RESILIO_UPDATES_APPLIED=1
                fi
                
                # Master folder set up
                RESILIO_CONTAINER_MASTERFOLDER=$(resilio_api $RESILIO_CONTAINER_IP getmasterfolder)
                if [[ -z $(echo $RESILIO_CONTAINER_MASTERFOLDER | jq -r ".value.secret") ]]; then
                    echo "RESILIO: INFO: $RESILIO_CONTAINER_NODE_ID | setmfsecret"
                    RESILIO_CONTAINER_MFSECRET=$(resilio_api $RESILIO_CONTAINER_IP setmfsecret)
                    echo "RESILIO: INFO: $RESILIO_CONTAINER_NODE_ID | sendstat"
                    RESILIO_CONTAINER_SENDSTAT=$(resilio_api $RESILIO_CONTAINER_IP sendstat eventname=syncMarketingNotification eventaction=rejected)
                    RESILIO_UPDATES_APPLIED=1
                fi

                # Get notifications
                RESILIO_CONTAINER_NOTIFICATIONS=$(resilio_api $RESILIO_CONTAINER_IP getnotifications)
                RESILIO_CONTAINER_NOTIFICATIONS_COUNT=$(echo $RESILIO_CONTAINER_NOTIFICATIONS | jq -r '.value | length')
                if [[ -z $RESILIO_CONTAINER_NOTIFICATIONS_COUNT ]]; then RESILIO_CONTAINER_NOTIFICATIONS_COUNT=0; fi
                if [ $RESILIO_CONTAINER_NOTIFICATIONS_COUNT -gt 0 ]; then
                    echo "RESILIO: Notifications found ($RESILIO_CONTAINER_NOTIFICATIONS_COUNT)"
                    i=0
                    while [[ $i -lt $RESILIO_CONTAINER_NOTIFICATIONS_COUNT ]]; do
                        case $(echo $RESILIO_CONTAINER_NOTIFICATIONS | jq -r ".value[$i].type") in
                            "STORAGE_LOCAL_marketing")
                                RESILIO_CONTAINER_DELETENOTIFICATIONS=$(resilio_api $RESILIO_CONTAINER_IP deletenotification id=$(echo $RESILIO_CONTAINER_NOTIFICATIONS | jq -r ".value[$i].id"))
                                echo "RESILIO: NOTIFICATION: $RESILIO_CONTAINER_NODE_ID | Deleted local marketing notification"
                            ;;
                            *)
                                echo "RESILIO: NOTIFICATION: $RESILIO_CONTAINER_NODE_ID | "$(echo $RESILIO_CONTAINER_NOTIFICATIONS | jq -r ".value[$i].data.text")
                            ;;
                        esac
                        (( i += 1 ))
                    done
                fi

                # Shares
                RESILIO_CONTAINER_SYNCFOLDERS=$(resilio_api $RESILIO_CONTAINER_IP getsyncfolders discovery=1)
                RESILIO_CONTAINER_SYNCFOLDERS_COUNT=$(echo $RESILIO_CONTAINER_SYNCFOLDERS | jq -r ".folders | length")
                if [[ -z $RESILIO_CONTAINER_SYNCFOLDERS_COUNT ]]; then RESILIO_CONTAINER_SYNCFOLDERS_COUNT=0; fi
                if [ $RESILIO_CONTAINER_SYNCFOLDERS_COUNT -eq 0 ]; then
                    if [[ -z $RESILIO_FOLDER_SECRET ]]; then
                        echo "RESILIO: INFO: $RESILIO_CONTAINER_NODE_ID | Creating first sync folder"
                        RESILIO_CONTAINER_ADDSYNCFOLDERS=$(
                            resilio_api $RESILIO_CONTAINER_IP addsyncfolder \
                                path=/mnt/sync/folders \
                                secret= \
                                selectivesync=false \
                            )
                        RESILIO_CONTAINER_SYNCFOLDERS=$(resilio_api $RESILIO_CONTAINER_IP getsyncfolders discovery=1)
                        RESILIO_FOLDER_SECRET=$(echo $RESILIO_CONTAINER_SYNCFOLDERS | jq -r ".folders[] | select(.path==\"/mnt/sync/folders\") | .secret")
                    else
                        echo "RESILIO: INFO: $RESILIO_CONTAINER_NODE_ID | Adding sync folder ($RESILIO_FOLDER_SECRET)"
                        RESILIO_CONTAINER_ADDSYNCFOLDERS=$(
                            resilio_api $RESILIO_CONTAINER_IP addsyncfolder \
                                path=/mnt/sync/folders \
                                secret=$RESILIO_FOLDER_SECRET \
                                force=true \
                                selectivesync=false \
                            )
                    fi
                    RESILIO_UPDATES_APPLIED=1
                fi
            done
        else
            echo "RESILIO: WARNING: Not enough nodes spooled (${#RESILIO_CONTAINER_IPS[@]})"
            sleep 5
            RESILIO_UPDATES_APPLIED=1
        fi
        if [[ $RESILIO_UPDATES_APPLIED == 0 ]]; then 
            sleep $RESILIO_SLEEP
            if [ $RESILIO_SLEEP -lt 300 ]; then
                (( RESILIO_SLEEP += 5 ))
            fi
        fi
    done
}

cockroach_get_status() {
    COCKROACH_STATUS_GET=$(curl http://$COCKROACH_HOSTNAME:$COCKROACH_HTTPPORT/health?ready=1 2>/dev/null)
    if [ ! -z "$COCKROACH_STATUS_GET" ]; then
        COCKROACH_STATUS_CODE=$(echo $COCKROACH_STATUS_GET | jq -r ".code" 2>/dev/null)
        COCKROACH_STATUS_ERROR=$(echo $COCKROACH_STATUS_GET | jq -r ".error" 2>/dev/null)
        COCKROACH_STATUS_MESSAGE=$(echo $COCKROACH_STATUS_GET | jq -r ".error" 2>/dev/null)
        if [ ! -z "$COCKROACH_STATUS_ERROR" ] && [ "$COCKROACH_STATUS_ERROR" != "null" ]; then
            echo "COCKROACH: ERROR: $COCKROACH_STATUS_ERROR"
        fi
        if [ "$COCKROACH_STATUS_ERROR" != "$COCKROACH_STATUS_MESSAGE" ]; then
            echo "COCKROACH: INFO: $COCKROACH_STATUS_MESSAGE"
        fi
    fi
}
prep_cockroach() {
    COCKROACH_HOSTNAME="${COCKROACH_HOSTNAME:=cockroach}"
    COCKROACH_HTTPPORT="${COCKROACH_HTTPPORT:=8080}"
    COCKROACH_SQLPORT="${COCKROACH_SQLPORT:=26257}"
    COCKROACH_SERVICE_NAME=$STACK_NAME"_"$COCKROACH_HOSTNAME
    STORAGE_CUSTER_COCKROACH_DIR=$STORAGE_CLUSTER_DIR/cockroach
    while [ ! -d $STORAGE_CUSTER_COCKROACH_DIR ]; do sleep 1; done
    if [ ! -f $STORAGE_CUSTER_COCKROACH_DIR/cockroach ]; then
        echo "COCKROACH: INFO: Downloading binaries"
        COCKROACH_VERSION=v20.2.4.linux-amd64
        curl -o cockroach-$COCKROACH_VERSION.tgz https://binaries.cockroachdb.com/cockroach-$COCKROACH_VERSION.tgz 2>/dev/null
        tar -xf cockroach-$COCKROACH_VERSION.tgz --strip=1 cockroach-$COCKROACH_VERSION/cockroach
        cp cockroach $STORAGE_CUSTER_COCKROACH_DIR/cockroach
    fi
    if [ ! -d $STORAGE_CUSTER_COCKROACH_DIR/certs ]; then
        echo "COCKROACH: INFO: Creating certificate dir: $STORAGE_CUSTER_COCKROACH_DIR/certs"
        mkdir -p $STORAGE_CUSTER_COCKROACH_DIR/certs
    fi
    if [ ! -f $STORAGE_CUSTER_COCKROACH_DIR/certs/ca.key ]; then
        echo "COCKROACH: INFO: Creating certificate authority"
        $STORAGE_CUSTER_COCKROACH_DIR/cockroach cert create-ca \
            --certs-dir=$STORAGE_CUSTER_COCKROACH_DIR/certs \
            --ca-key=$STORAGE_CUSTER_COCKROACH_DIR/certs/ca.key
        chmod 700 $STORAGE_CUSTER_COCKROACH_DIR/certs/ca.key
    fi
    if [ ! -f $STORAGE_CUSTER_COCKROACH_DIR/certs/client.root.key ]; then
        echo "COCKROACH: INFO: Creating root client certificate"
        $STORAGE_CUSTER_COCKROACH_DIR/cockroach cert create-client \
            root \
            --certs-dir=$STORAGE_CUSTER_COCKROACH_DIR/certs \
            --ca-key=$STORAGE_CUSTER_COCKROACH_DIR/certs/ca.key
        chmod 700 $STORAGE_CUSTER_COCKROACH_DIR/certs/client.root.key
    fi

    echo "COCKROACH: INFO: Waiting for nodes to be ready for initilization..."

    while [ "$COCKROACH_STATUS_CODE" = "" ] || [ "$COCKROACH_STATUS_ERROR" != "" ]; do
        INITIAL_CLUSTER_TOKEN=$COCKROACH_SERVICE_NAME

        echo "COCKROACH: INFO: building a seeds list for cluster"
        # IP of the service tasks
        typeset -i nbt
        nbt=0
        SECONDS=0
        echo "COCKROACH: INFO: waiting for the min seeds count ($MIN_SEEDS_COUNT)"
        while [[ $nbt -lt ${MIN_SEEDS_COUNT} ]]; do
            tips=$(dig +short tasks.$COCKROACH_SERVICE_NAME)
            nbt=$(echo $tips | wc -w)
            sleep 1
            (( SECONDS+=1 ))
            if [[ $SECONDS -gt 30 ]]; then break; fi
        done
        if [[ $nbt -lt ${MIN_SEEDS_COUNT} ]]; then
            echo "COCKROACH: WARNING: couldn't reach the min seeds count after $SECONDS sec, only $nbt tasks were found"
            continue
        fi
        for tip in $tips; do
            [[ -z "$INITIAL_CLUSTER" ]] && INITIAL_CLUSTER="$tip:26257" || INITIAL_CLUSTER="$INITIAL_CLUSTER,$tip:26257"
        done

        cockroach_get_status
        if [ "$COCKROACH_STATUS_ERROR" = "node is waiting for cluster initialization" ] && [ "$COCKROACH_INITIALIZATION_STATUS" != "Cluster successfully initialized" ]; then
            echo "COCKROACH: INFO: Initializing cluster..."
            COCKROACH_INITIALIZATION_STATUS=$( \
                                            $STORAGE_CUSTER_COCKROACH_DIR/cockroach init \
                                                --certs-dir=$STORAGE_CUSTER_COCKROACH_DIR/certs \
                                                --url=postgres://$COCKROACH_HOSTNAME:$COCKROACH_SQLPORT \
                                            )
        fi
        if [ "$COCKROACH_STATUS_ERROR" = "null" ]; then break; fi
    done
    COCKROACH_USERS=($($STORAGE_CUSTER_COCKROACH_DIR/cockroach sql \
        --certs-dir=$STORAGE_CUSTER_COCKROACH_DIR/certs \
        --url=postgres://$COCKROACH_HOSTNAME:$COCKROACH_SQLPORT \
        --format=csv \
        --execute='SHOW USERS;'))
    echo "COCKROACH: INFO: Checking user status..."
    for COCKROACH_USER_STATUS in "${COCKROACH_USERS[@]:1}"; do
        current_cockroach_user=$(echo $COCKROACH_USER_STATUS | awk -F, '{print $1}')
        if [ "$current_cockroach_user" = "$(cat /run/secrets/user | tr '[:upper:]' '[:lower:]')" ]; then 
            COCKROACH_USER_UPDATE=1;
        fi
    done
    if [ -z "$COCKROACH_USER_UPDATE" ]; then
        echo "COCKROACH: INFO: Adding user via secrets..."
        $STORAGE_CUSTER_COCKROACH_DIR/cockroach sql \
            --certs-dir=$STORAGE_CUSTER_COCKROACH_DIR/certs \
            --url=postgres://$COCKROACH_HOSTNAME:$COCKROACH_SQLPORT \
            --execute="CREATE USER $(cat /run/secrets/user) WITH PASSWORD '$(cat /run/secrets/password)';" \
            --execute="GRANT admin TO $(cat /run/secrets/user);"
    else
        echo "COCKROACH: INFO: Updating existing user via secrets..."
        $STORAGE_CUSTER_COCKROACH_DIR/cockroach sql \
            --certs-dir=$STORAGE_CUSTER_COCKROACH_DIR/certs \
            --url=postgres://$COCKROACH_HOSTNAME:$COCKROACH_SQLPORT \
            --execute="ALTER USER $(cat /run/secrets/user) WITH PASSWORD '$(cat /run/secrets/password)';" \
            --execute="GRANT admin TO $(cat /run/secrets/user);"
    fi
}

case $STORAGE_CLUSTER_SERVICE in
    resilio) resilio_manager & ;;
    syncthing) syncthing_manager & ;;
esac
prep_cockroach &


echo "------------------------------------------------------------"
echo
echo "GENERAL: USERNAME: $USER"
echo "GENERAL: PASSWORD: $PASSWORD"
echo "GENERAL: APIKEY  : $APIKEY"
echo
echo "------------------------------------------------------------"
tail -f /dev/null