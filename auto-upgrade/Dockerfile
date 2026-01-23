FROM docker:cli

RUN apk add --no-cache bash curl jq coreutils util-linux

COPY auto-upgrade.sh /auto-upgrade/auto-upgrade.sh
RUN chmod +x /auto-upgrade/auto-upgrade.sh

ENTRYPOINT ["/auto-upgrade/auto-upgrade.sh"]
