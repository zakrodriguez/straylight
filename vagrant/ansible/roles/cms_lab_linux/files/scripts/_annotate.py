#!/usr/bin/env python3
"""Drill into a CMS SignedData and print SignerInfo + signed attributes."""
import sys
from asn1crypto import cms

with open(sys.argv[1], 'rb') as f:
    ci = cms.ContentInfo.load(f.read())

print(f"ContentType: {ci['content_type'].native}")
sd = ci['content']
print(f"SignedData version: {sd['version'].native}")
print(f"DigestAlgorithms: {[a['algorithm'].native for a in sd['digest_algorithms']]}")
print(f"EncapContentInfo type: {sd['encap_content_info']['content_type'].native}")
print(f"Number of SignerInfos: {len(sd['signer_infos'])}")

for i, si in enumerate(sd['signer_infos']):
    print(f"\nSignerInfo #{i}:")
    print(f"  Version: {si['version'].native}")
    sid = si['sid'].chosen
    if 'issuer_and_serial_number' in sid.name:
        print(f"  SID (issuerAndSerialNumber):")
        print(f"    Issuer: {sid['issuer'].native}")
        print(f"    Serial: {sid['serial_number'].native}")
    else:
        print(f"  SID ({sid.name})")
    print(f"  DigestAlgorithm: {si['digest_algorithm']['algorithm'].native}")
    print(f"  SignatureAlgorithm: {si['signature_algorithm']['algorithm'].native}")
    print(f"  Signature length: {len(si['signature'].native)} bytes")
    if si['signed_attrs']:
        print(f"  SignedAttrs ({len(si['signed_attrs'])}):")
        for attr in si['signed_attrs']:
            print(f"    {attr['type'].native}: {attr['values'].native}")
    if si['unsigned_attrs']:
        print(f"  UnsignedAttrs: {[a['type'].native for a in si['unsigned_attrs']]}")
