FROM debian:stable-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bc \
        ca-certificates \
        curl \
        expect \
        git \
        jq \
        python3-pip \
        python3-setuptools \
        python3-wheel \
        && \
    pip3 install yq && \
    apt-get clean -y && \
    rm -rf /var/lib/apt/lists/*
