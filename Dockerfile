FROM alpine:3.11

RUN apk add --no-cache file curl jq

COPY entrypoint.sh /

ENTRYPOINT [ "/entrypoint.sh" ]
