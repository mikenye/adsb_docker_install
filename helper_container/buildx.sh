#!/usr/bin/env sh
#shellcheck shell=sh

REPO=mikenye
IMAGE=adsb_docker_install_helper
PLATFORMS="linux/386,linux/amd64,linux/arm/v6,linux/arm/v7,linux/arm64"

docker context use x86_64
export DOCKER_CLI_EXPERIMENTAL="enabled"
docker buildx use homecluster

# Build & push latest
docker buildx build --no-cache -t "${REPO}/${IMAGE}:latest" --compress --push --platform "${PLATFORMS}" .
