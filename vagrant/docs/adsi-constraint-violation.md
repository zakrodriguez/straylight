# ADSI CommitChanges() Constraint Violation on AD CS Certificate Templates

## Summary

ADSI's `CommitChanges()` fails with **"A constraint violation occurred"** when modifying
`nTSecurityDescriptor` on templates imported by `New-ADCSTemplate` (`ADCSTemplate` module). The
Enroll/Autoenroll ACEs were never written — **all autoenrollment silently failed**; no domain machine could obtain a certificate.

## Impact

- **Affected:** `cert_templates` role (sections 3 and 3b); all JSON-imported Straylight templates
- **Symptom:** `machine_cert` exhausts all 30 retries (10 min) waiting for a Server Auth EKU certificate that can never be issued. (Retry budget at the time of the incident; the role now polls 90×20s = 30 min.)
- **Failure mode:** silent — Ansible reported `changed: [ca1]` (SUCCESS) despite ACEs never persisting (see "Why It Was Silent")
- **Error from CA:** `CERTSRV_E_TEMPLATE_DENIED` (0x80094012) — "The permissions on the
  certificate template do not allow the current user to enroll for this type of certificate"

## Root Cause

PowerShell has two write paths for AD security descriptors: **ADSI** (`[ADSI]"LDAP://..."`, COM
`DirectoryEntry.CommitChanges()`) and the **AD cmdlets** (`Get-ADObject`/`Set-ADObject`, via `System.DirectoryServices.Protocols`).

### Why ADSI Fails

Certificate templates are `pKICertificateTemplate` objects in the AD Configuration partition;
`nTSecurityDescriptor` has schema-enforced constraints. `New-ADCSTemplate` writes it as a raw
binary blob deserialized from the JSON export. ADSI reads it into a `System.DirectoryServices.ActiveDirectorySecurity`
object and `AddAccessRule()` works in memory, but `CommitChanges()` re-serializes to a binary
the schema rejects — the LDAP modify fails with **LDAP constraint violation** (`LDAP_CONSTRAINT_VIOLATION`,
0x13). The AD cmdlet path (`Set-ADObject -Replace @{nTSecurityDescriptor = $sd}`) round-trips correctly.

### Why It Was Silent

The old code structure was:

```powershell
foreach ($tplName in $autoenrollMap.Keys) {
    try {
        # ... build ACEs, add to ACL ...
        $tplObj.CommitChanges()       # <-- throws constraint violation
    } catch {
        # Logs to $results but does NOT re-throw
        $results.Add("Enroll/Autoenroll failed: $tplName ($($_.Exception.Message))")
    }
}
```

The error reached `$results` and a log file, but `no_log: true` (protecting the admin password)
hid all output, and the outer `try/catch` set `FAILED` only on unhandled exceptions — the inner
`catch` swallowed this one. The status file got `SUCCESS`; the Ansible task reported `changed`.

## Diagnosis Timeline

### Symptoms Observed

1. `vagrant provision web1` — `machine_cert` role failed after 30 retries (10 min)
2. `certutil -catemplates` on CA1 showed `Auto-Enroll: Access is denied` on the default
   `Machine` template (expected — not the target)
3. Straylight templates showed `Auto-Enroll` — misleading (see Lessons Learned #4)
4. Only 2 certs ever issued in the CA database (both NDES bootstrap certs, request IDs 2-3)
5. Explicit `certreq -submit` as SYSTEM against `Straylight-Machine-1Y-RSA2048-SHA256-v1`
   returned `CERTSRV_E_TEMPLATE_DENIED`

### Diagnosis Steps

1. Checked template ACL via ADSI on DC1 — **no Domain Computers ACEs** on any Straylight template
2. Attempted `CommitChanges()` manually as SYSTEM — **"A constraint violation occurred"**
3. Attempted `Set-Acl` via AD: drive — reported success but ACEs didn't persist
4. Attempted `Set-ADObject` as SYSTEM — **"Access is denied"** (SYSTEM lacks WriteDacl)
5. Ran `Set-ADObject` as `YOURLAB\Administrator` — **succeeded**, ACEs persisted
6. Restarted CertSvc (CA caches template ACLs), submitted fresh `certreq` — **issued**

### Key Finding: SYSTEM vs Domain Admin

The `CommitChanges()` failure is a serialization bug, independent of caller identity. The
`Set-ADObject` workaround requires `WriteDacl`, held only by `Domain Admins` and `Enterprise Admins`
— `SYSTEM` diagnostic scripts fail with "Access is denied"; the cert_templates scheduled task (runs as `YOURLAB\Administrator`) is unaffected.

## The Fix

**File:** `ansible/roles/cert_templates/tasks/main.yml`, sections 3 and 3b

### Before (broken)

```powershell
$tplObj = [ADSI]"LDAP://$tplDN"
$acl = $tplObj.ObjectSecurity
# ... add ACEs to $acl ...
$tplObj.CommitChanges()  # FAILS with constraint violation
```

### After (working)

```powershell
Import-Module ActiveDirectory
# $adCred = explicit YOURLAB\Administrator PSCredential (see below)
# Get-ADObjectWaitForReplication wraps Get-ADObject with a retry loop for AD lag.
$tplAD = Get-ADObjectWaitForReplication -Identity $tplDN `
    -Properties nTSecurityDescriptor -Credential $adCred
$sd = $tplAD.nTSecurityDescriptor
# ... add ACEs to $sd ...
Set-ADObject -Identity $tplDN -Replace @{nTSecurityDescriptor = $sd} `
    -Credential $adCred -ErrorAction Stop
```

### Additional Changes

- Inner `catch` blocks now re-throw (`throw`) so the outer try/catch sets `FAILED` status
- Error messages prefixed with `FAILED:` instead of just `failed:` for grep visibility
- `Import-Module ActiveDirectory` added at the top of section 3 (RSAT-AD-PowerShell is already
  installed by the role's first task)
- **Explicit `-Credential $adCred`** on every `Get-ADObject`/`Set-ADObject` call: the task runs
  as `YOURLAB\Administrator` via `/ru` `/rp`, but the implicit Batch-logon token can drop privileges
  and force a failing Kerberos handshake; explicit `PSCredential` forces NTLM with the full Administrator identity.
- **`Get-ADObjectWaitForReplication`** wrapper: ACEs written on one DC may be read back from
  another; it retries `Get-ADObject` (default 15 attempts × 4s) on "Directory object not found"
  to ride out replication lag, failing fast on any other error.

## Reproducing the Bug

To re-verify (e.g., after a Windows update):

```powershell
# On a domain-joined machine, as Domain Admin:
$rootDSE = [ADSI]'LDAP://RootDSE'
$configNC = $rootDSE.configurationNamingContext.Value
$tplDN = "CN=SomeJsonImportedTemplate,CN=Certificate Templates,CN=Public Key Services,CN=Services,$configNC"

# ADSI path — will fail:
$tplObj = [ADSI]"LDAP://$tplDN"
$acl = $tplObj.ObjectSecurity
$sid = (New-Object System.Security.Principal.NTAccount("YOURLAB", "Domain Computers")).Translate(
    [System.Security.Principal.SecurityIdentifier])
$ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    $sid,
    [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
    [System.Security.AccessControl.AccessControlType]::Allow,
    [Guid]'0e10c968-78fb-11d2-90d4-00c04f79dc55'
)
$acl.AddAccessRule($ace)
$tplObj.CommitChanges()  # Expected: "A constraint violation occurred"

# AD cmdlet path — will succeed:
Import-Module ActiveDirectory
$tplAD = Get-ADObject -Identity $tplDN -Properties nTSecurityDescriptor
$sd = $tplAD.nTSecurityDescriptor
$sd.AddAccessRule($ace)
Set-ADObject -Identity $tplDN -Replace @{nTSecurityDescriptor = $sd}
```

## Affected Template Types

Only JSON-imported templates from `New-ADCSTemplate` are affected; templates created via ADSI
(`$container.Create('pKICertificateTemplate', ...)`) and built-ins round-trip correctly through ADSI.

| Template | Created By | ADSI CommitChanges | Set-ADObject |
|---|---|---|---|
| Machine, User, WebServer, etc. | Built-in (AD schema) | Works | Works |
| stray-machine | ADSI `Create()` + `SetInfo()` | Works | Works |
| Straylight-Machine-1Y-* | `New-ADCSTemplate` (JSON) | **FAILS** | Works |
| Straylight-ServerAdmin-* | `New-ADCSTemplate` (JSON) | **FAILS** | Works |
| All other Straylight-* | `New-ADCSTemplate` (JSON) | **FAILS** | Works |

## Lessons Learned

1. **Never swallow exceptions silently** — re-throw or set a failure flag that propagates to the caller.
2. **`no_log: true` hides diagnostic output** — write diagnostics to a separate file that persists after the task.
3. **ADSI and AD cmdlets are not interchangeable for writes** — COM `DirectoryEntry` serializes
   differently than `System.DirectoryServices.Protocols`; reads are equivalent. Prefer AD
   cmdlets for writing security descriptors on non-standard objects.
4. **`certutil -catemplates` is misleading** — it reports the CA service's view and the *current
   caller's* autoenroll rights, not domain computers' permissions; check the actual ACL in AD.
5. **CertSvc caches template ACLs** — after modifying template permissions, run
   `Restart-Service CertSvc` or the CA won't see the new ACEs until the cache expires.
