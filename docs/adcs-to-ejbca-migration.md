# Migrating ADCS Issuing CA to EJBCA CE with YubiHSM2

Export an issuing CA private key from Active Directory Certificate
Services (AD CS) with `certutil`, transfer it via base64, convert it with
OpenSSL, and import it into EJBCA Community Edition — via a YubiHSM2
PKCS#11 hard token (physical device) or a soft token (no HSM).

## Overview

```
  ┌──────────────┐     certutil      ┌───────────┐
  │   ISSUECA    │ ──────────────▶   │  PFX file  │
  │  (ADCS CA)   │   -backupKey      └─────┬─────┘
  └──────────────┘                         │
                                    base64 transfer
                                           │
  ┌──────────────┐                   ┌─────▼─────┐
  │   EJBCA1     │ ◀────────────── │  PFX file  │
  │  (Linux VM)  │                   └─────┬─────┘
  └──────┬───────┘                         │
         │                          OpenSSL extract
         │                                 │
         │              ┌──────────────────┼──────────────────┐
         │              │                  │                  │
         │        ┌─────▼─────┐    ┌───────▼──────┐   ┌──────▼──────┐
         │        │ Private   │    │ Issuing CA   │   │  Root CA    │
         │        │ Key (PEM) │    │ Cert (PEM)   │   │ Cert (PEM)  │
         │        └─────┬─────┘    └───────┬──────┘   └──────┬──────┘
         │              │                  │                  │
         │    ┌─────────▼──────────┐       └────────┬─────────┘
         │    │  Path A: YubiHSM2  │                │
         │    │  (physical device) │          chain file
         │    │                    │                │
         │    │  yubihsm-shell     │     ┌──────────▼──────────┐
         │    │  put-asymmetric    │     │  Path B: Soft Token  │
         │    │       │            │     │  (no HSM needed)     │
         │    │  PKCS#11 Token     │     │                      │
         │    │       │            │     │  Rebuilt PFX with    │
         │    │  ejbca.sh          │     │  full chain          │
         │    │  ca importca       │     │       │              │
         │    │  --hard            │     │  ejbca.sh            │
         │    └────────┬───────────┘     │  ca importca         │
         │             │                 └──────────┬───────────┘
         │             ▼                            ▼
         │    ┌────────────────────────────────────────────┐
         └──▶ │  ADCS-YOURLAB-Issuing-CA in EJBCA          │
              │  (same key, same cert, new CA platform)    │
              └────────────────────────────────────────────┘
```

### Lab Values

| Item | Value |
|------|-------|
| Domain | `yourlab.local` |
| NetBIOS | `YOURLAB` |
| Domain DN | `DC=yourlab,DC=local` |
| Admin password | `TenTowns00!` |
| ISSUECA IP | `192.168.56.21` |
| EJBCA1 IP | `192.168.56.50` |
| ADCS Root CA name | `YOURLAB-Root-CA` |
| ADCS Issuing CA name | `YOURLAB-Issuing-CA` |
| EJBCA existing CAs | `EJBCA-Root-CA`, `EJBCA-Issuing-CA` |
| Imported CA name | `ADCS-YOURLAB-Issuing-CA` |
| PFX export password | `ExportP@ss1` |
| EJBCA container | `ejbca-ce` |
| EJBCA CLI path | `/opt/keyfactor/bin/ejbca.sh` (inside container) |
| Export dir (host) | `/opt/ejbca/data/export/` |
| Export dir (container) | `/mnt/export` |
| PKCS#11 lib (container) | `/usr/lib/yubihsm_pkcs11.so` |
| YubiHSM connector | `http://127.0.0.1:12345` |
| YubiHSM auth key | `1` (default) |
| YubiHSM password | `password` |
| PKCS#11 PIN | `0001password` |

## Prerequisites

### Required VMs

From the project root, bring up the AD CS two-tier VMs plus EJBCA1 and wait
for provisioning to finish. The `ad-cs-two-tier` profile does not include
`ejbca1`, so use a profile that contains both — `pqc-full` or `full`:

```bash
cd vagrant
LAB_PROFILE=pqc-full vagrant up dc1 rootca web1 issueca ejbca1
```

### Verify ADCS Is Running

The `vagrant winrm` commands throughout this guide require the vagrant-winrm
plugin: `vagrant plugin install vagrant-winrm`.

```bash
vagrant winrm issueca -c "certutil -ping"
```

Output includes `CertUtil: -ping command completed successfully`.

### Verify EJBCA Is Running

```bash
vagrant ssh ejbca1 -c "docker exec ejbca-ce /opt/keyfactor/bin/ejbca.sh ca listcas"
```

Output includes `EJBCA-Root-CA` and `EJBCA-Issuing-CA` (under `pqc-full` the
PQC and chimera CAs appear as well).

### Verify YubiHSM Connector (Optional)

```bash
vagrant ssh ejbca1 -c "curl -s http://127.0.0.1:12345/connector/status"
```

Expected output: `status=NO_DEVICE` — in `connector` mode (the default) the
connector runs with no physical device attached. `status=OK` appears only with
a real YubiHSM2 plugged in; without one, steps marked **[Physical HSM]** will
fail — use the soft token path instead.

## Step 1: Export CA Key from ADCS

On the host, create a script that backs up the CA private key and
base64-encodes the PFX for cross-VM transfer:

```bash
cat > /tmp/export-ca.ps1 << 'ENDOFSCRIPT'
# Back up the CA private key and certificate to a PFX file
New-Item -Path C:\CABackup -ItemType Directory -Force | Out-Null
certutil -backupKey C:\CABackup -p "ExportP@ss1"
if ($LASTEXITCODE -ne 0) { throw "certutil -backupKey failed" }

# Find the exported PFX
$pfx = Get-ChildItem C:\CABackup\*.p12 | Select-Object -First 1
if (-not $pfx) { throw "No .p12 file found in C:\CABackup" }
Write-Host "Exported: $($pfx.FullName) ($($pfx.Length) bytes)"

# Base64 encode for transfer
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($pfx.FullName))
[IO.File]::WriteAllText("C:\CABackup\issueca.b64", $b64)
Write-Host "Base64 encoded to C:\CABackup\issueca.b64"
ENDOFSCRIPT
```

Upload and run it on ISSUECA:

```bash
vagrant upload /tmp/export-ca.ps1 C:\\export-ca.ps1 issueca
vagrant winrm issueca -c "powershell.exe -ExecutionPolicy Bypass -File C:\export-ca.ps1"
```

`certutil -backupKey` reads from the local key store, so it works over WinRM
Basic auth with no double-hop issues.

## Step 2: Transfer PFX to EJBCA1

Retrieve the base64-encoded PFX from ISSUECA and decode it on the host:

```bash
vagrant winrm issueca -c "type C:\CABackup\issueca.b64" 2>/dev/null \
  | sed 's/^[[:space:]]*issueca:[[:space:]]*//' \
  | tr -d '\r\n' > /tmp/issueca.b64
base64 -d /tmp/issueca.b64 > /tmp/issueca.pfx
```

> [!NOTE]
> The `sed` command strips Vagrant's `issueca:` output prefix. If you get a
> 0-byte file, run `vagrant winrm issueca -c "echo test"` to see the exact
> prefix format and adjust the sed pattern.

Verify the PFX:

```bash
openssl pkcs12 -info -in /tmp/issueca.pfx -passin pass:ExportP@ss1 -nokeys | head -20
```

Subject lines should contain `YOURLAB-Issuing-CA`.

Transfer to EJBCA1:

```bash
cat /tmp/issueca.pfx | vagrant ssh ejbca1 -c \
  "sudo tee /opt/ejbca/data/export/issueca.pfx > /dev/null"
```

Verify the file arrived:

```bash
vagrant ssh ejbca1 -c "ls -la /opt/ejbca/data/export/issueca.pfx"
```

## Step 3: Extract Key and Certificate Chain

SSH into EJBCA1; all commands below run there unless otherwise noted:

```bash
vagrant ssh ejbca1
```

### Extract the Private Key

```bash
openssl pkcs12 -nocerts -nodes \
  -in /opt/ejbca/data/export/issueca.pfx \
  -passin pass:ExportP@ss1 \
  -out /opt/ejbca/data/export/private-key.pem
```

### Extract the Issuing CA Certificate

```bash
openssl pkcs12 -clcerts -nokeys \
  -in /opt/ejbca/data/export/issueca.pfx \
  -passin pass:ExportP@ss1 \
  -out /opt/ejbca/data/export/issuing-ca.pem
```

### Extract the Root CA Certificate

```bash
openssl pkcs12 -cacerts -nokeys \
  -in /opt/ejbca/data/export/issueca.pfx \
  -passin pass:ExportP@ss1 \
  -out /opt/ejbca/data/export/root-ca.pem
```

> [!NOTE]
> If `root-ca.pem` is empty, the certutil backup did not include the root
> CA certificate in the chain. Export it separately from ISSUECA:
>
> ```bash
> # On the host (not EJBCA1):
> vagrant winrm issueca -c 'certutil -ca.chain C:\CABackup\chain.p7b'
> # Then base64-transfer chain.p7b and extract with:
> # openssl pkcs7 -print_certs -in chain.p7b -out root-ca.pem
> ```

### Build the Certificate Chain File

The chain file must have the issuing CA certificate first, then the root CA:

```bash
cat /opt/ejbca/data/export/issuing-ca.pem \
    /opt/ejbca/data/export/root-ca.pem \
  > /opt/ejbca/data/export/ca-chain.pem
```

### Verify the Certificates

```bash
echo "=== Issuing CA ==="
openssl x509 -noout -subject -issuer -in /opt/ejbca/data/export/issuing-ca.pem

echo "=== Root CA ==="
openssl x509 -noout -subject -issuer -in /opt/ejbca/data/export/root-ca.pem
```

Expected output:

```
=== Issuing CA ===
subject=DC = local, DC = yourlab, CN = YOURLAB-Issuing-CA
issuer=DC = local, DC = yourlab, CN = YOURLAB-Root-CA
=== Root CA ===
subject=DC = local, DC = yourlab, CN = YOURLAB-Root-CA
issuer=DC = local, DC = yourlab, CN = YOURLAB-Root-CA
```

### Rebuild PFX for EJBCA Soft Token Import

Create a new PKCS#12 file with a known key alias (`signKey`) and the full
chain, used by the soft token import path in Step 6b:

```bash
openssl pkcs12 -export \
  -out /opt/ejbca/data/export/issueca-import.pfx \
  -inkey /opt/ejbca/data/export/private-key.pem \
  -in /opt/ejbca/data/export/issuing-ca.pem \
  -certfile /opt/ejbca/data/export/root-ca.pem \
  -name "signKey" \
  -passout pass:ExportP@ss1
```

## Step 4: Import Key into YubiHSM2

> [!WARNING]
> **Physical HSM required.** Requires a physical YubiHSM2 attached to the
> EJBCA1 VM. In connector-only mode (the default), skip to **Step 6b**.

Import the extracted RSA 4096 private key into the YubiHSM2:

```bash
yubihsm-shell
```

Inside the interactive session:

```
connect
session open 1 password
put asymmetric 0 100 adcs-issueca-signkey 1 sign-pkcs,sign-pss /opt/ejbca/data/export/private-key.pem
session close 0
quit
```

`put asymmetric` arguments: session ID `0`, object ID `100` (`0x0064`; 0 =
auto-assign), label `adcs-issueca-signkey`, domain `1`, capabilities
`sign-pkcs,sign-pss`. The algorithm (RSA 4096) is auto-detected from the key file.

Verify the key was stored:

```
connect
session open 1 password
list objects 0
session close 0
quit
```

Expect an object with ID `0x0064`, type `asymmetric-key`, label
`adcs-issueca-signkey`.

## Step 5: Create PKCS#11 CryptoToken in EJBCA

> [!WARNING]
> **Physical HSM required.** Connector-only users skip to **Step 6b**.

```bash
docker exec ejbca-ce /opt/keyfactor/bin/ejbca.sh cryptotoken create \
  --token "YubiHSM2-ADCS-Migration" \
  --pin "0001password" \
  --autoactivate true \
  --type PKCS11CryptoToken \
  --lib /usr/lib/yubihsm_pkcs11.so \
  --slotlabeltype SLOT_NUMBER \
  --slotlabel 0
```

The PKCS#11 PIN is the 4-character hex auth key ID (`0001`) concatenated with
the YubiHSM password (`password`).

Verify the token is active:

```bash
docker exec ejbca-ce /opt/keyfactor/bin/ejbca.sh cryptotoken list
```

## Step 6: Import CA into EJBCA

Choose **Path A** (hard token) if you have a physical YubiHSM2 and completed
Steps 4-5, or **Path B** (soft token) if running connector-only.

### Path A: Hard Token Import (Physical YubiHSM2)

Create a `catoken.properties` mapping EJBCA key aliases to the YubiHSM2 key:

```bash
sudo tee /opt/ejbca/data/export/catoken.properties > /dev/null << 'EOF'
sharedLibrary=/usr/lib/yubihsm_pkcs11.so
slotLabelType=SLOT_NUMBER
slotLabelValue=0
certSignKey=adcs-issueca-signkey
crlSignKey=adcs-issueca-signkey
defaultKey=adcs-issueca-signkey
EOF
```

Import the CA using the PKCS#11 token:

```bash
docker exec ejbca-ce /opt/keyfactor/bin/ejbca.sh ca importca \
  "ADCS-YOURLAB-Issuing-CA" \
  --hard \
  --cp org.cesecore.keys.token.PKCS11CryptoToken \
  --ctpassword "0001password" \
  --prop /mnt/export/catoken.properties \
  --cert /mnt/export/ca-chain.pem
```

> [!NOTE]
> Paths inside the container use `/mnt/export/` (the bind mount of
> `/opt/ejbca/data/export/` on the host).

### Path B: Soft Token Import (No HSM Required)

Import the CA using the rebuilt PFX with the full certificate chain:

```bash
docker exec ejbca-ce /opt/keyfactor/bin/ejbca.sh ca importca \
  "ADCS-YOURLAB-Issuing-CA" \
  /mnt/export/issueca-import.pfx \
  -kspassword "ExportP@ss1"
```

This creates a software crypto token and imports the CA without HSM hardware.

## Step 7: Verify

### List CAs

```bash
docker exec ejbca-ce /opt/keyfactor/bin/ejbca.sh ca listcas
```

`ADCS-YOURLAB-Issuing-CA` should appear alongside the existing EJBCA CAs.

### Check CA Details

```bash
docker exec ejbca-ce /opt/keyfactor/bin/ejbca.sh ca info \
  --caname "ADCS-YOURLAB-Issuing-CA"
```

Verify subject DN `CN=YOURLAB-Issuing-CA,...`, issuer DN
`CN=YOURLAB-Root-CA,...`, and key algorithm RSA 4096.

### Generate a CRL

```bash
docker exec ejbca-ce /opt/keyfactor/bin/ejbca.sh ca createcrl \
  --caname "ADCS-YOURLAB-Issuing-CA"
```

Successful CRL generation confirms the signing key works.

### Compare Certificate Fingerprints

Verify the imported CA certificate matches the original. On EJBCA1:

```bash
docker exec ejbca-ce /opt/keyfactor/bin/ejbca.sh ca getcacert \
  --caname "ADCS-YOURLAB-Issuing-CA" \
  -f /tmp/ejbca-issueca.pem

docker exec ejbca-ce openssl x509 -noout -fingerprint -sha256 \
  -in /tmp/ejbca-issueca.pem
```

On the host, compare with the original:

```bash
openssl pkcs12 -clcerts -nokeys -passin pass:ExportP@ss1 \
  -in /tmp/issueca.pfx \
  | openssl x509 -noout -fingerprint -sha256
```

The SHA-256 fingerprints must match.

## Step 8: Cleanup

Remove temporary files containing private key material. On EJBCA1:

```bash
sudo rm -f /opt/ejbca/data/export/private-key.pem
sudo rm -f /opt/ejbca/data/export/issueca.pfx
sudo rm -f /opt/ejbca/data/export/issueca-import.pfx
sudo rm -f /opt/ejbca/data/export/issuing-ca.pem
sudo rm -f /opt/ejbca/data/export/root-ca.pem
sudo rm -f /opt/ejbca/data/export/ca-chain.pem
sudo rm -f /opt/ejbca/data/export/catoken.properties
```

On the host:

```bash
rm -f /tmp/issueca.b64 /tmp/issueca.pfx /tmp/export-ca.ps1
```

On ISSUECA (from the host):

```bash
vagrant winrm issueca -c "Remove-Item -Recurse -Force C:\CABackup, C:\export-ca.ps1"
```

> [!CAUTION]
> This lab uses known demonstration passwords. In production, use unique strong
> passwords, transfer keys only over encrypted channels, and securely wipe all
> intermediate files.

## Connector-Only vs Physical YubiHSM2

| Step | Connector-Only | Physical HSM |
|------|---------------|--------------|
| 1. Export CA key from ADCS | Yes | Yes |
| 2. Transfer PFX to EJBCA1 | Yes | Yes |
| 3. Extract key and certs (OpenSSL) | Yes | Yes |
| 4. Import key into YubiHSM2 | **No** — no device | Yes |
| 5. Create PKCS#11 CryptoToken | **No** — no device | Yes |
| 6a. Hard token CA import | **No** — requires Steps 4-5 | Yes |
| 6b. Soft token CA import | **Yes** — recommended path | Optional |
| 7. Verify | Yes | Yes |
| 8. Cleanup | Yes | Yes |

## Troubleshooting

### `certutil -backupKey` fails with "access denied"

The CA service must be running and the user must have CA administrator rights.
Verify CertSvc is running:

```bash
vagrant winrm issueca -c "Get-Service CertSvc | Select-Object Status"
```

If access errors persist, run certutil elevated via a scheduled task:

```bash
cat > /tmp/backup-elevated.ps1 << 'ENDOFSCRIPT'
$action = New-ScheduledTaskAction -Execute "certutil.exe" `
  -Argument "-backupKey C:\CABackup -p ExportP@ss1"
$task = Register-ScheduledTask -TaskName "CABackup" -Action $action `
  -User "SYSTEM" -RunLevel Highest -Force
Start-ScheduledTask -TaskName "CABackup"
$timeout = 60; $elapsed = 0
do {
    Start-Sleep -Seconds 2; $elapsed += 2
    $state = (Get-ScheduledTask -TaskName "CABackup").State
} while ($state -eq "Running" -and $elapsed -lt $timeout)
$result = Get-ScheduledTaskInfo -TaskName "CABackup"
Write-Host "Exit code: $($result.LastTaskResult)"
Unregister-ScheduledTask -TaskName "CABackup" -Confirm:$false
ENDOFSCRIPT
vagrant upload /tmp/backup-elevated.ps1 C:\\backup-elevated.ps1 issueca
vagrant winrm issueca -c "powershell.exe -ExecutionPolicy Bypass -File C:\backup-elevated.ps1"
```

### PFX password mismatch

If OpenSSL fails with `mac verify failure`, the export password does not match.
Verify by listing the PFX contents:

```bash
openssl pkcs12 -info -in /opt/ejbca/data/export/issueca.pfx -passin pass:ExportP@ss1 -nokeys
```

### YubiHSM connector unreachable

```bash
curl -v http://127.0.0.1:12345/connector/status
systemctl status yubihsm-connector
```

If the service is not running: `sudo systemctl start yubihsm-connector`.
`status=NO_DEVICE` means connector-only mode — use the soft token path (Step 6b).

### PKCS#11 slot not found

EJBCA uses slot number 0 by default. Verify available slots:

```bash
docker exec ejbca-ce pkcs11-tool --module /usr/lib/yubihsm_pkcs11.so --list-slots
```

If the slot number differs, update the `--slotlabel` value in Step 5 and the
`slotLabelValue` in `catoken.properties`.

### Wrong certificate chain order

EJBCA expects the CA's own certificate first, then the issuer. If `ca importca`
fails with chain validation errors, verify the order (issuing CA first, root
CA second):

```bash
openssl crl2pkcs7 -nocrl -certfile /opt/ejbca/data/export/ca-chain.pem \
  | openssl pkcs7 -print_certs -noout
```

### CA name already exists in EJBCA

The import name `ADCS-YOURLAB-Issuing-CA` avoids conflicting with the existing
`EJBCA-Issuing-CA`. On a duplicate name error, pick a different name in the
`ca importca` command.

### Transfer produces 0-byte file

The `sed` pattern in Step 2 may not match your Vagrant version's output prefix.
Check the exact format:

```bash
vagrant winrm issueca -c "echo TESTMARKER" 2>/dev/null
```

Adjust the sed pattern to match the prefix before `TESTMARKER`, or copy the
base64 string from the terminal output into `/tmp/issueca.b64` manually.

## References

- [certutil -backupKey — Microsoft Learn](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/certutil#-backupkey)
- [EJBCA CA Operations — Keyfactor Docs](https://doc.primekey.com/ejbca/ejbca-operations/ca-operations)
- [Migrating from Other CAs to EJBCA — Keyfactor Docs](https://doc.primekey.com/ejbca/tutorials-and-guides/migrating-from-other-cas-to-ejbca)
- [YubiHSM2 User Guide — Yubico](https://docs.yubico.com/hardware/yubihsm-2/hsm-2-user-guide/)
- [yubihsm-shell Reference — Yubico](https://docs.yubico.com/software/yubihsm-2/yubihsm-shell/)
- [EJBCA PKCS#11 Crypto Tokens — Keyfactor Docs](https://doc.primekey.com/ejbca/ejbca-operations/managing-crypto-tokens)
