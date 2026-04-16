#!/bin/bash -x

set -eo pipefail

export ARTIFACT_IMAGE='wechaty/wechaty:artifact'
export IMAGE_REPO="${IMAGE_REPO:-wechaty/wechaty}"
export ONBUILD_REPO="${ONBUILD_REPO:-wechaty/onbuild}"

function dockerBuild () {
  platform=$1     # `all` for all platforms, `linux/amd64`, `linux/arm64`, etc.
  tag=${2}        # set the tag for building image
  deploy=$3       # `true` for deploy, not set for local build

  # Shellcheck - https://github.com/koalaman/shellcheck/wiki/SC2086
  options=('--rm')
  [ -n "$NO_CACHE" ] && options+=('--no-cache')

  [ "$platform" == "all" ]  && platform='linux/amd64,linux/arm64,linux/arm/v7'
  [ -n "$deploy" ]          && options+=('--push')

  cat <<_CMD_
    docker buildx build \
    "${options[@]}" \
    --platform "$platform" \
    --tag "wechaty/wechaty:$tag" \
    .
_CMD_

  docker buildx build \
    "${options[@]}" \
    --platform "$platform" \
    --tag "$IMAGE_REPO:$tag" \
    .
}

function deployOnbuild () {
  export tag=$1

  echo "Building & Deploying '$ONBUILD_REPO:$tag' based on '$IMAGE_REPO:$tag'"

  sed "s#FROM wechaty/wechaty:next#FROM $IMAGE_REPO:$tag#" < Dockerfile.onbuild \
    | docker buildx build \
      --platform 'linux/amd64,linux/arm64,linux/arm/v7' \
      --tag "$ONBUILD_REPO:$tag" \
      --push \
      -
}

function main () {
declare -i ret=0

  case "$1" in
    build | '')
      docker build \
        --rm \
        --tag "$ARTIFACT_IMAGE" \
        .

      ret=$?
      ;;

    test)
      echo "Testing the docker image behaviors to make sure it works as expected..."
      echo "bats tests/"
      IMAGE_NAME="$ARTIFACT_IMAGE" bats tests/

      echo
      echo
      echo docker run -i --rm -v /dev/shm:/dev/shm "$ARTIFACT_IMAGE" test
      exec docker run -i --rm -v /dev/shm:/dev/shm "$ARTIFACT_IMAGE" test
      ret=$?
      ;;

    deploy)
      version=$(npx pkg-jq -r .version)
      majorVer=$(echo "$version" | cut -d. -f1)
      minorVer=$(echo "$version" | cut -d. -f2)
      versionTag="${majorVer}.${minorVer}"

      dockerBuild all "$versionTag" deploy
      deployOnbuild "$versionTag"

      if npx --package @chatie/semver semver-is-prod "$version"; then
        dockerBuild all latest deploy
        deployOnbuild latest
      else
        dockerBuild all next deploy
        deployOnbuild next
      fi
      ;;

    clean)
      docker ps -a | grep Exited | awk '{print $1}' | xargs docker rm || true
      docker images | grep none | awk '{print $3}' | xargs docker rmi
      ;;

    *)
      echo docker run -ti --rm -v /dev/shm:/dev/shm "$ARTIFACT_IMAGE" "$@"
      exec docker run -ti --rm -v /dev/shm:/dev/shm "$ARTIFACT_IMAGE" "$@"
      ;;
  esac

  [ "$ret" -ne 0 ] && {
    echo "ERROR: exec return $ret ???"
  }

  return $ret
}

main "$@"
