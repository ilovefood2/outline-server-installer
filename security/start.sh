#!/bin/sh
set -eu
umask 077
: "${SB_PUBLIC_IP:?Set the existing public hostname before starting}"
cp geodb/*.mmdb /var/lib/libmaxminddb/
(
    while sleep 604800; do
        /scripts/update_mmdb.sh >/dev/null 2>&1 || true
    done
) &
exec node app/main.js
