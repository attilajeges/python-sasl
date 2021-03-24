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

set -eu -o pipefail
set -x

# Called inside the manylinux1 image
echo "Started $0 $@"

DISTS_DIR="$1"
GIT_TAG="$2"
GITHUB_ACCOUNT="${3:-cloudera}"

PKG_NAME=sasl
GIT_REPO="python-sasl"
GIT_URL="https://github.com/${GITHUB_ACCOUNT}/${GIT_REPO}.git"

BDIST_TMP_DIR="${DISTS_DIR}/tmp"
WHEELHOUSE_DIR="${DISTS_DIR}/wheelhouse"
SDIST_DIR="${DISTS_DIR}/sdist"

SYSTEM_REQUIREMENTS=(cyrus-sasl cyrus-sasl-devel)
PIP_REQUIREMENTS=(six)
BUILD_REQUIREMENTS=(devtoolset-2-gcc devtoolset-2-gcc-c++)

prepare_system() {
  # Install system packages required by our library
  yum install -y "${SYSTEM_REQUIREMENTS[@]}"

  cd /tmp
  git clone -b "$GIT_TAG" --single-branch "$GIT_URL"
  cd "$GIT_REPO"
  echo "Build directory: $(pwd)"

  # Clean up dists directory
  rm -rf "$DISTS_DIR" || true
  mkdir -p "$DISTS_DIR"

  echo "Python versions found: $(cd /opt/python && echo cp* | sed -e 's|[^ ]*-||g')"
  g++ --version
}

is_cpython2() {
  local pyver_abi="$1"
  [[ "$pyver_abi" =~ ^cp2 ]]
}

build_wheels() {
  # Compile wheels for all python versions
  for PYDIR in /opt/python/*; do
    # Do not build wheels from cpython2
    local pyver_abi="$(basename $PYDIR)"
    if is_cpython2 "$pyver_abi"; then continue; fi

    # Install build requirements
    "${PYDIR}/bin/python" -m pip install "${PIP_REQUIREMENTS[@]}"

    echo "Building wheel with $($PYBIN/python -V)"
    "${PYDIR}/bin/python" setup.py bdist_wheel -d "$BDIST_TMP_DIR"
  done
}

repair_wheels() {
  # Bundle external shared libraries into the wheels
  for whl in "${BDIST_TMP_DIR}/"*.whl; do
    auditwheel repair $whl -w "$WHEELHOUSE_DIR"
  done
}

show_wheels() {
  ls -l "${WHEELHOUSE_DIR}/"*.whl
}

build_sdist() {
  for PYBIN in /opt/python/*/bin; do
    echo "Building sdist with $(${PYBIN}/python -V)"
    "${PYBIN}/python" setup.py sdist -d "$SDIST_DIR"
    break
  done
}

show_sdist() {
  ls -l "$SDIST_DIR"
}

smoke_test() {
  cat <<EOF >/tmp/smoke.py
import sasl
sasl_client = sasl.Client()
sasl_client.setAttr('service', 'myservice')
sasl_client.setAttr('host', 'myhost')
sasl_client.init()
sasl_client.encode('1234567890')
EOF

  cd /tmp

  # Install sdist with different python versions and run smoke test script.
  local sdistfn="$(ls ${SDIST_DIR}/${PKG_NAME}-*.tar.gz)"
  for PYBIN in /opt/python/*/bin/; do
    "${PYBIN}/pip" install --upgrade --force-reinstall --no-binary "$PKG_NAME" "$sdistfn"
    "${PYBIN}/python" /tmp/smoke.py
  done

  # Install wheels with different python versions.
  # Required system packages are included in wheels.
  # System requirements can be removed as the wheels already include them.
  yum remove -y "${SYSTEM_REQUIREMENTS[@]}"
  yum remove -y "${BUILD_REQUIREMENTS[@]}"
  for PYDIR in /opt/python/*; do
    # Haven't built wheels for cpython2, skip cpython2 testing
    local pyver_abi="$(basename $PYDIR)"
    if is_cpython2 "$pyver_abi"; then continue; fi

    local whlfn="$(ls ${WHEELHOUSE_DIR}/${PKG_NAME}-*-${pyver_abi}-*.whl)"
    "${PYDIR}/bin/pip" install --upgrade --force-reinstall --only-binary "$PKG_NAME" "$whlfn"
    "${PYDIR}/bin/python" /tmp/smoke.py
  done
}

prepare_system

build_wheels
repair_wheels
show_wheels

build_sdist
show_sdist

smoke_test
