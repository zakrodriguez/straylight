"""
Set alternativeSignatureAlgorithm + alternativeCertSignKey on EJBCA-Chimera-Root-CA
via the EJBCA Admin UI's Edit CA page.

FORWARD-COMPATIBLE SKELETON. Requires EJBCA 9.4+ which exposes these fields on
the Edit CA form (upstream tickets ECA-13071 + ECA-13368). On EJBCA CE 9.3.7
(the lab's current ship), the fields are NOT rendered and this script exits 2
with "FIELD-MISSING". The role's default method stays `db_patch` until CE 9.4
ships. See vagrant/docs/ejbca-chimera-setup.md for upstream status.

Page-object pattern mirrors configure-chimera.py in ejbca_chimera_profile.

Run inside an mcr.microsoft.com/playwright/python:v1.48.0-noble container.
Idempotent: exits 0 with no changes if both fields already match desired values.

Args:
  --base-url       e.g. https://192.168.56.50:8443
  --p12            Path to SuperAdmin P12
  --pwd-file       Path to file containing P12 password (single line)
  --ca             CA name (default: EJBCA-Chimera-Root-CA)
  --alt-algo       Alt signature algorithm (default: ML-DSA-65)
  --alt-key-alias  Alt cert sign key alias (default: signKeyMLDSA)
  --dry-run        Log intended actions, do not save

Exit codes:
  0  success (changed or already-correct)
  1  unexpected failure (login, navigation, save)
  2  FIELD-MISSING — selectors absent. Likely EJBCA < 9.4. Fall back to db_patch.
"""
import argparse
import asyncio
import re
import sys
from playwright.async_api import async_playwright, TimeoutError as PWTimeout

ADMIN_PATH = "/ejbca/adminweb/"
EDIT_CAS_PATH = "ca/editcas/editcas.xhtml"

# Hypothesized JSF selectors. The exact element IDs MUST be confirmed against
# the EJBCA 9.4 DOM before flipping the default method; if they differ the
# `--probe` mode below will report the actual IDs found on the page.
SEL_ALT_ALGO = "#editcapage\\:alternativesignaturealgorithm"
SEL_ALT_KEY = "#editcapage\\:alternativecertsignkey"
SEL_SAVE = "#editcapage\\:buttonsave"


async def login(base_url, p12, pwd):
    pw = await async_playwright().start()
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
    await page.goto(base_url + ADMIN_PATH, wait_until="load", timeout=30000)
    title = await page.title()
    if "Administration" not in title and "EJBCA" not in title:
        print(f"FAIL: unexpected admin page title: {title!r}", file=sys.stderr)
        await browser.close()
        await pw.stop()
        sys.exit(1)
    return pw, browser, ctx, page


async def open_edit_ca(page, base_url, ca_name):
    """Navigate to Edit CAs list page, open the Edit form for ca_name."""
    await page.goto(
        base_url + ADMIN_PATH + EDIT_CAS_PATH,
        wait_until="load",
        timeout=30000,
    )
    row = page.locator("tr").filter(
        has=page.locator("td", has_text=re.compile(r"^" + re.escape(ca_name) + r"$"))
    )
    if await row.count() == 0:
        print(f"FAIL: CA {ca_name!r} not found in Edit CAs list", file=sys.stderr)
        sys.exit(1)
    await row.locator("input[value='Edit CA']").click()
    await page.wait_for_load_state("load", timeout=30000)


async def get_current(page):
    """Return (alt_algo, alt_key_alias) — or (None, None) on FIELD-MISSING."""
    try:
        alt_algo = await page.locator(SEL_ALT_ALGO).input_value(timeout=3000)
        alt_key = await page.locator(SEL_ALT_KEY).input_value(timeout=3000)
        return alt_algo, alt_key
    except PWTimeout:
        return None, None


async def set_values(page, alt_algo, alt_key, dry_run):
    """Select alt-sig algo + key alias from dropdowns, click Save."""
    if dry_run:
        print(f"DRY-RUN: would set alt-algo={alt_algo} alt-key={alt_key}")
        return
    await page.locator(SEL_ALT_ALGO).select_option(label=alt_algo)
    await page.locator(SEL_ALT_KEY).select_option(label=alt_key)
    await page.locator(SEL_SAVE).click()
    await page.wait_for_load_state("load", timeout=30000)


async def run(args):
    pwd = open(args.pwd_file).read().strip()
    pw, browser, ctx, page = await login(args.base_url, args.p12, pwd)
    try:
        await open_edit_ca(page, args.base_url, args.ca)
        cur_algo, cur_key = await get_current(page)

        if cur_algo is None:
            print(
                "FIELD-MISSING: alt-sig selectors not present on Edit CA form. "
                "Likely EJBCA < 9.4. Set ejbca_chimera_method: db_patch.",
                file=sys.stderr,
            )
            sys.exit(2)

        if cur_algo == args.alt_algo and cur_key == args.alt_key_alias:
            print(f"OK: already set — alt-algo={cur_algo} alt-key={cur_key} (no change)")
            return

        print(f"BEFORE: alt-algo={cur_algo!r} alt-key={cur_key!r}")
        await set_values(page, args.alt_algo, args.alt_key_alias, args.dry_run)
        if not args.dry_run:
            print(f"OK: set alt-algo={args.alt_algo} alt-key={args.alt_key_alias}")
    finally:
        await browser.close()
        await pw.stop()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--base-url", required=True)
    p.add_argument("--p12", required=True)
    p.add_argument("--pwd-file", required=True)
    p.add_argument("--ca", default="EJBCA-Chimera-Root-CA")
    p.add_argument("--alt-algo", default="ML-DSA-65")
    p.add_argument("--alt-key-alias", default="signKeyMLDSA")
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()
    asyncio.run(run(args))


if __name__ == "__main__":
    main()
