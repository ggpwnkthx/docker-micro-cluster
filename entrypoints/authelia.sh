#!/bin/sh
if [ -z "$DOMAIN" ]; then
  echo "No root domain set."
  exit 1
fi
if [ ! -f /configuration.yml ]; then
    cat <<EOF > /configuration.yml
###############################################################
#                   Authelia configuration                    #
###############################################################

host: 0.0.0.0
port: 9091
log_level: debug
jwt_secret: $(base64 /dev/urandom | tr -d "/+" | head -c32)
default_redirection_url: https://login.$DOMAIN

totp:
  issuer: authelia.com

authentication_backend:
  file:
    path: /config/users.yml
    password:
      algorithm: argon2id
      iterations: 1
      salt_length: 16
      parallelism: 8
      memory: 128

access_control:
  default_policy: deny
  rules:
    - domain: "*.$DOMAIN"
      policy: one_factor

session:
  name: authelia_session
  secret: $(base64 /dev/urandom | tr -d "/+" | head -c32)
  expiration: 3600 # 1 hour
  inactivity: 300 # 5 minutes
  domain: $DOMAIN

regulation:
  max_retries: 3
  find_time: 120
  ban_time: 300

storage:
  local:
    path: /config/preferences.sqlite3

notifier:
  filesystem:
    filename: /config/notifications
EOF
fi

if [ ! -f /config/users.yml ]; then
    PASSWORD=$(authelia hash-password $(cat /run/secrets/password) -i 1 -m 128 -p 8 -k 32 -l 16  | awk '{print $3}')
    cat <<EOF > /config/users.yml
users:
  $(cat /run/secrets/user):
    password: $PASSWORD
    displayname: Administrator
    email: ""
    groups:
    - admins
    - dev
EOF
fi

if [ ! -f /config/notifications ]; then
    touch /config/notifications
fi

/usr/local/bin/entrypoint.sh --config /configuration.yml $@