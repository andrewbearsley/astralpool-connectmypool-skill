#!/usr/bin/env bash
#
# pool-chemistry.sh - Fetch pool chemistry (pH, ORP) from ConnectMyPool web dashboard
#
# The REST API does not expose pH/ORP data. This script logs into the web
# interface and scrapes the Chemistry page to extract these readings.
#
# Sessions are cached to avoid logging in on every call. The cookie file is
# stored at ~/.pool-session-cookies (configurable via POOL_SESSION_FILE).
# If the session has expired, a fresh login is performed automatically.
#
# Usage: ./pool-chemistry.sh [--raw] [--json]
#   --raw    Show raw HTML spans
#   --json   Output as JSON
#
# Requires: python3
# Environment:
#   POOL_WEB_USER      - ConnectMyPool login email (required)
#   POOL_WEB_PASS      - ConnectMyPool login password (required)
#   POOL_SESSION_FILE  - Cookie cache path (default: ~/.pool-session-cookies)

set -euo pipefail

POOL_WEB_USER="${POOL_WEB_USER:?Error: POOL_WEB_USER environment variable is not set}"
POOL_WEB_PASS="${POOL_WEB_PASS:?Error: POOL_WEB_PASS environment variable is not set}"
POOL_SESSION_FILE="${POOL_SESSION_FILE:-$HOME/.pool-session-cookies}"

OUTPUT_MODE="formatted"
for arg in "$@"; do
  case "$arg" in
    --raw)  OUTPUT_MODE="raw" ;;
    --json) OUTPUT_MODE="json" ;;
    --help|-h)
      echo "Usage: $0 [--raw] [--json]"
      echo "  --raw    Show raw HTML spans"
      echo "  --json   Output as JSON"
      echo ""
      echo "Environment:"
      echo "  POOL_WEB_USER      ConnectMyPool login email (required)"
      echo "  POOL_WEB_PASS      ConnectMyPool login password (required)"
      echo "  POOL_SESSION_FILE  Cookie cache path (default: ~/.pool-session-cookies)"
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

POOL_WEB_USER="$POOL_WEB_USER" POOL_WEB_PASS="$POOL_WEB_PASS" \
  POOL_OUTPUT_MODE="$OUTPUT_MODE" POOL_SESSION_FILE="$POOL_SESSION_FILE" \
  python3 - << 'PYEOF'
import sys
import os
import urllib.request
import urllib.parse
import http.cookiejar
import re
import ssl
import json
import time
from datetime import datetime

username = os.environ['POOL_WEB_USER']
password = os.environ['POOL_WEB_PASS']
output_mode = os.environ['POOL_OUTPUT_MODE']
session_file = os.environ['POOL_SESSION_FILE']

BASE_URL = "https://www.connectmypool.com.au"

cookie_jar = http.cookiejar.MozillaCookieJar(session_file)
ctx = ssl.create_default_context()
opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(cookie_jar),
    urllib.request.HTTPSHandler(context=ctx)
)

HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
    'Origin': BASE_URL,
}

def fetch(url, data=None, referer=None, retries=1):
    headers = dict(HEADERS)
    if referer:
        headers['Referer'] = referer
    if data:
        headers['Content-Type'] = 'application/x-www-form-urlencoded'
    req = urllib.request.Request(url, data=data, headers=headers)
    for attempt in range(retries + 1):
        try:
            resp = opener.open(req, timeout=30)
            return resp.read().decode('utf-8'), resp.url
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < retries:
                print("Rate limited (429), waiting 60s...", file=sys.stderr)
                time.sleep(60)
                continue
            elif e.code == 500:
                raise Exception(f"Server error (HTTP 500) from {url}")
            else:
                raise Exception(f"HTTP {e.code} from {url}: {e.reason}")
        except urllib.error.URLError as e:
            raise Exception(f"Connection failed to {url}: {e.reason}")

def extract_aspnet_tokens(html):
    vs = re.search(r'name="__VIEWSTATE" id="__VIEWSTATE" value="([^"]*)"', html)
    vsgen = re.search(r'name="__VIEWSTATEGENERATOR" id="__VIEWSTATEGENERATOR" value="([^"]*)"', html)
    ev = re.search(r'name="__EVENTVALIDATION" id="__EVENTVALIDATION" value="([^"]*)"', html)
    return {
        '__VIEWSTATE': vs.group(1) if vs else '',
        '__VIEWSTATEGENERATOR': vsgen.group(1) if vsgen else '',
        '__EVENTVALIDATION': ev.group(1) if ev else '',
    }

def extract_span(html, span_id):
    match = re.search(rf'id="{span_id}"[^>]*>([^<]*)</span>', html)
    return match.group(1).strip() if match else None

def has_chemistry_data(html):
    """Check if the page has chemistry data (vs login page or error)."""
    return bool(re.search(r'id="lblPHMeasure"', html)) and 'Login Here' not in html[:1000]

def do_login():
    """Perform a fresh login and save cookies."""
    login_html, _ = fetch(f"{BASE_URL}/Front/Login.aspx")
    tokens = extract_aspnet_tokens(login_html)

    form_data = urllib.parse.urlencode({
        **tokens,
        'ucLogin1$txtUserName': username,
        'ucLogin1$txtPassword': password,
        'ucLogin1$btnLogin': 'Login',
    }).encode('utf-8')

    result_html, result_url = fetch(
        f"{BASE_URL}/Front/Login.aspx",
        data=form_data,
        referer=f"{BASE_URL}/Front/Login.aspx"
    )

    auth_cookies = [c for c in cookie_jar if c.name == '.ASPXAUTH']
    if not auth_cookies:
        if 'activate' in result_html.lower() or 'confirmation' in result_html.lower():
            raise Exception("Login failed - account email not verified. Check your inbox for the ConnectMyPool verification email.")
        elif 'Login Here' in result_html:
            raise Exception("Login failed - incorrect username or password. Check POOL_WEB_USER and POOL_WEB_PASS.")
        else:
            raise Exception("Login failed - no auth cookie received. Site may be down or login flow changed.")

    cookie_jar.save(ignore_discard=True, ignore_expires=True)
    os.chmod(session_file, 0o600)

def fetch_chemistry():
    """Fetch the chemistry page. Returns HTML."""
    html, _ = fetch(
        f"{BASE_URL}/Account/Chemistry.aspx",
        referer=f"{BASE_URL}/Account/Home.aspx"
    )
    return html

# --- Main flow: try cached session, fall back to fresh login ---

chem_html = None

# Try cached session first
if os.path.exists(session_file):
    try:
        cookie_jar.load(ignore_discard=True, ignore_expires=True)
        html = fetch_chemistry()
        if has_chemistry_data(html):
            chem_html = html
    except Exception:
        pass  # Session expired or broken, will re-login

# Fresh login if needed
if chem_html is None:
    try:
        cookie_jar.clear()
        do_login()
        chem_html = fetch_chemistry()
        if not has_chemistry_data(chem_html):
            print("Error: Chemistry page loaded but contains no data. The pool controller may be offline or the account may not have Chemistry access.", file=sys.stderr)
            sys.exit(1)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

# --- Extract data ---

ph_value = extract_span(chem_html, 'lblPHMeasure')
ph_last = extract_span(chem_html, 'lblPHLast')
orp_value = extract_span(chem_html, 'lblORPMeasure')
orp_last = extract_span(chem_html, 'lblORPLast')
orp_setpoint = extract_span(chem_html, 'lblORPSetPoint')
chlorine_setpoint = extract_span(chem_html, 'lblChlorineSetPoint')
pool_status = extract_span(chem_html, 'lblDCConnected')

# --- Output ---

now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

if output_mode == 'raw':
    for span_id in ['lblPHMeasure', 'lblPHLast', 'lblORPMeasure', 'lblORPLast',
                     'lblORPSetPoint', 'lblChlorineSetPoint', 'lblDCConnected']:
        val = extract_span(chem_html, span_id)
        print(f"{span_id}: {val}")

elif output_mode == 'json':
    data = {
        'ph': {
            'value': float(ph_value) if ph_value and ph_value.replace('.','').isdigit() else ph_value,
            'last_reading': ph_last,
        },
        'orp': {
            'value': int(orp_value) if orp_value and orp_value.isdigit() else orp_value,
            'last_reading': orp_last,
            'set_point': int(orp_setpoint) if orp_setpoint and orp_setpoint.isdigit() else orp_setpoint,
        },
        'chlorine_set_point': int(chlorine_setpoint) if chlorine_setpoint and chlorine_setpoint.isdigit() else chlorine_setpoint,
        'pool_connected': pool_status == 'Pool system online' if pool_status else None,
        'fetched_at': now,
    }
    print(json.dumps(data, indent=2))

else:
    print()
    print("============================================")
    print("  Pool Chemistry")
    print("============================================")
    print()
    print(f"  pH Level:           {ph_value or 'N/A'}")
    if ph_last:
        print(f"                      ({ph_last})")
    print()
    print(f"  ORP:                {orp_value or 'N/A'}")
    if orp_last:
        print(f"                      ({orp_last})")
    print(f"  ORP Set Point:      {orp_setpoint or 'N/A'}")
    print()
    print(f"  Chlorine Set Point: {chlorine_setpoint or 'N/A'}")
    print()
    print(f"  Pool Status:        {pool_status or 'N/A'}")
    print()
    print("============================================")
    print(f"  Fetched at: {now}")
    print("============================================")

    # Warnings
    warnings = []
    if ph_value:
        try:
            ph = float(ph_value)
            if ph < 7.0:
                warnings.append(f"pH is LOW ({ph}) - ideal range is 7.2-7.6")
            elif ph > 7.8:
                warnings.append(f"pH is HIGH ({ph}) - ideal range is 7.2-7.6")
        except ValueError:
            pass

    if orp_value:
        if orp_value == 'Low':
            warnings.append("ORP is LOW - sanitiser level may be insufficient")
        elif orp_value.isdigit():
            orp = int(orp_value)
            if orp < 650:
                warnings.append(f"ORP is LOW ({orp}mV) - should be 650-750mV")
            elif orp > 800:
                warnings.append(f"ORP is HIGH ({orp}mV) - may indicate over-chlorination")

    if pool_status and pool_status != 'Pool system online':
        warnings.append(f"Pool status: {pool_status}")

    if warnings:
        print()
        for w in warnings:
            print(f"  WARNING: {w}")
        print()
PYEOF
