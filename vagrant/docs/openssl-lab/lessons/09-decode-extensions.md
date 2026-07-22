# Lesson 09: Decode SAN + EKU extensions

**Skill level:** intermediate
**Time:** ~15 min
**Prereqs:** Lesson 01

## Goal

You'll know how to extract specific X.509 extensions (SAN, EKU, AIA, CRL
distribution points) without dumping the whole cert, and you'll
understand the OID-vs-friendly-name mapping for EKU values.

## Setup

Uses files in `certs/09-extensions/`:
- `cert.crt` — a "kitchen sink" cert with multiple extensions

If you skipped bootstrap: `bash bootstrap.sh --only 09`

## Walkthrough

### Step 1: Pull just one extension by name

```bash
$ openssl x509 -in certs/09-extensions/cert.crt -ext subjectAltName -noout
```

**Why:** `-ext <name>` filters the `-text` output to a single extension. Multiple extensions: `-ext subjectAltName,extendedKeyUsage`. Names are case-sensitive and use the X.509 friendly name (camelCase).

**Expected output:**
```
X509v3 Subject Alternative Name:
    DNS:api.example.com, DNS:api-staging.example.com, DNS:*.api.example.com, IP Address:10.0.0.42, email:ops@example.com
```

### Step 2: Pull EKU + see the OID mapping

```bash
$ openssl x509 -in certs/09-extensions/cert.crt -ext extendedKeyUsage -noout
```

**Expected output:**
```
X509v3 Extended Key Usage:
    TLS Web Server Authentication, TLS Web Client Authentication, Code Signing
```

These are the friendly names. The underlying OIDs:
- `serverAuth` = `1.3.6.1.5.5.7.3.1`
- `clientAuth` = `1.3.6.1.5.5.7.3.2`
- `codeSigning` = `1.3.6.1.5.5.7.3.3`
- `emailProtection` = `1.3.6.1.5.5.7.3.4`
- `OCSPSigning` = `1.3.6.1.5.5.7.3.9`

### Step 3: AIA — where to fetch the issuer + OCSP responder

```bash
$ openssl x509 -in certs/09-extensions/cert.crt -ext authorityInfoAccess -noout
```

**Why:** Authority Information Access (AIA) tells clients where to fetch the missing intermediate (`caIssuers` URI) and where the OCSP responder lives (`OCSP` URI). Many TLS clients chase the `caIssuers` link automatically when the server fails to send a complete chain.

**Expected output:**
```
Authority Information Access:
    OCSP - URI:http://ocsp.example.com
    CA Issuers - URI:http://ca.example.com/ca.crt
```

### Step 4: CRL distribution points

```bash
$ openssl x509 -in certs/09-extensions/cert.crt -ext crlDistributionPoints -noout
```

**Expected output:**
```
X509v3 CRL Distribution Points:
    Full Name:
      URI:http://crl.example.com/lab.crl
```

### Step 5: Walk the ASN.1 tree (when -ext doesn't expose what you need)

```bash
$ openssl asn1parse -in certs/09-extensions/cert.crt -i | head -30
```

**Why:**
- `asn1parse`: dumps the cert as nested ASN.1 structures.
- `-i`: indent for readability.
- Use this when an extension is custom (not in openssl's friendly-name table) and you need to see the raw OID + value.

**Expected output (key lines):** a tree of `SEQUENCE`, `OBJECT`, `OCTET STRING`, `INTEGER`, etc. — each line corresponds to one ASN.1 element of the cert.

## Self-check

1. The cert has `*.api.example.com` as a SAN. Why is that NOT in `subject` (CN)?
2. What does `clientAuth` EKU mean operationally?
3. If a cert has `serverAuth` EKU but no SAN, will browsers accept it for any hostname?

## Cross-references

- fixmycert.com: "SAN/EKU Explorer" — interactive extension decoder.
- Real-world bug this catches: cert intended for SMIME (`emailProtection`) deployed to a TLS server — clients refuse because EKU doesn't include `serverAuth`.
- Related lessons: 10 (hostname matching uses SAN), 04 (the `-extensions` config that builds these).
