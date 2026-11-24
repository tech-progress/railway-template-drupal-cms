#!/usr/bin/env python3
"""Application-level smoke test for the Drupal CMS template.

Runs through the public URL only, with Drupal's own forms, so it works the same
against the local Compose stack and a Railway deployment.

  setup     anonymous refusals; the generated administrator signs in; the
            client address Drupal records is the visitor's; a published page,
            a page scheduled to publish (published by the container's cron
            loop, the template's background worker), a site slogan
            (configuration) and an uploaded logo (public file on the volume);
            optionally per-visitor login flood control (FLOOD_TEST=1, local
            only). Records what it made in STATE_FILE.
  readback  after a restart or redeploy: the same password still signs in
            (the install did not run again), and every record made by setup
            is still there, the logo byte for byte.

Environment:
  BASE_URL                https://<domain> (no trailing slash)
  ADMIN_USER              default admin
  ADMIN_PASSWORD_FILE     file holding the administrator password (0600)
  STATE_FILE              JSON file written by setup and read by readback
  INSECURE_TLS=1          accept the local edge's self-signed certificate
  CLIENT_HEADER=1         local edge: send X-Test-Client to choose the visitor
  EXPECT_CLIENT_IP        the address Drupal must record for the sign-in;
                          without it, any address outside private, loopback
                          and Railway's 100.64.0.0/10 passes
  FLOOD_TEST=1            local only: five failed sign-ins from one visitor
                          block that visitor, not another
Prints no password.
"""

import datetime
import hashlib
import html
import html.parser
import http.cookiejar
import ipaddress
import json
import os
import re
import secrets
import ssl
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib

BASE = os.environ["BASE_URL"].rstrip("/")
USER = os.environ.get("ADMIN_USER", "admin")
with open(os.environ["ADMIN_PASSWORD_FILE"], encoding="utf-8") as fh:
    PASSWORD = fh.read().strip()
STATE_FILE = os.environ["STATE_FILE"]
CONTEXT = ssl.create_default_context()
if os.environ.get("INSECURE_TLS") == "1":
    CONTEXT.check_hostname = False
    CONTEXT.verify_mode = ssl.CERT_NONE
CLIENT_HEADER = os.environ.get("CLIENT_HEADER") == "1"
UA = "drupal-cms-template-smoke"


def ok(message):
    print(f"smoke: ok {message}", flush=True)


def die(message):
    print(f"smoke: FAIL {message}", file=sys.stderr, flush=True)
    sys.exit(1)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class Client:
    """A visitor: its own cookies and, on the local edge, its own address."""

    def __init__(self, address="203.0.113.50"):
        self.jar = http.cookiejar.CookieJar()
        handlers = [urllib.request.HTTPCookieProcessor(self.jar), urllib.request.HTTPSHandler(context=CONTEXT)]
        self.follow = urllib.request.build_opener(*handlers)
        self.stay = urllib.request.build_opener(*handlers, NoRedirect())
        self.address = address

    def request(self, path, data=None, headers=None, follow=True, timeout=60):
        url = path if path.startswith("http") else BASE + path
        hdrs = {"User-Agent": UA}
        if CLIENT_HEADER:
            hdrs["X-Test-Client"] = self.address
        hdrs.update(headers or {})
        req = urllib.request.Request(url, data=data, headers=hdrs)
        opener = self.follow if follow else self.stay
        for attempt in range(4):
            try:
                with opener.open(req, timeout=timeout) as resp:
                    return resp.status, resp.read(), resp.headers, resp.geturl()
            except urllib.error.HTTPError as err:
                return err.code, err.read(), err.headers, url
            except (urllib.error.URLError, ConnectionError, TimeoutError) as err:
                if attempt == 3:
                    die(f"{path}: no answer ({err})")
                time.sleep(3)
        raise AssertionError("unreachable")

    def get(self, path, **kw):
        return self.request(path, **kw)


class FormParser(html.parser.HTMLParser):
    """Collects every form with the values a browser would submit by default."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.forms = {}
        self.form = None
        self.select = None
        self.textarea = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "form":
            self.form = {"action": a.get("action") or "", "fields": [], "files": [], "selects": {}}
            if a.get("id"):
                self.forms[a["id"]] = self.form
            return
        if self.form is None:
            return
        name = a.get("name")
        if tag == "input" and name:
            kind = (a.get("type") or "text").lower()
            if kind in ("submit", "button", "image", "reset"):
                return
            if kind == "file":
                self.form["files"].append(name)
            elif kind in ("checkbox", "radio"):
                if "checked" in a:
                    self.form["fields"].append((name, a.get("value", "on")))
            else:
                self.form["fields"].append((name, a.get("value", "")))
        elif tag == "select" and name:
            self.select = {"name": name, "first": None, "chosen": None, "options": []}
        elif tag == "option" and self.select is not None:
            value = a.get("value", "")
            self.select["options"].append(value)
            if self.select["first"] is None:
                self.select["first"] = value
            if "selected" in a:
                self.select["chosen"] = value
        elif tag == "textarea" and name:
            self.textarea = [name, ""]

    def handle_endtag(self, tag):
        if tag == "form":
            self.form = None
        elif tag == "select" and self.select is not None and self.form is not None:
            s = self.select
            value = s["chosen"] if s["chosen"] is not None else s["first"]
            self.form["selects"][s["name"]] = s["options"]
            if value is not None:
                self.form["fields"].append((s["name"], value))
            self.select = None
        elif tag == "textarea" and self.textarea is not None and self.form is not None:
            self.form["fields"].append(tuple(self.textarea))
            self.textarea = None

    def handle_data(self, data):
        if self.textarea is not None:
            self.textarea[1] += data


def form(client, path, form_id):
    status, body, _, _ = client.get(path)
    if status != 200:
        die(f"{path} answered {status}")
    parser = FormParser()
    parser.feed(body.decode("utf-8", "replace"))
    if form_id not in parser.forms:
        die(f"{path} has no form {form_id}")
    return parser.forms[form_id]


def submit(client, path, found, values, op, files=None, follow=False):
    fields = [(k, v) for k, v in found["fields"] if k not in values]
    fields += list(values.items())
    fields.append(("op", op))
    action = found["action"] or path
    if files:
        boundary = "----smoke" + secrets.token_hex(8)
        parts = []
        for k, v in fields:
            parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
        for k, (filename, content, ctype) in files.items():
            parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"; filename="{filename}"\r\n'
                         f"Content-Type: {ctype}\r\n\r\n".encode() + content + b"\r\n")
        parts.append(f"--{boundary}--\r\n".encode())
        return client.request(action, b"".join(parts), {"Content-Type": f"multipart/form-data; boundary={boundary}"}, follow=follow)
    return client.request(action, urllib.parse.urlencode(fields).encode(),
                          {"Content-Type": "application/x-www-form-urlencoded"}, follow=follow)


def login(client, password=PASSWORD):
    found = form(client, "/user/login", "user-login-form")
    status, body, headers, _ = submit(client, "/user/login", found, {"name": USER, "pass": password}, "Log in")
    return status, body.decode("utf-8", "replace"), headers.get("Location", "")


def must_login(client):
    status, body, location = login(client)
    if status not in (302, 303) or "/user/login" in location:
        die(f"administrator sign-in failed (HTTP {status})")
    status, _, _, _ = client.get("/admin/content")
    if status != 200:
        die(f"/admin/content answered {status} after sign-in")


def wait_ready(deadline_seconds=900):
    probe = Client()
    deadline = time.time() + deadline_seconds
    while time.time() < deadline:
        try:
            status, _, _, _ = probe.request("/user/login", timeout=20)
            if status == 200:
                return
        except SystemExit:
            pass
        time.sleep(5)
    die("/user/login did not answer 200 in time")


def anonymous_refusals():
    anon = Client()
    expected = {
        "/core/install.php": (403,),
        "/core/authorize.php": (403,),
        "/core/rebuild.php": (302, 403),
        "/update.php": (403,),
        "/user/register": (403,),
        "/admin": (403,),
        "/admin/content": (403,),
        "/admin/modules": (403,),
        "/admin/config/system/site-information": (403,),
        "/admin/reports/status": (403,),
        "/node/add/page": (403,),
        "/sites/default/files/php/": (403, 404),
        "/sites/default/settings.php": (403,),
        "/composer.json": (403, 404),
        "/vendor/autoload.php": (403, 404),
    }
    for path, codes in expected.items():
        status, body, _, _ = anon.get(path, follow=False)
        if status not in codes:
            die(f"anonymous {path} answered {status}, expected {codes}")
        if b"error-with-backtrace" in body or b"Stack trace" in body:
            die(f"anonymous {path} showed a backtrace")
    ok(f"{len(expected)} anonymous requests to installer, update, admin, registration and code paths are refused")
    status, body, _, _ = anon.get("/user/login")
    text = body.decode("utf-8", "replace")
    if status != 200 or 'name="pass"' not in text:
        die("the sign-in page is not served")
    if "install.php" in text and "Choose language" in text:
        die("the interactive installer is shown")


def recorded_client_address(client):
    """The hostname Drupal's log stored for the newest administrator sign-in."""
    status, body, _, _ = client.get("/admin/reports/dblog?type%5B%5D=user")
    if status != 200:
        die(f"/admin/reports/dblog answered {status}")
    events = re.findall(r'href="(/admin/reports/dblog/event/\d+)"[^>]*>(?:(?!</a>).)*Session opened for', body.decode("utf-8", "replace"), re.S)
    if not events:
        die("no 'Session opened' entry in the log")
    status, body, _, _ = client.get(events[0])
    match = re.search(r"Hostname</th>\s*<td>\s*([^<\s]+)\s*</td>", body.decode("utf-8", "replace"))
    if status != 200 or not match:
        die("the log entry has no hostname")
    return html.unescape(match.group(1))


def check_client_address(client, expected):
    address = recorded_client_address(client)
    if expected:
        if address != expected:
            die(f"Drupal recorded the sign-in from {address}, expected {expected}")
    else:
        ip = ipaddress.ip_address(address)
        if ip.is_private or ip.is_loopback or ip in ipaddress.ip_network("100.64.0.0/10"):
            die(f"Drupal recorded the sign-in from {address}, a proxy or private address")
    ok(f"Drupal recorded the sign-in from the visitor's address ({address})")


def png(seed):
    """A 4x4 PNG whose pixels come from seed, so every run uploads new bytes."""
    rows = b"".join(b"\x00" + bytes(seed[(y * 12):(y * 12) + 12]) for y in range(4))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 4, 4, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def create_page(client, title, text, moderation, publish_on=None):
    found = form(client, "/node/add/page", "node-page-form")
    if moderation not in found["selects"].get("moderation_state[0][state]", []):
        die(f"moderation state {moderation} is not offered")
    values = {"title[0][value]": title, "field_description[0][value]": text,
              "field_content[0][value]": f"<p>{text}</p>", "moderation_state[0][state]": moderation}
    if publish_on is not None:
        values["publish_on[0][value][date]"] = publish_on.strftime("%Y-%m-%d")
        values["publish_on[0][value][time]"] = publish_on.strftime("%H:%M:%S")
        values["publish_state"] = "published"
    status, body, headers, _ = submit(client, "/node/add/page", found, values, "Save")
    location = headers.get("Location", "")
    if status not in (302, 303) or not location:
        errors = re.findall(r'role="alert".*?</div>', body.decode("utf-8", "replace"), re.S)[:2]
        die(f"saving page {title!r} answered {status} {errors}")
    path = urllib.parse.urlsplit(location).path
    status, body, _, url = client.get(path)
    if status != 200 or title.encode() not in body:
        die(f"the new page is not shown to its author ({status})")
    edit = re.search(rb'href="(/node/(\d+)/edit)', body)
    if not edit:
        die("the new page has no edit link")
    return f"/node/{edit.group(2).decode()}"


def setup():
    wait_ready()
    anonymous_refusals()
    admin = Client("203.0.113.50")
    must_login(admin)
    ok("the generated administrator signs in")
    check_client_address(admin, os.environ.get("EXPECT_CLIENT_IP") or ("203.0.113.50" if CLIENT_HEADER else ""))

    token = secrets.token_hex(8)
    state = {"token": token}

    state["page"] = create_page(admin, f"Railway smoke {token}", f"Published smoke text {token}", "published")
    status, body, _, _ = Client().get(state["page"])
    if status != 200 or f"Published smoke text {token}".encode() not in body:
        die(f"anonymous visitors cannot read the published page ({status})")
    ok("a published page is visible to anonymous visitors")

    # The site's own clock, from the node form's default "authored on" value.
    found = form(admin, "/node/add/page", "node-page-form")
    fields = dict(found["fields"])
    now = datetime.datetime.strptime(f"{fields['created[0][value][date]']} {fields['created[0][value][time]']}", "%Y-%m-%d %H:%M:%S")
    state["scheduled"] = create_page(admin, f"Scheduled smoke {token}", f"Scheduled smoke text {token}", "draft",
                                     publish_on=now + datetime.timedelta(seconds=45))
    status, _, _, _ = Client().get(state["scheduled"])
    if status == 200:
        die("the scheduled page is visible before its publish time")
    ok("a draft page scheduled to publish in 45 seconds is not yet public")

    found = form(admin, "/admin/config/system/site-information", "system-site-information-settings")
    state["slogan"] = f"Smoke slogan {token}"
    status, _, _, _ = submit(admin, "/admin/config/system/site-information", found, {"site_slogan": state["slogan"]}, "Save configuration")
    if status not in (302, 303):
        die(f"saving the site slogan answered {status}")
    check_slogan(admin, state["slogan"])
    ok("the site slogan (configuration) is saved")

    logo = png(secrets.token_bytes(48))
    name = f"smoke-logo-{token}.png"
    found = form(admin, "/admin/appearance/settings", "system-theme-settings")
    # Unchecking "Use the logo supplied by the theme" (default_logo) makes
    # Drupal store the upload as the site logo.
    found["fields"] = [(k, v) for k, v in found["fields"] if k != "default_logo"]
    status, _, _, _ = submit(admin, "/admin/appearance/settings", found, {}, "Save configuration",
                             files={"files[logo_upload]": (name, logo, "image/png")})
    if status not in (302, 303):
        die(f"uploading the logo answered {status}")
    state["logo"] = f"/sites/default/files/{name}"
    state["logo_sha256"] = hashlib.sha256(logo).hexdigest()
    check_logo(state)
    ok("an uploaded logo is served from the volume to anonymous visitors, byte for byte")

    if os.environ.get("FLOOD_TEST") == "1":
        flood_test()

    deadline = time.time() + 480
    while time.time() < deadline:
        status, body, _, _ = Client().get(state["scheduled"])
        if status == 200 and f"Scheduled smoke text {token}".encode() in body:
            break
        time.sleep(10)
    else:
        die("the scheduled page was not published within 8 minutes; the cron loop did not run Scheduler")
    ok("the cron loop published the scheduled page (Scheduler ran in the background)")

    with open(STATE_FILE, "w", encoding="utf-8") as fh:
        json.dump(state, fh)


def check_slogan(client, slogan):
    found = form(client, "/admin/config/system/site-information", "system-site-information-settings")
    if dict(found["fields"]).get("site_slogan") != slogan:
        die("the site slogan is not the saved value")


def check_logo(state):
    status, body, headers, _ = Client().get(state["logo"])
    if status != 200 or hashlib.sha256(body).hexdigest() != state["logo_sha256"]:
        die(f"the uploaded logo is not served intact ({status})")


def flood_test():
    blocked, other = Client("203.0.113.61"), Client("203.0.113.62")
    for _ in range(5):
        status, body, location = login(blocked, password="wrong-" + secrets.token_hex(8))
        if status in (302, 303) and "/user/login" not in location:
            die("a wrong password signed in")
    status, body, location = login(blocked)
    if (status in (302, 303) and "/user/login" not in location) or "failed login attempts" not in body:
        die("after five failed sign-ins the same visitor could still sign in")
    status, body, location = login(other)
    if status not in (302, 303) or "/user/login" in location:
        die("another visitor was blocked by the first visitor's failed sign-ins (flood control keyed on the proxy)")
    ok("five failed sign-ins block that visitor only; another visitor still signs in")


def readback():
    with open(STATE_FILE, encoding="utf-8") as fh:
        state = json.load(fh)
    wait_ready()
    anonymous_refusals()
    admin = Client("203.0.113.50")
    must_login(admin)
    ok("the administrator password still works (the install did not run again)")
    token = state["token"]
    for key, text in (("page", f"Published smoke text {token}"), ("scheduled", f"Scheduled smoke text {token}")):
        status, body, _, _ = Client().get(state[key])
        if status != 200 or text.encode() not in body:
            die(f"the {key} page is missing after the restart ({status})")
    ok("both pages are still public")
    check_slogan(admin, state["slogan"])
    ok("the site slogan is unchanged")
    check_logo(state)
    ok("the uploaded logo is still served byte for byte")


if __name__ == "__main__":
    phase = sys.argv[1] if len(sys.argv) > 1 else ""
    if phase == "setup":
        setup()
    elif phase == "readback":
        readback()
    else:
        die("usage: smoke.py setup|readback")
    print(f"smoke: {phase} passed", flush=True)
