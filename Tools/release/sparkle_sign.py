#!/usr/bin/env python3
"""Sparkle update signing for Slyy Mailr (EdDSA / Ed25519, as Sparkle 2 verifies it).

The private key is the base64 of a 32-byte Ed25519 seed, read from $SPARKLE_PRIVATE_KEY.
Create one once and keep a copy in your password manager — losing it means installed
apps can no longer be updated automatically:

    head -c 32 /dev/urandom | base64 | gh secret set SPARKLE_PRIVATE_KEY -R mySlyy/slyy-mailr

Commands:
    public                        print the public key (goes into SUPublicEDKey)
    sign FILE                     print the base64 signature of FILE
    appcast --dmg ... --version   print a one-item appcast.xml for the release
    verify APPCAST DMG            check the appcast's signature and length against the DMG
"""
import argparse
import base64
import email.utils
import os
import sys
from xml.sax.saxutils import escape, quoteattr

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def private_key() -> Ed25519PrivateKey:
    raw = os.environ.get("SPARKLE_PRIVATE_KEY", "").strip()
    if not raw:
        sys.exit("SPARKLE_PRIVATE_KEY is not set")
    seed = base64.b64decode(raw)
    if len(seed) not in (32, 64):
        sys.exit(f"SPARKLE_PRIVATE_KEY must be base64 of 32 bytes (got {len(seed)})")
    return Ed25519PrivateKey.from_private_bytes(seed[:32])


def public_key(key: Ed25519PrivateKey) -> str:
    raw = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return base64.b64encode(raw).decode()


def sign(key: Ed25519PrivateKey, path: str) -> str:
    with open(path, "rb") as f:
        return base64.b64encode(key.sign(f.read())).decode()


def appcast(key: Ed25519PrivateKey, a: argparse.Namespace) -> str:
    length = os.path.getsize(a.dmg)
    sig = sign(key, a.dmg)
    date = email.utils.formatdate(usegmt=True)
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Slyy Mailr</title>
    <link>https://github.com/mySlyy/slyy-mailr</link>
    <item>
      <title>{escape("Slyy Mailr " + a.version)}</title>
      <pubDate>{date}</pubDate>
      <sparkle:version>{escape(a.build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(a.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(a.min_os)}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>{escape(a.notes)}</sparkle:releaseNotesLink>
      <enclosure url={quoteattr(a.url)} length="{length}" type="application/octet-stream" sparkle:edSignature="{sig}"/>
    </item>
  </channel>
</rss>
"""


def verify(key: Ed25519PrivateKey, appcast_path: str, dmg: str) -> None:
    import xml.etree.ElementTree as ET
    ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    enc = ET.parse(appcast_path).getroot().find("channel/item/enclosure")
    data = open(dmg, "rb").read()
    if int(enc.get("length")) != len(data):
        sys.exit("appcast length does not match the DMG")
    key.public_key().verify(base64.b64decode(enc.get(ns + "edSignature")), data)
    print("appcast signature OK")


def main() -> None:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("public")
    s = sub.add_parser("sign")
    s.add_argument("file")
    c = sub.add_parser("appcast")
    c.add_argument("--dmg", required=True)
    c.add_argument("--version", required=True)
    c.add_argument("--build", required=True)
    c.add_argument("--url", required=True)
    c.add_argument("--notes", required=True)
    c.add_argument("--min-os", default="14.0")
    v = sub.add_parser("verify")
    v.add_argument("appcast")
    v.add_argument("dmg")
    a = p.parse_args()
    key = private_key()
    if a.cmd == "public":
        print(public_key(key))
    elif a.cmd == "sign":
        print(sign(key, a.file))
    elif a.cmd == "verify":
        verify(key, a.appcast, a.dmg)
    else:
        sys.stdout.write(appcast(key, a))


if __name__ == "__main__":
    main()
