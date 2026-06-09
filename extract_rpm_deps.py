#!/usr/bin/env python3
# /// script
# dependencies = ["tomli"]
# ///
# extract_rpm_deps.py

import tomli
import re
import sys
from pathlib import Path

def parse_requirement(req_str):
    """
    Parse a PEP 508 requirement string.
    Examples:
        'vsc-base' -> ('vsc-base', '')
        'vsc-base>=3.0.1' -> ('vsc-base', '>=3.0.1')
        'vsc-base >= 3.0.1, <4.0' -> ('vsc-base', '>= 3.0.1, <4.0')
    """
    # Simple regex for name and version specifiers
    match = re.match(r'^([a-zA-Z0-9._-]+)\s*(.*)$', req_str.strip())
    if match:
        name = match.group(1)
        version_spec = match.group(2).strip()
        return name, version_spec
    return req_str, ''

def python_to_rpm_name(python_pkg):
    """Convert Python package name to RPM package name."""
    return f"python3-{python_pkg}"

def main():
    pyproject_path = Path("pyproject.toml")
    if not pyproject_path.exists():
        print("Error: pyproject.toml not found", file=sys.stderr)
        sys.exit(1)
    
    with open(pyproject_path, "rb") as f:
        data = tomli.load(f)
    
    dependencies = data.get("project", {}).get("dependencies", [])
    
    for dep in dependencies:
        pkg_name, version_spec = parse_requirement(dep)
        rpm_name = python_to_rpm_name(pkg_name)
        
        if version_spec:
            # RPM uses different syntax, but >= and > work the same
            # You might need to adjust this for complex version specs
            print(f"-d '{rpm_name} {version_spec}'")
        else:
            print(f"-d '{rpm_name}'")

if __name__ == "__main__":
    main()
