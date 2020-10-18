#!/usr/bin/env bash
#shellcheck shell=bash

pushd ./helper_container > /dev/null 2>&1 || exit 1

REPO=mikenye
IMAGE=adsb_docker_install_helper
PLATFORMS="linux/386,linux/amd64,linux/arm/v7,linux/arm64"

docker context use x86_64
export DOCKER_CLI_EXPERIMENTAL="enabled"
docker buildx use homecluster

# Build & push latest
docker buildx build --no-cache -t "${REPO}/${IMAGE}:latest" --compress --push --platform "${PLATFORMS}" .

popd  > /dev/null 2>&1 || exit 1
