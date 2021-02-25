#!/bin/sh
set -eu
[[ -d ${HOME}/config ]] || mkdir -p ${HOME}/config
[[ -f ${HOME}/config/config.xml ]] || /bin/syncthing -generate="${HOME}/config"
chown -R ${PUID} ${HOME} && chgrp -R ${PGID} ${HOME}
sed -i "s/<apikey>.*<\/apikey>/<apikey>$(cat /run/secrets/apikey)<\/apikey>/" ${HOME}/config/config.xml
sed -i "s/<globalAnnounceServer>.*<\/globalAnnounceServer>/<globalAnnounceServer>http\:\/\/syncthing-discovery\:8443\/\?insecure\&amp;noannounce<\/globalAnnounceServer>/" ${HOME}/config/config.xml
sed -i "s/<urAccepted>.*<\/urAccepted>/<urAccepted>-1<\/urAccepted>/" ${HOME}/config/config.xml
sed -i "s/<urSeen>.*<\/urSeen>/<urSeen>3<\/urSeen>/" ${HOME}/config/config.xml
sed -i "s/<unackedNotificationID>.*<\/unackedNotificationID>/<unackedNotificationID><\/unackedNotificationID>/" ${HOME}/config/config.xml
/bin/syncthing -home ${HOME}/config "$@"