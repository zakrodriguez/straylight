#!/usr/bin/env python3
"""Create OpenSearch Alerting monitors for CBOM crypto observatory.

Creates five alert monitors:
  1. CRITICAL (sev 1): Private Key Detected
  2. CRITICAL (sev 1): Weak Algorithm Detected
  3. HIGH     (sev 2): Small RSA Key Detected
  4. MEDIUM   (sev 3): Certificate Expiring Soon
  5. LOW      (sev 4): New Scan Results

Usage:
    python3 cbom_alerts.py
    python3 cbom_alerts.py --opensearch-url https://192.168.56.53:9244
    python3 cbom_alerts.py --delete --opensearch-url https://192.168.56.53:9244
"""
import base64
import json
import os
import ssl
import sys
import argparse
import urllib.request
import urllib.error


# ── OpenSearch Alerting API helpers ──────────────────────────────────────

# Module-level auth/TLS state populated by main() so opensearch_request keeps
# its signature simple for the existing call sites.
_AUTH_HEADER = None
_SSL_CTX = None


def _set_auth_context(username, password, ca_cert, insecure):
    """Configure HTTP Basic Auth header + TLS context for subsequent calls.

    OpenSearch is fronted by observe_tls nginx on :9244 (TLS + Basic Auth).
    """
    global _AUTH_HEADER, _SSL_CTX
    if username and password:
        token = base64.b64encode(f"{username}:{password}".encode()).decode()
        _AUTH_HEADER = f"Basic {token}"
    _SSL_CTX = ssl.create_default_context(cafile=ca_cert) if ca_cert else ssl.create_default_context()
    if insecure:
        _SSL_CTX.check_hostname = False
        _SSL_CTX.verify_mode = ssl.CERT_NONE


def opensearch_request(base_url, method, path, body=None):
    """Execute an HTTP request against the OpenSearch API.

    Args:
        base_url: OpenSearch base URL (e.g. https://192.168.56.53:9244).
        method: HTTP method (GET, POST, PUT, DELETE).
        path: API path (e.g. /_plugins/_alerting/monitors).
        body: Optional dict to send as JSON body.

    Returns:
        Parsed JSON response as dict, or None for empty responses.
    """
    url = f"{base_url.rstrip('/')}{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header('Content-Type', 'application/json')
    if _AUTH_HEADER:
        req.add_header('Authorization', _AUTH_HEADER)
    try:
        if url.lower().startswith('https://'):
            resp = urllib.request.urlopen(req, context=_SSL_CTX)
        else:
            resp = urllib.request.urlopen(req)
        raw = resp.read()
        if not raw:
            return None
        return json.loads(raw)
    except urllib.error.HTTPError as e:
        body_text = e.read().decode() if e.fp else ''
        print(f"  API error {e.code}: {body_text[:200]}", file=sys.stderr)
        raise


# ── Monitor definitions ─────────────────────────────────────────────────

MONITORS = [
    {
        'name': 'CBOM: Private Key Detected',
        'severity': '1',
        'query': 'cbom_key_type:private-key',
    },
    {
        'name': 'CBOM: Weak Algorithm Detected',
        'severity': '1',
        'query': 'cbom_pqc_status:weak-classical',
    },
    {
        'name': 'CBOM: Small RSA Key Detected',
        'severity': '2',
        'query': 'cbom_name:RSA AND cbom_key_size:<2048',
    },
    {
        'name': 'CBOM: Certificate Expiring Soon',
        'severity': '3',
        'query': '_exists_:cbom_days_to_expiry AND cbom_days_to_expiry:[0 TO 30]',
    },
    {
        'name': 'CBOM: New Scan Results',
        'severity': '4',
        'query': 'cbom_event_type:scan',
    },
]


def build_monitor_payload(name, severity, query):
    """Build an OpenSearch Alerting monitor creation payload.

    Args:
        name: Monitor display name.
        severity: Trigger severity level (1=critical, 4=low).
        query: Lucene query string to match CBOM documents.

    Returns:
        Complete monitor dict ready for POST to the Alerting API.
    """
    return {
        'type': 'monitor',
        'name': name,
        'monitor_type': 'query_level_monitor',
        'enabled': True,
        'schedule': {
            'period': {
                'interval': 5,
                'unit': 'MINUTES',
            },
        },
        'inputs': [{
            'search': {
                'indices': ['cbom'],
                'query': {
                    'size': 0,
                    'query': {
                        'bool': {
                            'filter': [
                                {
                                    'range': {
                                        '@timestamp': {
                                            'from': '{{period_end}}||-5m',
                                            'to': '{{period_end}}',
                                            'include_lower': True,
                                            'include_upper': True,
                                        },
                                    },
                                },
                                {
                                    'query_string': {
                                        'query': query,
                                    },
                                },
                            ],
                        },
                    },
                },
            },
        }],
        'triggers': [{
            'query_level_trigger': {
                'name': 'trigger',
                'severity': severity,
                'condition': {
                    'script': {
                        'source': 'ctx.results[0].hits.total.value > 0',
                        'lang': 'painless',
                    },
                },
                'actions': [],
            },
        }],
    }


# ── CRUD operations ─────────────────────────────────────────────────────

def get_existing_cbom_monitors(base_url):
    """Return a mapping of name -> monitor_id for existing CBOM monitors.

    Searches all monitors and filters to those whose name starts with 'CBOM:'.
    """
    body = {'query': {'match_all': {}}, 'size': 100}
    try:
        result = opensearch_request(
            base_url, 'POST',
            '/_plugins/_alerting/monitors/_search', body,
        )
    except urllib.error.HTTPError as e:
        if e.code == 404:
            # Alerting index doesn't exist yet (first run)
            return {}
        raise
    existing = {}
    for hit in result.get('hits', {}).get('hits', []):
        monitor = hit.get('_source', {})
        name = monitor.get('name', '')
        if name.startswith('CBOM:'):
            existing[name] = hit['_id']
    return existing


def create_monitors(base_url):
    """Create all CBOM alerting monitors, skipping any that already exist."""
    existing = get_existing_cbom_monitors(base_url)

    print("  Creating CBOM alerting monitors...")
    created = 0
    skipped = 0

    for monitor_def in MONITORS:
        name = monitor_def['name']

        if name in existing:
            print(f"  \033[33mExists:\033[0m {name}  ({existing[name]})")
            skipped += 1
            continue

        payload = build_monitor_payload(
            name=name,
            severity=monitor_def['severity'],
            query=monitor_def['query'],
        )

        try:
            result = opensearch_request(
                base_url, 'POST',
                '/_plugins/_alerting/monitors', payload,
            )
            monitor_id = result['_id']
            print(f"  \033[32mCreated:\033[0m {name}  ({monitor_id})")
            created += 1
        except Exception as e:
            print(f"  \033[31mFailed:\033[0m {name}  ({e})")

    print(f"\n  Done: {created} created, {skipped} skipped (already exist)")


def delete_monitors(base_url):
    """Delete all alerting monitors whose name starts with 'CBOM:'."""
    existing = get_existing_cbom_monitors(base_url)

    if not existing:
        print("  No CBOM alerting monitors found")
        return

    deleted = 0
    for name, monitor_id in existing.items():
        try:
            opensearch_request(
                base_url, 'DELETE',
                f'/_plugins/_alerting/monitors/{monitor_id}',
            )
            print(f"  \033[32mDeleted:\033[0m {name}  ({monitor_id})")
            deleted += 1
        except Exception as e:
            print(f"  \033[31mFailed:\033[0m {name}  ({e})")

    print(f"\n  Deleted {deleted} CBOM alerting monitor(s)")


# ── Entry point ──────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Create OpenSearch Alerting monitors for CBOM crypto observatory"
    )
    parser.add_argument(
        '--opensearch-url',
        default=os.environ.get('OPENSEARCH_URL', 'https://192.168.56.53:9244'),
        help='OpenSearch base URL (TLS-fronted on :9244 via observe_tls nginx)',
    )
    parser.add_argument(
        '--username', default=os.environ.get('OPENSEARCH_USER', 'beats'),
        help='HTTP Basic Auth user (default: beats, or $OPENSEARCH_USER)',
    )
    parser.add_argument(
        '--password', default=os.environ.get('OPENSEARCH_PASS'),
        help='HTTP Basic Auth password ($OPENSEARCH_PASS; required for https://)',
    )
    parser.add_argument(
        '--ca-cert', default=os.environ.get('OPENSEARCH_CA'),
        help='Path to PEM CA bundle for TLS verification',
    )
    parser.add_argument(
        '--insecure', action='store_true',
        help='Skip TLS verification (lab-only)',
    )
    parser.add_argument(
        '--delete', action='store_true',
        help='Delete all existing CBOM alerting monitors',
    )
    args = parser.parse_args()

    _set_auth_context(args.username, args.password, args.ca_cert, args.insecure)

    if args.delete:
        delete_monitors(args.opensearch_url)
        return

    create_monitors(args.opensearch_url)


if __name__ == '__main__':
    main()
