#!/usr/bin/env bash
set -euo pipefail

docker pull passivelogic/swift-tools:latest
docker run --rm -i -v $PWD:/project passivelogic/swift-tools:latest bash -c "swiftformat.sh .; swiftlint.sh"
