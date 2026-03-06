#!/bin/bash

set -e

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

PYTHON_VER=$(uv run --python ${PYTHON_VERSION} --no-project python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")

if [ -z "$PYTHON_VER" ]; then
    echo "ERROR: Could not determine Python version from ${PYTHON_VERSION}"
    exit 1
fi

PACKAGE_NAME=$(uv run --python ${PYTHON_VERSION} --no-project --isolated --with tomli python -c "
import tomli
with open('pyproject.toml', 'rb') as f:
    data = tomli.load(f)
    print(data['project']['name'])
")

VERSION=$(uv run -- python ${PYTHON_VERSION} --no-project --isolated --with tomli python -c "
import tomli
with open('pyproject.toml', 'rb') as f:
    data = tomli.load(f)
    print(data['project']['version'])
")

# Build iteration string if --gittag is specified
ITERATION_FLAG=""
if [ "$USE_GITTAG" = true ]; then
    if git rev-parse --git-dir > /dev/null 2>&1; then
        GITTAG=$(git log --format=%ct.%h -1 2>/dev/null || echo "0.unknown")
        ITERATION_FLAG="--iteration 1.${GITTAG}"
        echo "Building ${PACKAGE_NAME} ${VERSION}-1.${GITTAG}..."
    else
        echo "Warning: --gittag specified but not in a git repository"
        echo "Building ${PACKAGE_NAME} ${VERSION}..."
    fi
else
    echo "Building ${PACKAGE_NAME} ${VERSION}..."
fi

echo "Building ${PACKAGE_NAME} ${VERSION}..."

# Build wheel
uv build --python ${PYTHON_VERSION}

# Create staging directory
STAGING_DIR=$(mktemp -d)
trap "rm -rf ${STAGING_DIR}" EXIT

INSTALL_DIR="${STAGING_DIR}/usr/lib/python3.9/site-packages"
BIN_DIR="${STAGING_DIR}/usr/bin"
mkdir -p "${INSTALL_DIR}"
mkdir -p "${BIN_DIR}"

# Use uv pip to install the wheel to the staging directory
uv pip install --python ${PYTHON_VERSION} --target "${INSTALL_DIR}" --no-deps dist/*.whl

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
    sys.argv[0] = re.sub(r'(-script\.pyw|\.exe)?$', '', sys.argv[0])
    sys.exit(${func}())
EOF
            chmod +x "${BIN_DIR}/${script_name}"
            echo "  Created: ${script_name} -> ${module}:${func}"
        fi
    done <<< "$ENTRY_POINTS"
fi


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
