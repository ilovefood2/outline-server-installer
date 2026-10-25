FROM node@sha256:06d7adf3e0ef61a13f1d28682726366f97a15aa1888c934d3ecec86c33918b53

RUN rm -rf /usr/local/lib/node_modules /opt/yarn-v1.22.22 \
    && rm -f /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack /usr/local/bin/yarn /usr/local/bin/yarnpkg \
    && apk add --no-cache --upgrade coreutils curl setpriv ca-certificates \
    && addgroup -S -g 31999 outline \
    && adduser -S -D -u 31999 -G outline -h /opt/outline outline \
    && mkdir -p /opt/outline/persisted-state /var/lib/libmaxminddb \
    && chown -R 31999:31999 /opt/outline /var/lib/libmaxminddb

WORKDIR /opt/outline-server
COPY app/ app/
COPY bin/ bin/
COPY licenses/ licenses/
COPY package.json package-lock.json ./
COPY update_mmdb.sh /scripts/update_mmdb.sh
RUN /scripts/update_mmdb.sh \
    && mv /var/lib/libmaxminddb geodb \
    && mkdir /var/lib/libmaxminddb
COPY entrypoint.sh /entrypoint.sh
COPY start.sh /start.sh
COPY health.js /health.js

ENV NODE_ENV=production SB_STATE_DIR=/opt/outline/persisted-state \
    SB_ACCESS_KEY_PREFIX=POST%20 SB_ALLOW_PRIVATE_TARGETS=true \
    NODE_OPTIONS=--max-old-space-size=256
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD ["/entrypoint.sh", "--health"]
ENTRYPOINT ["/entrypoint.sh"]
