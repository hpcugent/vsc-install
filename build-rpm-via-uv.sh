#!/bin/bash

set -e

PACKAGE_NAME=$(uv run --with tomli python -c "
import tomli
with open('pyproject.toml', 'rb') as f:
    data = tomli.load(f)
    print(data['project']['name'])
")

VERSION=$(uv run --with tomli python -c "
import tomli
with open('pyproject.toml', 'rb') as f:
    data = tomli.load(f)
    print(data['project']['version'])
")

echo "Building ${PACKAGE_NAME} ${VERSION}..."

# Build wheel
uv build

# Create staging directory
STAGING_DIR=$(mktemp -d)
trap "rm -rf ${STAGING_DIR}" EXIT

INSTALL_DIR="${STAGING_DIR}/usr/lib/python3.9/site-packages"
mkdir -p "${INSTALL_DIR}"

# Use uv pip to install the wheel to the staging directory
uv pip install --target "${INSTALL_DIR}" --no-deps dist/*.whl

# Build RPM dependencies
RPM_DEPS=$(uv run extract_rpm_deps.py)

# Build RPM from directory
eval "fpm -s dir -t rpm \
    --name 'python3-${PACKAGE_NAME}' \
    --version '${VERSION}' \
    --architecture noarch \
    --depends python3.9 \
    ${RPM_DEPS} \
    --rpm-dist el9 \
    -C ${STAGING_DIR} \
    usr/lib/python3.9/site-packages"

echo "RPM built successfully!"
ls -lh python3-${PACKAGE_NAME}*.rpm
