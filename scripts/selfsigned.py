#!/usr/bin/env python3
"""Создаёт самоподписанный сертификат (fullchain.pem + privkey.pem).

Запускается ВНУТРИ контейнера certbot/certbot: там уже есть python3 и библиотека
cryptography, поэтому на хосте ничего ставить не нужно.

    python3 selfsigned.py --out /etc/letsencrypt/live/example.org --cn example.org [--days 1] [--if-missing]
"""
import argparse
import datetime
import ipaddress
import os
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--cn", required=True)
    ap.add_argument("--days", type=int, default=1)
    ap.add_argument("--if-missing", action="store_true", help="ничего не делать, если сертификат уже есть")
    args = ap.parse_args()

    cert_path = os.path.join(args.out, "fullchain.pem")
    key_path = os.path.join(args.out, "privkey.pem")
    if args.if_missing and os.path.exists(cert_path) and os.path.exists(key_path):
        print(f"selfsigned: {cert_path} уже существует, пропускаю")
        return 0

    os.makedirs(args.out, exist_ok=True)
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, args.cn)])
    sans = [x509.DNSName(args.cn)]
    if args.cn == "localhost":
        sans += [x509.IPAddress(ipaddress.ip_address("127.0.0.1")), x509.IPAddress(ipaddress.ip_address("::1"))]
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=5))
        .not_valid_after(now + datetime.timedelta(days=args.days))
        .add_extension(x509.SubjectAlternativeName(sans), critical=False)
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )
    with open(key_path, "wb") as f:
        f.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    os.chmod(key_path, 0o600)
    with open(cert_path, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))
    # chain.pem нужен для ssl_trusted_certificate (OCSP stapling)
    with open(os.path.join(args.out, "chain.pem"), "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))
    print(f"selfsigned: создан сертификат для {args.cn} на {args.days} дн. в {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
