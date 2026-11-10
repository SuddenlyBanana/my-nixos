"""Structural checks for strictly substituted YAML; never applies resources."""

import ipaddress
import re
import sys

import yaml


def validate(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "cidr" and isinstance(child, str):
                ipaddress.ip_network(child)
            if key == "image" and isinstance(child, str) and "@" in child:
                if not re.search(r"@sha256:[0-9a-f]{64}$", child):
                    raise ValueError("Invalid pinned image digest")
            validate(child)
    elif isinstance(value, list):
        for child in value:
            validate(child)
    elif isinstance(value, str):
        if "REPLACE_WITH" in value or re.search(r"\$\{[^}]+\}", value):
            raise ValueError("Unresolved deployment placeholder")


documents = [value for value in yaml.safe_load_all(sys.stdin) if value is not None]
for document in documents:
    if not all(key in document for key in ("apiVersion", "kind", "metadata")):
        raise ValueError("Not a Kubernetes resource")
    validate(document)
print(f"Validated {len(documents)} rendered resources (structural checks only)")
