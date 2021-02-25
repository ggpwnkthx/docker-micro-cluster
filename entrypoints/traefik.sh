#!/bin/sh
if [ -f /letsencrypt/acme.json ]; then
    chmod 600 /letsencrypt/acme.json
fi
/entrypoint.sh $@