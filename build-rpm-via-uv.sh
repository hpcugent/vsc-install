#!/bin/bash
# Copyright 2026-2026 Ghent University
#
# This file is part of vsc-install
# originally created by the HPC team of Ghent University (http://ugent.be/hpc/en),
# with support of Ghent University (http://ugent.be/hpc),
# the Flemish Supercomputer Centre (VSC) (https://www.vscentrum.be),
# the Flemish Research Foundation (FWO) (http://www.fwo.be/en)
# and the Department of Economy, Science and Innovation (EWI) (http://www.ewi-vlaanderen.be/en).
#
# https://github.ugent.be/hpcugent/clusterbuildrpm-server
#
# clusterbuildrpm-server is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation v2.
#
# clusterbuildrpm-server is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with clusterbuildrpm-server.  If not, see <http://www.gnu.org/licenses/>.
#
#
set -e

# Default values
DEFAULT_NAME=""
DEFAULT_RELEASE="1"
DEFAULT_RHEL="el9"
DEFAULT_VERSION=""
USE_GITTAG=false
PYTHON_VERSION="python3.9"

while [[ $# -gt 0 ]]; do
    case $1 in
        --gittag)
            USE_GITTAG=true
            shift
            ;;
        --name=*)
            DEFAULT_NAME="${1#*=}"
            shift
            ;;
        --version=*)
            DEFAULT_VERSION="${1#*=}"
            shift
            ;;
        --release=*)
            DEFAULT_RELEASE="${1#*=}"
            shift
            ;;
        --rhel=*)
            DEFAULT_RHEL="${1#*=}"
            shift
            ;;
        --python=*)
            PYTHON_VERSION="${1#*=}"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--gittag] [--name=<name>] [--version=<version>] [--python=<python>]"
            exit 1
            ;;
    esac
done

PYTHON_VER=$(uv run --python "${PYTHON_VERSION}" --no-project python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")

if [ -z "$PYTHON_VER" ]; then
    echo "ERROR: Could not determine Python version from ${PYTHON_VERSION}"
    exit 1
fi

PACKAGE_NAME=$(uv run --python "${PYTHON_VERSION}" --no-project --isolated --with tomli python -c "
import tomli
with open('pyproject.toml', 'rb') as f:
    data = tomli.load(f)
    print(data['project']['name'])
")

# Use DEFAULT_NAME if no name found in pyproject.toml
if [ -z "$PACKAGE_NAME" ]; then
    PACKAGE_NAME="${DEFAULT_NAME}"
fi

# No name == no build
if [ -z "$PACKAGE_NAME" ]; then
    echo "ERROR: No package name found in pyproject.toml and no --name provided" >&2
    exit 1
fi

VERSION=$(uv run --python "${PYTHON_VERSION}" --no-project --isolated --with tomli python -c "
import tomli
with open('pyproject.toml', 'rb') as f:
    data = tomli.load(f)
    print(data['project']['version'])
")

# Use DEFAULT_VERSION if no version found in pyproject.toml
if [ -z "$VERSION" ]; then
    VERSION="${DEFAULT_VERSION}"
fi

# No version == no build
if [ -z "$VERSION" ]; then
    echo "ERROR: No version found in pyproject.toml and no --version provided" >&2
    exit 1
fi

ITERATION_FLAG=""
if [ "$USE_GITTAG" = true ]; then
    # Use git tag for iteration
    if git rev-parse --git-dir > /dev/null 2>&1; then
        GITTAG=$(git log --format=%ct.%h -1 2>/dev/null || echo "0.unknown")
        ITERATION_FLAG="--iteration ${DEFAULT_RELEASE}.${GITTAG}"
        echo "Building ${PACKAGE_NAME} ${VERSION}-${DEFAULT_RELEASE}.${GITTAG}..."
    else
        echo "Warning: --gittag specified but not in a git repository"
        ITERATION_FLAG="--iteration ${DEFAULT_RELEASE}"
        echo "Building ${PACKAGE_NAME} ${VERSION}-${DEFAULT_RELEASE}..."
    fi
else
    # No gittag, just use release number
    ITERATION_FLAG="--iteration ${DEFAULT_RELEASE}"
    echo "Building ${PACKAGE_NAME} ${VERSION}-${DEFAULT_RELEASE}..."
fi


# Build wheel
uv build --python "${PYTHON_VERSION}"

# Create staging directory
STAGING_DIR=$(mktemp -d)

# Cleanup function
cleanup() {
    if [ -n "${STAGING_DIR}" ] && [ -d "${STAGING_DIR}" ]; then
        rm -rf "${STAGING_DIR}"
    fi
}
trap cleanup EXIT

SITE_PACKAGES_PATH="usr/lib/python${PYTHON_VER}/site-packages"

INSTALL_DIR="${STAGING_DIR}/usr/lib/python${PYTHON_VER}/site-packages"
BIN_DIR="${STAGING_DIR}/usr/bin"
mkdir -p "${INSTALL_DIR}"
mkdir -p "${BIN_DIR}"

# Use uv pip to install the wheel to the staging directory
uv pip install --python "${PYTHON_VERSION}" --target "${INSTALL_DIR}" --no-deps dist/*.whl

find "${STAGING_DIR}" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "${STAGING_DIR}" -name "*.lock" -delete

# Create entry point scripts from pyproject.toml
ENTRY_POINTS=$(uv run --no-project  --isolated --with tomli python -c "
import tomli
with open('pyproject.toml', 'rb') as f:
    data = tomli.load(f)
    scripts = data.get('project', {}).get('scripts', {})
    for name, entry in scripts.items():
        print(f'{name}:{entry}')
" 2>/dev/null || true)

if [ -n "$ENTRY_POINTS" ]; then
    echo "Creating entry point scripts..."
    while IFS=: read -r script_name entry_point; do
        if [ -n "$script_name" ]; then
            module_func="${entry_point}"
            module="${module_func%:*}"
            func="${module_func#*:}"

            cat > "${BIN_DIR}/${script_name}" <<EOF
#!/usr/bin/python3.9
# -*- coding: utf-8 -*-
import re
import sys
from ${module} import ${func}
if __name__ == '__main__':
    sys.exit(${func}())
EOF
            chmod +x "${BIN_DIR}/${script_name}"
            echo "  Created: ${script_name} -> ${module}:${func}"
        fi
    done <<< "$ENTRY_POINTS"
fi


# Build RPM dependencies
RPM_DEPS=$(uv run extract_rpm_deps.py)

# Determine what to include in RPM
FPM_PATHS="${SITE_PACKAGES_PATH}"
bin_contents=$(ls -A "${BIN_DIR}" 2>/dev/null)
if [ -n "$bin_contents" ]; then
    FPM_PATHS="${FPM_PATHS} usr/bin"
fi


# Build RPM from directory
eval "fpm -s dir -t rpm \
    --name 'python3-${PACKAGE_NAME}' \
    --version '${VERSION}' \
    ${ITERATION_FLAG} \
    --architecture noarch \
    --depends python${PYTHON_VER} \
    ${RPM_DEPS} \
    --rpm-dist ${DEFAULT_RHEL} \
    -C ${STAGING_DIR} \
    ${FPM_PATHS}"

echo "RPM built successfully."
ls -lh python3-"${PACKAGE_NAME}"*.rpm
