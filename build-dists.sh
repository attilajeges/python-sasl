#!/bin/bash
# Copyright 2015 Cloudera Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -x

GIT_VERSION_TAG="$1"
GITHUB_ACCOUNT="${2:-cloudera}"

if [ -z "$GIT_VERSION_TAG" ]; then
  echo "Usage $0 <git-version-tag> [<git-account-name>]";
  exit 1
fi

DISTS_DIR=pip-dists
DOCKER_IMAGE='quay.io/pypa/manylinux1_x86_64'

docker pull "$DOCKER_IMAGE"
docker container run -t --rm  -v "$(pwd)/io:/io" "$DOCKER_IMAGE" \
  "/io/manylinux/build.sh" \
    "/io/${DISTS_DIR}" \
		"$GIT_VERSION_TAG" \
		"$GITHUB_ACCOUNT"

RETVAL="$?"
if [[ "$RETVAL" != "0" ]]; then
	echo "Failed with $RETVAL"
else
	echo "Succeeded"
fi
exit $RETVAL
