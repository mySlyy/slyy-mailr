# Local test servers

Integration tests (`SLYY_IT=1 swift test` in `Packages/SlyyMailKit`) run against three
local servers. Users: `alice@example.com` / `secret`, `bob@example.com` / `secret`.

| Service | Port | Software |
| --- | --- | --- |
| IMAP | 1143 (plain) | Dovecot 2.3 |
| SMTP | 1025 (plain, AUTH required) | `smtp_sink.py` (aiosmtpd), delivers to Dovecot via `dovecot-lda` |
| CalDAV | 5232 | Radicale 3 |

Ubuntu setup (as root):

```sh
apt-get install -y dovecot-imapd && pip install radicale aiosmtpd
useradd -m -u 1500 mailtest
mkdir -p /srv/slyydc/home /run/slyydc && chown mailtest /srv/slyydc/home
printf 'alice@example.com:{PLAIN}secret::::::\nbob@example.com:{PLAIN}secret::::::\n' > /srv/slyydc/users
printf 'alice@example.com:secret\nbob@example.com:secret\n' > /srv/slyydc/radicale-users
cp dovecot.conf radicale.conf /srv/slyydc/
dovecot -c /srv/slyydc/dovecot.conf
python3 -m radicale --config /srv/slyydc/radicale.conf &
python3 smtp_sink.py --port 1025 --spool /srv/slyydc/spool --lda-config /srv/slyydc/dovecot.conf &
```

These servers accept plaintext logins and must never listen beyond 127.0.0.1.
