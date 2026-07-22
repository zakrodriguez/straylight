"""Ory Hydra consent app with AD login via LDAPS."""

import os
import secrets
import ssl

import requests
from flask import Flask, redirect, render_template, request, session
from ldap3 import Connection, Server, Tls, SIMPLE

app = Flask(__name__)
app.secret_key = os.environ.get("FLASK_SECRET_KEY", secrets.token_hex(32))

HYDRA_ADMIN_URL = os.environ["HYDRA_ADMIN_URL"]
LDAP_URL = os.environ["LDAP_URL"]
LDAP_DOMAIN = os.environ["LDAP_DOMAIN"]
LDAP_BASE_DN = os.environ["LDAP_BASE_DN"]

_tls = Tls(validate=ssl.CERT_NONE)
_ldap_server = Server(LDAP_URL, use_ssl=True, tls=_tls)


def _csrf_token():
    """Generate or retrieve CSRF token from session."""
    if "_csrf" not in session:
        session["_csrf"] = secrets.token_hex(16)
    return session["_csrf"]


app.jinja_env.globals["csrf_token"] = _csrf_token


def ldap_authenticate(username, password):
    """Authenticate user via LDAPS simple bind to AD."""
    bind_dn = f"{LDAP_DOMAIN}\\{username}"
    conn = Connection(_ldap_server, user=bind_dn, password=password, authentication=SIMPLE)
    try:
        if conn.bind():
            return True
        return False
    finally:
        conn.unbind()


@app.route("/login", methods=["GET", "POST"])
def login():
    challenge = request.args.get("login_challenge")
    if not challenge:
        return "Missing login_challenge parameter", 400

    if request.method == "GET":
        return render_template("login.html", challenge=challenge, error=None)

    if request.form.get("_csrf") != session.get("_csrf"):
        return "CSRF validation failed", 403

    username = request.form.get("username", "")
    password = request.form.get("password", "")

    if not username or not password:
        return render_template(
            "login.html", challenge=challenge, error="Username and password required"
        )

    if not ldap_authenticate(username, password):
        return render_template(
            "login.html", challenge=challenge, error="Invalid credentials"
        )

    resp = requests.put(
        f"{HYDRA_ADMIN_URL}/admin/oauth2/auth/requests/login/accept",
        params={"login_challenge": challenge},
        json={"subject": username, "remember": True, "remember_for": 3600},
        timeout=10,
    )
    body = resp.json()
    return redirect(body["redirect_to"])


@app.route("/consent")
def consent():
    challenge = request.args.get("consent_challenge")
    if not challenge:
        return "Missing consent_challenge parameter", 400

    consent_req = requests.get(
        f"{HYDRA_ADMIN_URL}/admin/oauth2/auth/requests/consent",
        params={"consent_challenge": challenge},
        timeout=10,
    ).json()

    resp = requests.put(
        f"{HYDRA_ADMIN_URL}/admin/oauth2/auth/requests/consent/accept",
        params={"consent_challenge": challenge},
        json={
            "grant_scope": consent_req.get("requested_scope", []),
            "grant_access_token_audience": consent_req.get(
                "requested_access_token_audience", []
            ),
            "session": {
                "id_token": {
                    "sub": consent_req.get("subject", ""),
                    "preferred_username": consent_req.get("subject", ""),
                },
            },
        },
        timeout=10,
    )
    body = resp.json()
    return redirect(body["redirect_to"])


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=3000)
