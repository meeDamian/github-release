FROM alpine:3.10

RUN apk update \
    && apk add file curl jq

COPY entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]
