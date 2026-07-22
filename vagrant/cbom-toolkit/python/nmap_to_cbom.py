#!/usr/bin/env python3
"""Convert nmap XML output (with ssl-cert/ssl-enum-ciphers scripts) to CycloneDX CBOM 1.6.

nmap 7.x with OpenSSL 3.0 reports PQC signature algorithms as raw OIDs
(e.g. "1.3.6.1.4.1.2.267.12.6.5") since its NSE scripts lack PQC OID
mappings.  This parser resolves those OIDs to human-readable names so the
downstream cbom_score.py classifier can match them as quantum-safe.

Optionally merges supplemental openssl s_client key-exchange probe results
(--kex-json) to capture PQC hybrid KEX groups that nmap cannot negotiate.

Usage:
    python3 nmap_to_cbom.py nmap-results.xml > cbom-nmap.json
    python3 nmap_to_cbom.py nmap-results.xml -o cbom-nmap.json
    python3 nmap_to_cbom.py nmap-results.xml --kex-json kex-probe.json -o cbom-nmap.json
"""
import json
import sys
import uuid
import argparse
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

# ── PQC OID → human-readable name ────────────────────────────────────────────
# NIST FIPS 204 (ML-DSA), FIPS 205 (SLH-DSA), FIPS 203 (ML-KEM)
# Composite / hybrid OIDs from draft-ounsworth-pq-composite-sigs and IETF drafts

PQC_SIG_OIDS = {
    # ML-DSA (FIPS 204) — pure
    '2.16.840.1.101.3.4.3.17': 'ML-DSA-44',
    '2.16.840.1.101.3.4.3.18': 'ML-DSA-65',
    '2.16.840.1.101.3.4.3.19': 'ML-DSA-87',
    # SLH-DSA (FIPS 205) — SHA-2 variants
    '2.16.840.1.101.3.4.3.20': 'SLH-DSA-SHA2-128s',
    '2.16.840.1.101.3.4.3.21': 'SLH-DSA-SHA2-128f',
    '2.16.840.1.101.3.4.3.22': 'SLH-DSA-SHA2-192s',
    '2.16.840.1.101.3.4.3.23': 'SLH-DSA-SHA2-192f',
    '2.16.840.1.101.3.4.3.24': 'SLH-DSA-SHA2-256s',
    '2.16.840.1.101.3.4.3.25': 'SLH-DSA-SHA2-256f',
    # SLH-DSA (FIPS 205) — SHAKE variants
    '2.16.840.1.101.3.4.3.26': 'SLH-DSA-SHAKE-128s',
    '2.16.840.1.101.3.4.3.27': 'SLH-DSA-SHAKE-128f',
    '2.16.840.1.101.3.4.3.28': 'SLH-DSA-SHAKE-192s',
    '2.16.840.1.101.3.4.3.29': 'SLH-DSA-SHAKE-192f',
    '2.16.840.1.101.3.4.3.30': 'SLH-DSA-SHAKE-256s',
    '2.16.840.1.101.3.4.3.31': 'SLH-DSA-SHAKE-256f',
}

PQC_KEY_OIDS = {
    # ML-KEM (FIPS 203)
    '2.16.840.1.101.3.4.4.1': 'ML-KEM-512',
    '2.16.840.1.101.3.4.4.2': 'ML-KEM-768',
    '2.16.840.1.101.3.4.4.3': 'ML-KEM-1024',
    # ML-DSA public keys
    '2.16.840.1.101.3.4.3.17': 'ML-DSA-44',
    '2.16.840.1.101.3.4.3.18': 'ML-DSA-65',
    '2.16.840.1.101.3.4.3.19': 'ML-DSA-87',
}

ALL_PQC_OIDS = {**PQC_SIG_OIDS, **PQC_KEY_OIDS}


def resolve_pqc_oid(value, oid_map=None):
    """Translate a raw OID to a human-readable PQC name if it matches."""
    if oid_map is None:
        oid_map = ALL_PQC_OIDS
    if not value:
        return value
    # Direct OID match
    if value in oid_map:
        return oid_map[value]
    # OID embedded in a longer string (e.g. "1.3.6.1.4.1.2.267.12.6.5 with ...")
    for oid, name in oid_map.items():
        if oid in value:
            return name
    return value


def parse_nmap_xml(xml_path):
    """Parse nmap XML and extract TLS certificate and cipher info."""
    tree = ET.parse(xml_path)
    root = tree.getroot()
    findings = []

    for host in root.findall('.//host'):
        # Get IP address
        addr_el = host.find("address[@addrtype='ipv4']")
        if addr_el is None:
            continue
        ip = addr_el.get('addr', '')

        # Get hostname if available
        hostname = ip
        hostnames = host.find('hostnames')
        if hostnames is not None:
            hn = hostnames.find('hostname')
            if hn is not None:
                hostname = hn.get('name', ip)

        for port in host.findall('.//port'):
            portid = port.get('portid', '')
            protocol = port.get('protocol', 'tcp')
            state = port.find('state')
            if state is None or state.get('state') != 'open':
                continue

            service = port.find('service')
            service_name = service.get('name', '') if service is not None else ''
            is_ssl = 'ssl' in service_name or service.get('tunnel', '') == 'ssl' if service is not None else False

            for script in port.findall('script'):
                script_id = script.get('id', '')

                if script_id == 'ssl-cert':
                    cert = parse_ssl_cert(script, hostname, ip, portid)
                    if cert:
                        findings.append(cert)

                elif script_id == 'ssl-enum-ciphers':
                    ciphers = parse_ssl_ciphers(script, hostname, ip, portid)
                    findings.extend(ciphers)

    return findings


def parse_ssl_cert(script, hostname, ip, port):
    """Extract certificate info from ssl-cert script output."""
    subject = ''
    issuer = ''
    not_before = ''
    not_after = ''
    sig_algo = ''
    pk_type = ''
    pk_bits = 0

    for table in script.findall('.//table'):
        name = table.get('key', '')
        if name == 'subject':
            parts = []
            for elem in table.findall('elem'):
                parts.append(f"{elem.get('key', '')}={elem.text or ''}")
            subject = ', '.join(parts)
        elif name == 'issuer':
            parts = []
            for elem in table.findall('elem'):
                parts.append(f"{elem.get('key', '')}={elem.text or ''}")
            issuer = ', '.join(parts)
        elif name == 'validity':
            for elem in table.findall('elem'):
                if elem.get('key') == 'notBefore':
                    not_before = elem.text or ''
                elif elem.get('key') == 'notAfter':
                    not_after = elem.text or ''
        elif name == 'pubkey':
            for elem in table.findall('elem'):
                if elem.get('key') == 'type':
                    pk_type = elem.text or ''
                elif elem.get('key') == 'bits':
                    try:
                        pk_bits = int(elem.text or '0')
                    except ValueError:
                        pk_bits = 0

    # Get sig_algo from direct elements
    for elem in script.findall('.//elem'):
        if elem.get('key') == 'sig_algo':
            sig_algo = elem.text or ''

    # Resolve PQC OIDs to human-readable names
    sig_algo = resolve_pqc_oid(sig_algo, PQC_SIG_OIDS)
    pk_type = resolve_pqc_oid(pk_type, PQC_KEY_OIDS)

    # Build display name
    cn = ''
    for part in subject.split(', '):
        if part.startswith('commonName='):
            cn = part.split('=', 1)[1]
            break
    name = cn or subject or f'{hostname}:{port}'

    return {
        'type': 'certificate',
        'name': name,
        'hostname': hostname,
        'ip': ip,
        'port': port,
        'subject': subject,
        'issuer': issuer,
        'not_before': not_before,
        'not_after': not_after,
        'sig_algo': sig_algo,
        'pk_type': pk_type,
        'pk_bits': pk_bits,
    }


def parse_ssl_ciphers(script, hostname, ip, port):
    """Extract cipher suite info from ssl-enum-ciphers output."""
    findings = []
    for tls_table in script.findall('table'):
        tls_version = tls_table.get('key', '')
        ciphers_table = tls_table.find("table[@key='ciphers']")
        if ciphers_table is None:
            continue
        for cipher in ciphers_table.findall('table'):
            cipher_name = ''
            strength = ''
            for elem in cipher.findall('elem'):
                if elem.get('key') == 'name':
                    cipher_name = elem.text or ''
                elif elem.get('key') == 'strength':
                    strength = elem.text or ''
            if cipher_name:
                findings.append({
                    'type': 'algorithm',
                    'name': cipher_name,
                    'hostname': hostname,
                    'ip': ip,
                    'port': port,
                    'tls_version': tls_version,
                    'strength': strength,
                })
    return findings


def to_iso8601(nmap_date):
    """Convert nmap date format to ISO 8601."""
    if not nmap_date:
        return None
    for fmt in ('%Y-%m-%dT%H:%M:%S', '%Y/%m/%d %H:%M:%S', '%b %d %H:%M:%S %Y %Z'):
        try:
            dt = datetime.strptime(nmap_date.strip(), fmt)
            return dt.replace(tzinfo=timezone.utc).isoformat()
        except ValueError:
            continue
    return nmap_date


def build_cbom(findings):
    """Convert findings to CycloneDX CBOM 1.6."""
    components = []

    for f in findings:
        bom_ref = str(uuid.uuid5(uuid.NAMESPACE_URL, json.dumps(f, sort_keys=True)))
        location = f"{f['hostname']}/{f['ip']}:{f['port']}"

        if f['type'] == 'certificate':
            # Create certificate component
            cert_props = {
                'subjectName': f['subject'] or f['name'],
                'issuerName': f['issuer'],
                'certificateFormat': 'X.509',
            }
            nb = to_iso8601(f.get('not_before'))
            na = to_iso8601(f.get('not_after'))
            if nb:
                cert_props['notValidBefore'] = nb
            if na:
                cert_props['notValidAfter'] = na

            # Also create signature algorithm component if available
            sig_algo_ref = None
            if f.get('sig_algo'):
                sig_algo_ref = str(uuid.uuid5(uuid.NAMESPACE_URL, f'{location}:{f["sig_algo"]}'))
                components.append({
                    'bom-ref': sig_algo_ref,
                    'type': 'cryptographic-asset',
                    'name': f['sig_algo'],
                    'evidence': {'occurrences': [{'location': location}]},
                    'cryptoProperties': {
                        'assetType': 'algorithm',
                        'algorithmProperties': {
                            'primitive': 'signature',
                            'cryptoFunctions': ['sign'],
                        },
                    },
                })
                cert_props['signatureAlgorithmRef'] = sig_algo_ref

            # Create public key component if available
            if f.get('pk_type') and f.get('pk_bits'):
                pk_ref = str(uuid.uuid5(uuid.NAMESPACE_URL, f'{location}:{f["pk_type"]}-{f["pk_bits"]}'))
                components.append({
                    'bom-ref': pk_ref,
                    'type': 'cryptographic-asset',
                    'name': f'{f["pk_type"]}-{f["pk_bits"]}',
                    'evidence': {'occurrences': [{'location': location}]},
                    'cryptoProperties': {
                        'assetType': 'related-crypto-material',
                        'relatedCryptoMaterialProperties': {
                            'type': 'public-key',
                            'size': f['pk_bits'],
                        },
                    },
                })
                cert_props['subjectPublicKeyRef'] = pk_ref

            components.append({
                'bom-ref': bom_ref,
                'type': 'cryptographic-asset',
                'name': f['name'],
                'evidence': {'occurrences': [{'location': location}]},
                'cryptoProperties': {
                    'assetType': 'certificate',
                    'certificateProperties': cert_props,
                },
            })

        elif f['type'] == 'algorithm':
            is_kex = f.get('kex_group', False)
            components.append({
                'bom-ref': bom_ref,
                'type': 'cryptographic-asset',
                'name': f['name'],
                'evidence': {'occurrences': [{'location': location}]},
                'cryptoProperties': {
                    'assetType': 'algorithm',
                    'algorithmProperties': {
                        'primitive': 'key-agree' if is_kex else 'cipher',
                        'parameterSetIdentifier': f.get('tls_version', ''),
                        'cryptoFunctions': ['encapsulate'],
                    },
                },
            })

    bom = {
        '$schema': 'https://cyclonedx.org/schema/bom-1.6.schema.json',
        'bomFormat': 'CycloneDX',
        'specVersion': '1.6',
        'serialNumber': f'urn:uuid:{uuid.uuid4()}',
        'version': 1,
        'metadata': {
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'component': {
                'type': 'application',
                'name': 'nmap-network-scan',
                'version': '1.0',
            },
        },
        'components': components,
    }
    return bom


def parse_kex_probe(kex_json_path):
    """Parse openssl s_client key-exchange probe results.

    Expected JSON format (produced by kex-probe.sh):
      [{"ip": "192.168.56.10", "port": "636", "group": "X25519MLKEM768",
        "protocol": "TLSv1.3", "cipher": "TLS_AES_256_GCM_SHA384"}, ...]

    Returns findings compatible with build_cbom().
    """
    with open(kex_json_path) as f:
        probes = json.load(f)

    findings = []
    for p in probes:
        group = p.get('group', '')
        if not group:
            continue
        findings.append({
            'type': 'algorithm',
            'name': group,
            'hostname': p.get('ip', ''),
            'ip': p.get('ip', ''),
            'port': p.get('port', ''),
            'tls_version': p.get('protocol', 'TLSv1.3'),
            'strength': '',
            'kex_group': True,
        })
    return findings


def main():
    parser = argparse.ArgumentParser(description='Convert nmap XML to CycloneDX CBOM')
    parser.add_argument('input', help='nmap XML file')
    parser.add_argument('-o', '--output', help='Output JSON file (default: stdout)')
    parser.add_argument('--kex-json', help='Supplemental openssl KEX probe JSON file')
    args = parser.parse_args()

    findings = parse_nmap_xml(args.input)
    if args.kex_json:
        kex_findings = parse_kex_probe(args.kex_json)
        findings.extend(kex_findings)
        print(f"  Merged {len(kex_findings)} KEX probe findings", file=sys.stderr)
    bom = build_cbom(findings)

    output = json.dumps(bom, indent=2)
    if args.output:
        with open(args.output, 'w') as f:
            f.write(output)
        print(f"  Wrote {len(bom['components'])} components to {args.output}", file=sys.stderr)
    else:
        print(output)


if __name__ == '__main__':
    main()
