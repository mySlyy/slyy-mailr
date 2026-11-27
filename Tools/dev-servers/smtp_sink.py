"""Local SMTP submission server for development and integration tests.

Accepts AUTH PLAIN/LOGIN without TLS on 127.0.0.1, stores each message in
--spool, and (optionally) delivers it to a local Dovecot via dovecot-lda so the
IMAP side sees it. Never expose this beyond localhost.

    python3 smtp_sink.py --port 1025 --spool /tmp/spool --lda-config /srv/slyydc/dovecot.conf
"""
import argparse
import asyncio
import pathlib
import subprocess
import time

from aiosmtpd.controller import Controller
from aiosmtpd.smtp import AuthResult, LoginPassword

USERS = {"alice@example.com": "secret", "bob@example.com": "secret"}


class Handler:
    def __init__(self, spool: pathlib.Path, lda_config: str | None):
        self.spool = spool
        self.lda_config = lda_config

    async def handle_DATA(self, server, session, envelope):
        name = f"{time.time_ns()}.eml"
        (self.spool / name).write_bytes(envelope.original_content)
        (self.spool / (name + ".rcpt")).write_text("\n".join(envelope.rcpt_tos))
        if self.lda_config:
            # Like a real MTA's final delivery: record the envelope sender as Return-Path.
            delivered = b"Return-Path: <" + envelope.mail_from.encode() + b">\r\n" + envelope.original_content
            for rcpt in envelope.rcpt_tos:
                if rcpt.lower() in USERS:
                    subprocess.run(
                        ["/usr/lib/dovecot/dovecot-lda", "-c", self.lda_config, "-d", rcpt.lower(), "-f", envelope.mail_from],
                        input=delivered, check=False,
                    )
        return "250 OK queued"


def authenticator(server, session, envelope, mechanism, auth_data):
    if isinstance(auth_data, LoginPassword):
        user = auth_data.login.decode()
        if USERS.get(user.lower()) == auth_data.password.decode():
            return AuthResult(success=True)
    return AuthResult(success=False, handled=False)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=1025)
    p.add_argument("--spool", default="./spool")
    p.add_argument("--lda-config")
    a = p.parse_args()
    spool = pathlib.Path(a.spool)
    spool.mkdir(parents=True, exist_ok=True)
    c = Controller(
        Handler(spool, a.lda_config), hostname="127.0.0.1", port=a.port,
        authenticator=authenticator, auth_require_tls=False, auth_required=True,
        data_size_limit=50 * 1024 * 1024,
    )
    c.start()
    print(f"SMTP sink on 127.0.0.1:{a.port}, spool {spool}", flush=True)
    try:
        asyncio.get_event_loop().run_forever()
    except KeyboardInterrupt:
        c.stop()


if __name__ == "__main__":
    main()
