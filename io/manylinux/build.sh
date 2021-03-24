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
  local pydir=""
  for pydir in /opt/python/*; do
    # Do not build wheels from cpython2
    local pyver_abi="$(basename $pydir)"
    if is_cpython2 "$pyver_abi"; then continue; fi

    echo "Building wheel with $($PYBIN/python -V)"
    "${pydir}/bin/python" setup.py bdist_wheel -d "$BDIST_TMP_DIR"
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

set_up_virt_env() {
  local pydir="$1"
  local pyver_abi="$(basename $pydir)"

  if is_cpython2 "$pyver_abi"; then
    "${pydir}/bin/python" -m virtualenv sasl_test_env
  else
    "${pydir}/bin/python" -m venv sasl_test_env
  fi

  # set -eu must be disabled temporarily for activating the env.
  set +e +u
  source sasl_test_env/bin/activate
  set -eu
}

tear_down_virt_env() {
  # set -eu must be disabled temporarily for deactivating the env.
  set +e +u
  deactivate
  set -eu

  rm -rf sasl_test_env
}

sanity_check() {
  cat <<EOF >/tmp/sanity_check.py
import sasl
from sys import exit

sasl_client = sasl.Client()
if not sasl_client.setAttr('service', 'myservice'): exit(1)
if not sasl_client.setAttr('host', 'myhost'): exit(1)
if not sasl_client.init(): exit(1)
ok, enc = sasl_client.encode('1234567890')
if not ok or enc != b'1234567890': exit(1)
EOF

  cd /tmp

  # Install sdist with different python versions and run sanity_check.
  local sdistfn="$(ls ${SDIST_DIR}/${PKG_NAME}-*.tar.gz)"
  local pydir=""
  for pydir in /opt/python/*; do
    set_up_virt_env "$pydir"
    pip install --upgrade --force-reinstall --no-binary "$PKG_NAME" "$sdistfn"
    python /tmp/sanity_check.py
    tear_down_virt_env
  done

  # Install wheels with different python versions and run sanity_check.
  # System requirements can be removed as the wheels should already include them.
  yum remove -y "${SYSTEM_REQUIREMENTS[@]}"
  yum remove -y "${BUILD_REQUIREMENTS[@]}"

  for pydir in /opt/python/*; do
    # Haven't built wheels for cpython2, skip cpython2 testing
    local pyver_abi="$(basename $pydir)"
    if is_cpython2 "$pyver_abi"; then continue; fi

    local whlfn="$(ls ${WHEELHOUSE_DIR}/${PKG_NAME}-*-${pyver_abi}-*.whl)"

    set_up_virt_env "$pydir"
    pip install --upgrade --force-reinstall --only-binary "$PKG_NAME" "$whlfn"
    python /tmp/sanity_check.py
    tear_down_virt_env
  done
}

prepare_system

build_wheels
repair_wheels
show_wheels

build_sdist
show_sdist

sanity_check
