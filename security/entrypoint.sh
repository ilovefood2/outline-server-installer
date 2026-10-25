#!/bin/sh
set -eu
if [ "${1:-}" = --health ] && [ "$#" -eq 1 ]; then
    set -- node /health.js
elif [ "$#" -eq 0 ]; then
    set -- /start.sh
else
    exit 2
fi
# Drop the startup-only identity capabilities before any network service runs.
exec setpriv --reuid=31999 --regid=31999 --clear-groups \
    --inh-caps=-all,+net_bind_service --ambient-caps=-all,+net_bind_service \
    --bounding-set=-all,+net_bind_service --no-new-privs "$@"
