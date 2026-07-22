#!/usr/bin/env python3
"""Hand-build EnvelopedData artifact using ML-KEM-768 (RFC 9629 sketch).

The openssl cms -encrypt CLI doesn't accept ML-KEM recipients today. This
script demonstrates the building blocks (ML-KEM encapsulation + KDF +
AES-256-GCM content encryption) and produces a CMS-shaped artifact that
parses as ContentInfo wrapping EnvelopedData.

NOT production crypto. Teaching-grade. The RecipientInfo branch uses
OtherRecipientInfo with the id-ori-kem placeholder OID; a full RFC 9629
implementation would assemble a proper KEMRecipientInfo SEQUENCE with
explicit KDF/wrap fields.

Usage: 07-handbuild.py <ml-kem-pubkey.pub> <ml-kem-privkey.key> <input> <output.cms>
"""
import os
import subprocess
import sys
from asn1crypto import cms, algos, core
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

if len(sys.argv) != 5:
    print(__doc__, file=sys.stderr)
    sys.exit(1)

pubkey_path, privkey_path, input_path, output_path = sys.argv[1:5]

# Step 1: ML-KEM encapsulation against the recipient public key.
secret_tmp = "/tmp/.ml-kem-secret.bin"
encaps_tmp = "/tmp/.ml-kem-encaps.bin"
subprocess.run(
    ["/opt/openssl-3.5/bin/openssl", "pkeyutl", "-encap",
     "-inkey", pubkey_path, "-pubin",
     "-out", encaps_tmp, "-secret", secret_tmp],
    check=True,
)
with open(secret_tmp, "rb") as f:
    shared_secret = f.read()
with open(encaps_tmp, "rb") as f:
    encapsulated_key = f.read()
os.unlink(secret_tmp)
os.unlink(encaps_tmp)

# Step 2: derive a content-encryption key from the shared secret via HKDF-SHA256.
cek = HKDF(algorithm=hashes.SHA256(), length=32, salt=None,
           info=b"cms-lab-kemri").derive(shared_secret)

# Step 3: AES-256-GCM encrypt the plaintext.
with open(input_path, "rb") as f:
    plaintext = f.read()
iv = os.urandom(12)
ct_with_tag = AESGCM(cek).encrypt(iv, plaintext, None)
ciphertext, tag = ct_with_tag[:-16], ct_with_tag[-16:]

# Step 4: build OtherRecipientInfo with the encapsulated KEM ciphertext as the
# octet-string payload. The id-ori-kem placeholder OID signals this is a
# KEM-style recipient (teaching-grade — not a strict RFC 9629 KEMRecipientInfo).
other_ri = cms.OtherRecipientInfo({
    'ori_type': '1.2.840.113549.1.9.16.13.3',  # id-ori-kem
    'ori_value': core.ParsableOctetString(encapsulated_key),
})

# Step 5: EncryptedContentInfo with AES-256-CBC (asn1crypto's GcmParameters
# isn't available in older asn1crypto; use CBC-style algorithm identifier with
# IV-as-parameters for teaching purposes). The ciphertext+tag stays AES-GCM
# but the algorithm identifier just records the IV — readers should know this
# is teaching-grade and the real RFC 9629 KEMRecipientInfo + AES-GCM has its
# own normative parameter structure.
enc_ci = cms.EncryptedContentInfo({
    'content_type': 'data',
    'content_encryption_algorithm': algos.EncryptionAlgorithm({
        'algorithm': 'aes256_cbc',
        'parameters': core.OctetString(iv),
    }),
    'encrypted_content': ciphertext + tag,
})

# Step 6: EnvelopedData + outer ContentInfo wrapper.
ed = cms.EnvelopedData({
    'version': 'v4',
    'recipient_infos': cms.RecipientInfos([cms.RecipientInfo({'ori': other_ri})]),
    'encrypted_content_info': enc_ci,
})
ci = cms.ContentInfo({
    'content_type': 'enveloped_data',
    'content': ed,
})

with open(output_path, "wb") as f:
    f.write(ci.dump())

print(f"Wrote {output_path} ({os.path.getsize(output_path)} bytes)")
