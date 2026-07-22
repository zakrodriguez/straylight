#!/usr/bin/env python3
"""Generate OpenSearch mappings from the single source-of-truth CBOM envelope.

The cbom_* / cf_* / adcs_* field vocabulary used to live in four hand-synced
copies (cbom_ingest.py, the opensearch_stack index PUT, osd_dashboards.py, and
the classifier). The envelope schema collapses the OpenSearch-facing half of that onto one
schema file: cbom-toolkit/schema/cbom_envelope.json. This generator emits the
mapping body for the `cbom` index straight from that schema so the index and
the ingest producer can never drift on field types again.

Usage:
    # Print the cbom index mapping body (mappings.properties) as JSON
    python3 gen_opensearch_mapping.py --kind index-mapping

    # Print the full create-index body ({"mappings": {...}})
    python3 gen_opensearch_mapping.py --kind create-index

    # Point at a non-default schema file
    python3 gen_opensearch_mapping.py --schema /path/cbom_envelope.json
"""
import argparse
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SCHEMA = os.path.join(_HERE, '..', 'schema', 'cbom_envelope.json')


def load_schema(path):
    with open(path) as f:
        return json.load(f)


def build_properties(schema):
    """Map each declared field to an OpenSearch property block."""
    props = {}
    for name, spec in schema.get('fields', {}).items():
        prop = {'type': spec['type']}
        props[name] = prop
    return props


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--schema', default=DEFAULT_SCHEMA,
                        help='Path to cbom_envelope.json (default: bundled schema)')
    parser.add_argument('--kind', default='create-index',
                        choices=['index-mapping', 'create-index'],
                        help='index-mapping = mappings.properties only; '
                             'create-index = {"mappings": {"properties": {...}}}')
    args = parser.parse_args()

    schema = load_schema(args.schema)
    properties = build_properties(schema)

    if args.kind == 'index-mapping':
        out = {'properties': properties}
    else:
        out = {'mappings': {'properties': properties}}

    json.dump(out, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write('\n')


if __name__ == '__main__':
    main()
