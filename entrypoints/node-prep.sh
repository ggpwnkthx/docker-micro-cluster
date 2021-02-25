#!/bin/bash

# Set directory paths
STACK_DIR="${STACK_DIR:=/srv/default}"
STORAGE_CLUSTER_DIR="${STORAGE_CLUSTER_DIR:=$STACK_DIR/cluster}"
STORAGE_LOCAL_DIR="${STORAGE_LOCAL_DIR:=$STACK_DIR/local}"

STORAGE_CLUSTER_SERVICE="${STORAGE_CLUSTER_SERVICE:=syncthing}"

STORAGE_CLUSTER_NEEDED=(authelia cockroach couchdb letsencrypt)
STORAGE_LOCAL_NEEDED=(syncthing cockroach couchdb)
DIRS=()

for name in ${STORAGE_CLUSTER_NEEDED[@]}; do
    declare "STORAGE_CLUSTER_${name^^}_DIR=$STORAGE_CLUSTER_DIR/$name"
    DIRS+=($STORAGE_CLUSTER_DIR/$name)
done
for name in ${STORAGE_LOCAL_NEEDED[@]}; do
    declare "STORAGE_LOCAL_${name^^}_DIR=$STORAGE_LOCAL_DIR/$name"
    DIRS+=($STORAGE_LOCAL_DIR/$name)
done

for d in ${DIRS[@]}; do
    if [ ! -d $d ]; then
        echo "GENERAL: INFO: Creating directory: $d"
        mkdir -p $d
    fi
done