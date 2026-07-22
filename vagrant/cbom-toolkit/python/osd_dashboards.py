#!/usr/bin/env python3
"""Create OpenSearch Dashboards visualizations and dashboards for CBOM data.

Creates 7 CBOM dashboards (incl. Cross-Protocol PQC Posture) in OpenSearch Dashboards.

Usage:
    python3 osd_dashboards.py
    python3 osd_dashboards.py --osd-url http://192.168.56.53:5601
    python3 osd_dashboards.py --delete
"""
import json
import sys
import argparse
import urllib.request
import urllib.error

INDEX_PATTERN = 'cbom'
CBOM_FILTER = 'cbom_scanner:*'


class OSDAPI:
    def __init__(self, base_url):
        self.base_url = base_url.rstrip('/')

    def request(self, method, path, body=None):
        url = f"{self.base_url}{path}"
        data = json.dumps(body).encode() if body else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header('osd-xsrf', 'true')
        req.add_header('Content-Type', 'application/json')
        try:
            resp = urllib.request.urlopen(req)
            if resp.status == 204:
                return None
            return json.loads(resp.read())
        except urllib.error.HTTPError as e:
            body_text = e.read().decode() if e.fp else ''
            if e.code == 409:
                return {'exists': True}
            print(f"  API error {e.code}: {body_text[:200]}", file=sys.stderr)
            raise

    def create_vis(self, vis_id, title, vis_state, search_source):
        # ?overwrite=true so re-runs update existing visualizations in place.
        # Without it, OSD returns 409 and changes never land on existing labs.
        return self.request('POST', f'/api/saved_objects/visualization/{vis_id}?overwrite=true', {
            'attributes': {
                'title': title,
                'visState': json.dumps(vis_state),
                'kibanaSavedObjectMeta': {
                    'searchSourceJSON': json.dumps(search_source),
                },
            },
            'references': [{
                'id': INDEX_PATTERN,
                'name': 'kibanaSavedObjectMeta.searchSourceJSON.index',
                'type': 'index-pattern',
            }],
        })

    def create_dashboard(self, dash_id, title, description, panels):
        return self.request('POST', f'/api/saved_objects/dashboard/{dash_id}?overwrite=true', {
            'attributes': {
                'title': title,
                'description': description,
                'panelsJSON': json.dumps(panels),
                'optionsJSON': json.dumps({'hidePanelTitles': False, 'useMargins': True}),
                'timeRestore': True,
                'timeTo': 'now',
                'timeFrom': 'now-7d',
            },
            'references': [
                {'id': p['panelRefName'].replace('panel_', 'cbom-vis-'),
                 'name': p['panelRefName'],
                 'type': 'visualization'}
                for p in panels
            ],
        })

    def delete_saved_object(self, obj_type, obj_id):
        try:
            self.request('DELETE', f'/api/saved_objects/{obj_type}/{obj_id}')
            return True
        except urllib.error.HTTPError:
            return False


def search_source(query=CBOM_FILTER):
    return {
        'query': {'query': query, 'language': 'lucene'},
        'filter': [],
        'indexRefName': 'kibanaSavedObjectMeta.searchSourceJSON.index',
    }


def panel(vis_num, x, y, w, h):
    """Dashboard panel reference."""
    return {
        'panelRefName': f'panel_{vis_num}',
        'gridData': {'x': x, 'y': y, 'w': w, 'h': h, 'i': str(vis_num)},
        'version': '2.15.0',
        'panelIndex': str(vis_num),
        'embeddableConfig': {},
    }


# ── Visualization builders ───────────────────────────────────────────

def pie_vis(title, field, size=10):
    return {
        'title': title,
        'type': 'pie',
        'aggs': [
            {'id': '1', 'type': 'count', 'schema': 'metric', 'params': {}},
            {'id': '2', 'type': 'terms', 'schema': 'segment', 'params': {
                'field': field, 'size': size, 'order': 'desc', 'orderBy': '1',
            }},
        ],
        'params': {
            'type': 'pie', 'addLegend': True, 'addTooltip': True,
            'isDonut': True, 'legendPosition': 'right',
            'labels': {'show': True, 'values': True, 'truncate': 100},
        },
    }


def bar_vis(title, field, size=15, stack=False):
    return {
        'title': title,
        'type': 'histogram',
        'aggs': [
            {'id': '1', 'type': 'count', 'schema': 'metric', 'params': {}},
            {'id': '2', 'type': 'terms', 'schema': 'segment', 'params': {
                'field': field, 'size': size, 'order': 'desc', 'orderBy': '1',
            }},
        ],
        'params': {
            'type': 'histogram', 'addLegend': True, 'addTooltip': True,
            'mode': 'stacked' if stack else 'normal',
            'categoryAxes': [{'id': 'CategoryAxis-1', 'type': 'category', 'position': 'bottom'}],
            'valueAxes': [{'id': 'ValueAxis-1', 'name': 'LeftAxis-1', 'type': 'value', 'position': 'left'}],
        },
    }


def stacked_bar_vis(title, bucket_field, stack_field, bucket_size=15, stack_size=5):
    return {
        'title': title,
        'type': 'histogram',
        'aggs': [
            {'id': '1', 'type': 'count', 'schema': 'metric', 'params': {}},
            {'id': '2', 'type': 'terms', 'schema': 'segment', 'params': {
                'field': bucket_field, 'size': bucket_size, 'order': 'desc', 'orderBy': '1',
            }},
            {'id': '3', 'type': 'terms', 'schema': 'group', 'params': {
                'field': stack_field, 'size': stack_size, 'order': 'desc', 'orderBy': '1',
            }},
        ],
        'params': {
            'type': 'histogram', 'addLegend': True, 'addTooltip': True,
            'mode': 'stacked',
            'categoryAxes': [{'id': 'CategoryAxis-1', 'type': 'category', 'position': 'bottom'}],
            'valueAxes': [{'id': 'ValueAxis-1', 'name': 'LeftAxis-1', 'type': 'value', 'position': 'left'}],
        },
    }


def table_vis(title, fields, sizes=None):
    """Multi-bucket data table."""
    if sizes is None:
        sizes = [20] * len(fields)
    aggs = [{'id': '1', 'type': 'count', 'schema': 'metric', 'params': {}}]
    for i, (field, size) in enumerate(zip(fields, sizes)):
        aggs.append({
            'id': str(i + 2), 'type': 'terms', 'schema': 'bucket', 'params': {
                'field': field, 'size': size, 'order': 'desc', 'orderBy': '1',
            },
        })
    return {
        'title': title,
        'type': 'table',
        'aggs': aggs,
        'params': {
            'perPage': 25, 'showPartialRows': False, 'showMetricsAtAllLevels': False,
            'sort': {'columnIndex': None, 'direction': None},
            'showTotal': True, 'totalFunc': 'sum',
        },
    }


def metric_vis(title, label='Count'):
    return {
        'title': title,
        'type': 'metric',
        'aggs': [
            {'id': '1', 'type': 'count', 'schema': 'metric', 'params': {
                'customLabel': label,
            }},
        ],
        'params': {
            'addLegend': False, 'addTooltip': True, 'type': 'metric',
            'metric': {'colorSchema': 'Green to Red', 'style': {'fontSize': 40}},
        },
    }


def area_vis(title, stack_field, stack_size=5):
    return {
        'title': title,
        'type': 'area',
        'aggs': [
            {'id': '1', 'type': 'count', 'schema': 'metric', 'params': {}},
            {'id': '2', 'type': 'date_histogram', 'schema': 'segment', 'params': {
                'field': '@timestamp', 'interval': 'auto',
            }},
            {'id': '3', 'type': 'terms', 'schema': 'group', 'params': {
                'field': stack_field, 'size': stack_size, 'order': 'desc', 'orderBy': '1',
            }},
        ],
        'params': {
            'type': 'area', 'addLegend': True, 'addTooltip': True,
            'mode': 'stacked',
            'categoryAxes': [{'id': 'CategoryAxis-1', 'type': 'category', 'position': 'bottom'}],
            'valueAxes': [{'id': 'ValueAxis-1', 'name': 'LeftAxis-1', 'type': 'value', 'position': 'left'}],
        },
    }


def heatmap_vis(title, row_field, col_field, row_size=15, col_size=15):
    return {
        'title': title,
        'type': 'heatmap',
        'aggs': [
            {'id': '1', 'type': 'count', 'schema': 'metric', 'params': {}},
            {'id': '2', 'type': 'terms', 'schema': 'segment', 'params': {
                'field': row_field, 'size': row_size, 'order': 'desc', 'orderBy': '1',
            }},
            {'id': '3', 'type': 'terms', 'schema': 'group', 'params': {
                'field': col_field, 'size': col_size, 'order': 'desc', 'orderBy': '1',
            }},
        ],
        'params': {
            'type': 'heatmap', 'addLegend': True, 'addTooltip': True,
            'colorSchema': 'Greens', 'enableHover': True,
        },
    }


# ── Dashboard 1: Crypto Posture Overview ─────────────────────────────

VIS_DEFS = {}

# Dashboard 1 visualizations
VIS_DEFS[1] = ('CBOM: PQC Status Overview', pie_vis('PQC Status', 'cbom_pqc_status', 5), CBOM_FILTER)
VIS_DEFS[2] = ('CBOM: Components per VM', bar_vis('Components per VM', 'cbom_vm', 15), CBOM_FILTER)
VIS_DEFS[3] = ('CBOM: Asset Type Breakdown', pie_vis('Asset Types', 'cbom_asset_type', 5), CBOM_FILTER)
VIS_DEFS[4] = ('CBOM: PQC Status by VM', stacked_bar_vis('PQC by VM', 'cbom_vm', 'cbom_pqc_status', 15, 5), CBOM_FILTER)
VIS_DEFS[5] = ('CBOM: Algorithm Distribution', pie_vis('Algorithms', 'cbom_name', 20), f'{CBOM_FILTER} AND cbom_asset_type:algorithm')
VIS_DEFS[6] = ('CBOM: Top Quantum-Vulnerable', table_vis('Vulnerable Components', ['cbom_name', 'cbom_vm'], [25, 15]), f'{CBOM_FILTER} AND cbom_pqc_status:quantum-vulnerable')
VIS_DEFS[7] = ('CBOM: Scanner Coverage', table_vis('Scanner x VM', ['cbom_scanner', 'cbom_vm'], [5, 15]), CBOM_FILTER)

# Dashboard 2: Certificate Lifecycle
VIS_DEFS[10] = ('CBOM: Certificates per VM', bar_vis('Certs per VM', 'cbom_vm', 15), f'{CBOM_FILTER} AND cbom_asset_type:certificate')
VIS_DEFS[11] = ('CBOM: Certificate Issuers', pie_vis('Issuers', 'cbom_issuer', 15), f'{CBOM_FILTER} AND cbom_asset_type:certificate')
VIS_DEFS[12] = ('CBOM: Certificate Subjects', table_vis('Subjects', ['cbom_subject', 'cbom_sig_algorithm'], [30, 10]), f'{CBOM_FILTER} AND cbom_asset_type:certificate AND _exists_:cbom_subject')
VIS_DEFS[13] = ('CBOM: Signature Algorithms', pie_vis('Sig Algorithms', 'cbom_sig_algorithm', 10), f'{CBOM_FILTER} AND cbom_asset_type:certificate AND _exists_:cbom_sig_algorithm')
VIS_DEFS[14] = ('CBOM: Key Types', pie_vis('Key Types', 'cbom_key_type', 5), f'{CBOM_FILTER} AND cbom_asset_type:related-crypto-material')
VIS_DEFS[15] = ('CBOM: Key Size Distribution', bar_vis('Key Sizes', 'cbom_name', 10), f'{CBOM_FILTER} AND cbom_asset_type:related-crypto-material')
VIS_DEFS[16] = ('CBOM: Issuer per VM', table_vis('Issuer x VM', ['cbom_vm', 'cbom_issuer'], [15, 10]), f'{CBOM_FILTER} AND cbom_asset_type:certificate')

# Dashboard 3: Drift Detection
VIS_DEFS[20] = ('CBOM: Events Over Time', area_vis('Events by Asset Type', 'cbom_asset_type', 5), CBOM_FILTER)
VIS_DEFS[21] = ('CBOM: Scan Activity', area_vis('Scans by Scanner', 'cbom_scanner', 5), CBOM_FILTER)
VIS_DEFS[22] = ('CBOM: Weak Crypto Findings', table_vis('Weak Crypto', ['cbom_vm', 'cbom_name'], [15, 20]), f'{CBOM_FILTER} AND cbom_pqc_status:weak-classical')
VIS_DEFS[23] = ('CBOM: Private Keys Detected', table_vis('Private Keys', ['cbom_vm', 'cbom_location'], [15, 20]), f'{CBOM_FILTER} AND cbom_key_type:private-key')
VIS_DEFS[24] = ('CBOM: Components by VM + Type', table_vis('VM x Type', ['cbom_vm', 'cbom_asset_type'], [15, 5]), CBOM_FILTER)

# Dashboard 4: PQC Readiness
VIS_DEFS[30] = ('CBOM: Lab PQC Scorecard', pie_vis('Lab PQC', 'cbom_pqc_status', 5), CBOM_FILTER)
VIS_DEFS[31] = ('CBOM: PQC per VM (Stacked)', stacked_bar_vis('PQC per VM', 'cbom_vm', 'cbom_pqc_status', 15, 5), CBOM_FILTER)
VIS_DEFS[32] = ('CBOM: Migration Targets', table_vis('Migration', ['cbom_name', 'cbom_asset_type'], [20, 5]), f'{CBOM_FILTER} AND cbom_pqc_status:quantum-vulnerable')
VIS_DEFS[33] = ('CBOM: Crypto Heatmap', heatmap_vis('VM x Algorithm', 'cbom_vm', 'cbom_name', 15, 15), f'{CBOM_FILTER} AND cbom_pqc_status:quantum-vulnerable')
VIS_DEFS[34] = ('CBOM: Quantum-Safe Components', table_vis('Safe', ['cbom_vm', 'cbom_name'], [15, 10]), f'{CBOM_FILTER} AND cbom_pqc_status:quantum-safe')
VIS_DEFS[35] = ('CBOM: Weak Classical Risk', table_vis('Weak Classical', ['cbom_vm', 'cbom_name'], [15, 10]), f'{CBOM_FILTER} AND cbom_pqc_status:weak-classical')
VIS_DEFS[36] = ('CBOM: Pure-PQC Endpoints', metric_vis('Pure-PQC', 'Pure-PQC Endpoints'), f'{CBOM_FILTER} AND cbom_pqc_only:true AND cbom_asset_type:certificate')
VIS_DEFS[37] = ('CBOM: Pure-PQC Endpoints Detail', table_vis('Pure-PQC Detail', ['cbom_vm', 'cbom_location', 'cbom_name'], [15, 25, 30]), f'{CBOM_FILTER} AND cbom_pqc_only:true')

# Dashboard 5 (NEW): Certificate Expiry & Health
VIS_DEFS[40] = ('CBOM: Total Certificates', metric_vis('Total Certs', 'Certificates'), f'{CBOM_FILTER} AND cbom_asset_type:certificate')
VIS_DEFS[41] = ('CBOM: Expired Certificates', metric_vis('Expired', 'Expired'), f'{CBOM_FILTER} AND cbom_asset_type:certificate AND cbom_days_to_expiry:<0')
VIS_DEFS[42] = ('CBOM: Expiring <30d', metric_vis('Expiring Soon', 'Expiring <30d'), f'{CBOM_FILTER} AND cbom_asset_type:certificate AND cbom_days_to_expiry:[0 TO 30]')
VIS_DEFS[43] = ('CBOM: Self-Signed Certs', metric_vis('Self-Signed', 'Self-Signed'), f'{CBOM_FILTER} AND cbom_asset_type:certificate AND cbom_is_root:true')
VIS_DEFS[44] = ('CBOM: Expiring Cert Details', table_vis('Expiring', ['cbom_subject', 'cbom_vm', 'cbom_issuer'], [30, 15, 10]), f'{CBOM_FILTER} AND cbom_asset_type:certificate AND cbom_days_to_expiry:[0 TO 90]')
VIS_DEFS[45] = ('CBOM: Expired Cert Details', table_vis('Expired', ['cbom_subject', 'cbom_vm', 'cbom_not_after'], [30, 15, 10]), f'{CBOM_FILTER} AND cbom_asset_type:certificate AND cbom_days_to_expiry:<0')
VIS_DEFS[46] = ('CBOM: Self-Signed Details', table_vis('Self-Signed', ['cbom_subject', 'cbom_vm', 'cbom_sig_algorithm'], [30, 15, 10]), f'{CBOM_FILTER} AND cbom_asset_type:certificate AND cbom_is_root:true')

# Dashboard 6 (NEW): VM Security Posture
VIS_DEFS[50] = ('CBOM: Total Components', metric_vis('Total', 'Total Components'), CBOM_FILTER)
VIS_DEFS[51] = ('CBOM: Quantum-Vulnerable Count', metric_vis('Vulnerable', 'Quantum-Vulnerable'), f'{CBOM_FILTER} AND cbom_pqc_status:quantum-vulnerable')
VIS_DEFS[52] = ('CBOM: Weak Classical Count', metric_vis('Weak', 'Weak Classical'), f'{CBOM_FILTER} AND cbom_pqc_status:weak-classical')
VIS_DEFS[53] = ('CBOM: VM Crypto Inventory', heatmap_vis('VM x Asset Type', 'cbom_vm', 'cbom_asset_type', 15, 5), CBOM_FILTER)
VIS_DEFS[54] = ('CBOM: VM Sig Algorithm Matrix', heatmap_vis('VM x Sig Alg', 'cbom_vm', 'cbom_sig_algorithm', 15, 10), f'{CBOM_FILTER} AND cbom_asset_type:certificate')
VIS_DEFS[55] = ('CBOM: Full Inventory Table', table_vis('Inventory', ['cbom_vm', 'cbom_asset_type', 'cbom_name'], [15, 5, 30]), CBOM_FILTER)

# ── Cross-protocol PQC posture (TLS + SSH + OpenPGP) ──
# Surfaces the three protocol families together so the demo dashboard
# tells the unified story instead of three separate scanner views.
VIS_DEFS[60] = ('CBOM: TLS PQC Endpoints',     metric_vis('TLS-PQC',     'TLS PQC Endpoints'),     f'{CBOM_FILTER} AND cbom_scanner:pqc-handshake AND cbom_pqc_only:true AND cbom_asset_type:certificate')
VIS_DEFS[61] = ('CBOM: SSH PQC KEX',           metric_vis('SSH-PQC',     'SSH PQC KEX'),           f'{CBOM_FILTER} AND cbom_scanner:pqc-ssh AND cbom_pqc_status:quantum-safe')
VIS_DEFS[62] = ('CBOM: OpenPGP PQC Subkeys',   metric_vis('OpenPGP-PQC', 'OpenPGP PQC Subkeys'),   f'{CBOM_FILTER} AND cbom_scanner:pqc-openpgp AND cbom_pqc_status:quantum-safe')
VIS_DEFS[63] = ('CBOM: Cross-Protocol PQC by Scanner', stacked_bar_vis('PQC by Scanner', 'cbom_scanner', 'cbom_pqc_status', 6, 4), CBOM_FILTER)
VIS_DEFS[64] = ('CBOM: PQC-Safe by VM (Cross-Protocol)', stacked_bar_vis('PQC-Safe by VM', 'cbom_vm', 'cbom_scanner', 15, 6), f'{CBOM_FILTER} AND cbom_pqc_status:quantum-safe')
VIS_DEFS[65] = ('CBOM: PQC Components Detail',
                table_vis('PQC Components', ['cbom_scanner', 'cbom_vm', 'cbom_name', 'cbom_asset_type'], [15, 15, 30, 8]),
                f'{CBOM_FILTER} AND cbom_pqc_status:quantum-safe')
# Cloudflare edge PQC posture — populated by the cloudflare_pqc role on scanner1.
# Three-level bucketing: endpoint x stack x pqc_status. Filtered to the CF probe
# documents only (cbom_source:cloudflare-pqc) so it doesn't mix with internal
# lab scanners on the same dashboard.
VIS_DEFS[66] = ('CBOM: Cloudflare Edge PQC Posture',
                table_vis('Cloudflare Edge PQC Posture',
                          ['cf_endpoint_name', 'cf_stack', 'cbom_pqc_status'],
                          [10, 10, 5]),
                'cbom_source:cloudflare-pqc')

# ── Dashboard definitions ────────────────────────────────────────────

DASHBOARDS = {
    'cbom-dash-1': {
        'title': 'CBOM: Crypto Posture Overview',
        'description': 'Algorithm distribution, PQC status, and scanner coverage across the lab.',
        'panels': [
            panel(1, 0, 0, 24, 15),     # PQC status pie (top center, big)
            panel(2, 24, 0, 24, 15),     # Components per VM
            panel(3, 0, 15, 12, 12),     # Asset type pie
            panel(5, 12, 15, 12, 12),    # Algorithm distribution pie
            panel(4, 24, 15, 24, 12),    # PQC by VM stacked bar
            panel(6, 0, 27, 24, 15),     # Vulnerable table
            panel(7, 24, 27, 24, 15),    # Scanner coverage table
        ],
    },
    'cbom-dash-2': {
        'title': 'CBOM: Certificate Lifecycle',
        'description': 'Certificate inventory, issuer breakdown, signature algorithms, and key material.',
        'panels': [
            panel(10, 0, 0, 24, 15),     # Certs per VM
            panel(11, 24, 0, 24, 15),    # Issuers pie
            panel(13, 0, 15, 16, 12),    # Sig algorithms pie
            panel(14, 16, 15, 16, 12),   # Key types pie
            panel(15, 32, 15, 16, 12),   # Key size bar
            panel(12, 0, 27, 24, 15),    # Subjects table
            panel(16, 24, 27, 24, 15),   # Issuer per VM table
        ],
    },
    'cbom-dash-3': {
        'title': 'CBOM: Drift Detection',
        'description': 'Track changes, weak crypto, private keys, and scan coverage over time.',
        'panels': [
            panel(20, 0, 0, 48, 12),     # Events over time (full width)
            panel(21, 0, 12, 48, 12),    # Scan activity (full width)
            panel(22, 0, 24, 24, 15),    # Weak crypto table
            panel(23, 24, 24, 24, 15),   # Private keys table
            panel(24, 0, 39, 48, 15),    # Components by VM+type (full width)
        ],
    },
    'cbom-dash-4': {
        'title': 'CBOM: PQC Readiness Scorecard',
        'description': 'Post-quantum cryptography readiness — vulnerable, safe, and weak crypto per VM. Includes pure-PQC endpoint highlight (the demo headline asset).',
        'panels': [
            panel(36, 0, 0, 12, 8),      # Pure-PQC count (metric, top-left)
            panel(30, 12, 0, 18, 15),    # Lab PQC pie
            panel(31, 30, 0, 18, 15),    # PQC per VM stacked
            panel(37, 0, 8, 12, 7),      # Pure-PQC detail table (under the metric)
            panel(32, 0, 15, 24, 15),    # Migration targets table
            panel(33, 24, 15, 24, 15),   # Heatmap
            panel(34, 0, 30, 24, 12),    # Quantum-safe table
            panel(35, 24, 30, 24, 12),   # Weak classical table
        ],
    },
    'cbom-dash-5': {
        'title': 'CBOM: Certificate Expiry & Health',
        'description': 'Expired, expiring, and self-signed certificate monitoring.',
        'panels': [
            panel(40, 0, 0, 12, 8),      # Total certs metric
            panel(41, 12, 0, 12, 8),     # Expired metric
            panel(42, 24, 0, 12, 8),     # Expiring <30d metric
            panel(43, 36, 0, 12, 8),     # Self-signed metric
            panel(44, 0, 8, 24, 15),     # Expiring details table
            panel(45, 24, 8, 24, 15),    # Expired details table
            panel(46, 0, 23, 48, 15),    # Self-signed details (full width)
        ],
    },
    'cbom-dash-6': {
        'title': 'CBOM: VM Security Posture',
        'description': 'Per-VM crypto inventory heatmaps and summary metrics.',
        'panels': [
            panel(50, 0, 0, 16, 8),      # Total components metric
            panel(51, 16, 0, 16, 8),     # Vulnerable metric
            panel(52, 32, 0, 16, 8),     # Weak metric
            panel(53, 0, 8, 24, 15),     # VM x asset type heatmap
            panel(54, 24, 8, 24, 15),    # VM x sig algorithm heatmap
            panel(55, 0, 23, 48, 18),    # Full inventory table (full width)
        ],
    },
    # The unified cross-protocol PQC story. Top row: three big-number
    # metrics so a demo audience sees "we have PQC across three protocol
    # families" in one glance. Below: drilldowns by scanner + by VM, and
    # a flat list of every PQC-safe component the lab knows about.
    'cbom-dash-7': {
        'title': 'CBOM: Cross-Protocol PQC Posture',
        'description': 'Unified TLS + SSH + OpenPGP view. Each metric counts PQC components from one scanner. The drilldowns show which VMs participate and what specific components are PQC-safe.',
        'panels': [
            panel(60, 0, 0, 16, 8),      # TLS PQC Endpoints metric
            panel(61, 16, 0, 16, 8),     # SSH PQC KEX metric
            panel(62, 32, 0, 16, 8),     # OpenPGP PQC Subkeys metric
            panel(63, 0, 8, 24, 15),     # PQC by Scanner stacked bar
            panel(64, 24, 8, 24, 15),    # PQC-Safe by VM stacked
            panel(65, 0, 23, 48, 18),    # Full PQC components table
            panel(66, 0, 41, 48, 8),     # Cloudflare edge PQC posture table
        ],
    },
}


def main():
    parser = argparse.ArgumentParser(description="Create OSD CBOM dashboards")
    parser.add_argument('--osd-url', default='http://192.168.56.53:5601',
                        help='OpenSearch Dashboards URL')
    parser.add_argument('--delete', action='store_true',
                        help='Delete existing CBOM visualizations and dashboards')
    args = parser.parse_args()

    api = OSDAPI(args.osd_url)

    if args.delete:
        deleted = 0
        for vis_num in VIS_DEFS:
            if api.delete_saved_object('visualization', f'cbom-vis-{vis_num}'):
                deleted += 1
        for dash_id in DASHBOARDS:
            if api.delete_saved_object('dashboard', dash_id):
                deleted += 1
        print(f"  Deleted {deleted} saved objects")
        return

    # Create visualizations
    print("  Creating visualizations...")
    for vis_num, (title, vis_state, query) in VIS_DEFS.items():
        vis_id = f'cbom-vis-{vis_num}'
        result = api.create_vis(vis_id, title, vis_state, search_source(query))
        status = 'exists' if result and result.get('exists') else 'created'
        print(f"    {status}: {title}")

    # Create dashboards
    print("\n  Creating dashboards...")
    for dash_id, dash_def in DASHBOARDS.items():
        result = api.create_dashboard(
            dash_id, dash_def['title'], dash_def['description'], dash_def['panels'],
        )
        status = 'exists' if result and result.get('exists') else 'created'
        print(f"    {status}: {dash_def['title']}")

    print(f"\n  Open: {args.osd_url}/app/dashboards")


if __name__ == '__main__':
    main()
