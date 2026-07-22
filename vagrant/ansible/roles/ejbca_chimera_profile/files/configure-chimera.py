"""
Configure EJBCA cert profile + EE profile for chimera (issuer-hybrid) issuance.

Run inside an mcr.microsoft.com/playwright/python:v1.48.0-noble container.
Idempotent: exits 0 with no changes if both profiles already exist.

Args:
  --base-url           e.g. https://192.168.56.50:8443
  --p12                Path to SuperAdmin P12
  --pwd-file           Path to file containing P12 password (single line)
  --cert-profile       Cert profile name to create (default: ENDUSER-Chimera)
  --ee-profile         EE profile name to create (default: EE-Chimera)
  --ca                 CA name to associate (default: EJBCA-Chimera-Root-CA)
  --source-cert-profile  Profile to clone from (default: ENDUSER)
  --dry-run            Log intended actions, do not save
"""
import argparse
import asyncio
import re
import sys
from playwright.async_api import async_playwright, TimeoutError as PWTimeout

ADMIN_PATH = "/ejbca/adminweb/"
CERT_PROFILES_PATH = "ca/editcertificateprofiles/editcertificateprofiles.xhtml"
EE_PROFILES_PATH = "ra/editendentityprofiles/editendentityprofiles.xhtml"


async def login(base_url, p12, pwd):
    """Start Playwright, open browser context with client cert auth, navigate to admin."""
    pw = await async_playwright().start()
    # Running as root in the Playwright Docker image requires no-sandbox flags.
    # Do NOT add --ignore-certificate-errors when presenting client certs.
    browser = await pw.chromium.launch(args=[
        "--no-sandbox",
        "--disable-setuid-sandbox",
    ])
    ctx = await browser.new_context(
        ignore_https_errors=True,
        client_certificates=[{
            "origin": base_url,
            "pfxPath": p12,
            "passphrase": pwd,
        }],
    )
    page = await ctx.new_page()
    # Use wait_until="load" not "networkidle" — networkidle times out on some EJBCA pages.
    await page.goto(base_url + ADMIN_PATH, wait_until="load", timeout=30000)
    title = await page.title()
    if "Administration" not in title and "EJBCA" not in title:
        print(f"FAIL: unexpected admin page title: {title!r}", file=sys.stderr)
        await browser.close()
        await pw.stop()
        sys.exit(2)
    return pw, browser, ctx, page


async def cert_profile_exists(page, base_url, name):
    """Return True if a cert profile row with the exact name exists in the list."""
    await page.goto(
        base_url + ADMIN_PATH + CERT_PROFILES_PATH,
        wait_until="load",
        timeout=30000,
    )
    # Anchored regex to avoid partial matches, e.g. ENDUSER matching ENDUSER-Chimera.
    count = await page.locator("tr").filter(
        has=page.locator("td", has_text=re.compile(r"^" + re.escape(name) + r"$"))
    ).count()
    return count > 0


async def clone_cert_profile(page, base_url, source, target, ca_name, dry_run):
    """Clone source cert profile to target (two-step flow), then enable alt-sig + add CA."""
    await page.goto(
        base_url + ADMIN_PATH + CERT_PROFILES_PATH,
        wait_until="load",
        timeout=30000,
    )

    if dry_run:
        print(f"DRY-RUN: would clone cert profile {source} -> {target}")
        return

    # Step 1 of 2: fill target name in the list-page input and click Clone on the source row.
    # The name input is shared across all rows — fill it before clicking Clone.
    await page.locator("input[name*='profileNameInputField']").fill(target)
    await page.locator("tr").filter(
        has=page.locator("td", has_text=re.compile(r"^" + re.escape(source) + r"$"))
    ).locator("input[value='Clone']").click()
    await page.wait_for_load_state("load")

    # Step 2 of 2: confirmation page — re-fill name and click the confirm button.
    await page.locator(
        "#editcertificateprofilesForm\\:addFromTemplateProfileNew"
    ).fill(target)
    await page.locator(
        "#editcertificateprofilesForm\\:cloneConfirmButton"
    ).click()
    await page.wait_for_load_state("load")

    # --- Edit the cloned profile: enable alt-sig flag + add Chimera CA ---

    # Click Edit in the newly cloned profile's row.
    await page.locator("tr").filter(
        has=page.locator("td", has_text=re.compile(r"^" + re.escape(target) + r"$"))
    ).locator("input[value='Edit']").click()
    await page.wait_for_load_state("load")

    # Tick the alt-sig checkbox. DO NOT use get_by_label — label text "Use" is not unique.
    await page.locator(
        "#alternativeSignature\\:checkUseAlternativeSignature"
    ).check()

    # Select the Chimera CA in Available CAs (label-based; numeric IDs are per-instance).
    await page.locator(
        "#content\\:selectavailablecas"
    ).select_option(label=ca_name)

    # Save.
    await page.locator("#content\\:saveProfileButton").click()
    await page.wait_for_load_state("load")

    print(f"OK: created cert profile {target}")


async def ee_profile_exists(page, base_url, name):
    """Return True if the EE profile name appears in the profiles listbox."""
    await page.goto(
        base_url + ADMIN_PATH + EE_PROFILES_PATH,
        wait_until="load",
        timeout=30000,
    )
    # The listbox #manageEndEntityProfiles:profilesListBox holds all EE profile names.
    options = await page.locator(
        "#manageEndEntityProfiles\\:profilesListBox option"
    ).all_text_contents()
    return name in [o.strip() for o in options]


async def add_ee_profile(page, base_url, target, cert_profile, ca_name, dry_run):
    """Create a fresh EE profile via Add Profile (not Clone — EMPTY is uncloneable),
    then wire cert profile + CA via Edit."""
    await page.goto(
        base_url + ADMIN_PATH + EE_PROFILES_PATH,
        wait_until="load",
        timeout=30000,
    )

    if dry_run:
        print(f"DRY-RUN: would add EE profile {target} and configure for {cert_profile} / {ca_name}")
        return

    # Fill name in the add-profile input and click Add.
    await page.locator(
        "#manageEndEntityProfiles\\:addProfileNew"
    ).fill(target)
    await page.locator(
        "#manageEndEntityProfiles\\:addButton"
    ).click()
    await page.wait_for_load_state("load")

    # Select the newly added profile and click Edit.
    await page.select_option(
        "#manageEndEntityProfiles\\:profilesListBox",
        label=target,
    )
    await page.locator(
        "#manageEndEntityProfiles\\:editButton"
    ).click()
    await page.wait_for_load_state("load")

    # --- Wire cert profile + CA ---

    # Available certificate profiles: add ENDUSER-Chimera.
    await page.locator(
        "#eeProfiles\\:availableCertProfiles"
    ).select_option(label=cert_profile)

    # Default certificate profile.
    await page.locator(
        "#eeProfiles\\:defaultCertificateProfile"
    ).select_option(label=cert_profile)

    # Available CAs.
    await page.locator(
        "#eeProfiles\\:availableCA"
    ).select_option(label=ca_name)

    # Default CA.
    await page.locator(
        "#eeProfiles\\:defaultCAMenu"
    ).select_option(label=ca_name)

    # Save.
    await page.locator("#eeProfiles\\:saveButton").click()
    await page.wait_for_load_state("load")

    print(f"OK: created EE profile {target}")


async def main():
    ap = argparse.ArgumentParser(
        description="Configure EJBCA cert + EE profiles for chimera issuance."
    )
    ap.add_argument("--base-url", required=True, help="EJBCA base URL, e.g. https://192.168.56.50:8443")
    ap.add_argument("--p12", required=True, help="Path to SuperAdmin P12")
    ap.add_argument("--pwd-file", required=True, help="Path to file containing P12 password")
    ap.add_argument("--cert-profile", default="ENDUSER-Chimera", help="Cert profile name to create")
    ap.add_argument("--ee-profile", default="EE-Chimera", help="EE profile name to create")
    ap.add_argument("--ca", default="EJBCA-Chimera-Root-CA", help="CA name to associate")
    ap.add_argument("--source-cert-profile", default="ENDUSER", help="Cert profile to clone from")
    ap.add_argument("--dry-run", action="store_true", help="Log intended actions, do not save")
    args = ap.parse_args()

    pwd = open(args.pwd_file).read().strip()
    pw, browser, _ctx, page = await login(args.base_url, args.p12, pwd)
    try:
        # --- Cert profile ---
        if await cert_profile_exists(page, args.base_url, args.cert_profile):
            print(f"SKIP: cert profile {args.cert_profile} already exists")
        else:
            await clone_cert_profile(
                page,
                args.base_url,
                args.source_cert_profile,
                args.cert_profile,
                args.ca,
                args.dry_run,
            )

        # --- EE profile ---
        if await ee_profile_exists(page, args.base_url, args.ee_profile):
            print(f"SKIP: EE profile {args.ee_profile} already exists")
        else:
            await add_ee_profile(
                page,
                args.base_url,
                args.ee_profile,
                args.cert_profile,
                args.ca,
                args.dry_run,
            )
    except PWTimeout as e:
        print(f"FAIL: locator/page timeout — likely DOM drift: {e}", file=sys.stderr)
        sys.exit(3)
    finally:
        await browser.close()
        await pw.stop()


if __name__ == "__main__":
    asyncio.run(main())
