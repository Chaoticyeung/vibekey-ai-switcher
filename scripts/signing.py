#!/usr/bin/env python3
"""Keep one local code-signing identity across VibeKeyBridge updates."""

import os
import re
import secrets
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path


DATA = Path.home() / "Library/Application Support/VibeKeyBridge"
IDENTITY_FILE = DATA / "signing-identity.txt"
CERTIFICATE_FILE = DATA / "signing-certificate.pem"


def command(*args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"签名设置失败：{Path(args[0]).name} 返回错误。{result.stderr.strip()}")
    return result.stdout


def default_keychain():
    value = command("/usr/bin/security", "default-keychain", "-d", "user").strip()
    return value.removeprefix('"').removesuffix('"')


def available(fingerprint, keychain):
    result = subprocess.run(
        ["/usr/bin/security", "find-identity", "-v", "-p", "codesigning", keychain],
        text=True, capture_output=True,
    )
    return result.returncode == 0 and fingerprint.upper() in result.stdout.upper()


def certificate_fingerprint(certificate):
    output = command("/usr/bin/openssl", "x509", "-in", str(certificate), "-noout", "-fingerprint", "-sha1")
    match = re.search(r"=([0-9A-Fa-f:]+)", output)
    if not match:
        raise RuntimeError("无法读取本机签名证书的指纹。")
    return match.group(1).replace(":", "").upper()


def create_identity(keychain):
    DATA.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="vibekey-signing-") as temporary:
        folder = Path(temporary)
        folder.chmod(0o700)
        certificate = folder / "certificate.pem"
        key = folder / "private-key.pem"
        archive = folder / "identity.p12"
        config = folder / "certificate.cnf"
        name = f"VibeKeyBridge Local {uuid.uuid4().hex[:12]}"
        config.write_text(
            "[req]\n"
            "prompt = no\n"
            "distinguished_name = dn\n"
            "x509_extensions = extensions\n"
            "[dn]\n"
            f"CN = {name}\n"
            "O = VibeKeyBridge Local\n"
            "[extensions]\n"
            "keyUsage = critical, digitalSignature\n"
            "extendedKeyUsage = codeSigning\n"
            "basicConstraints = critical, CA:FALSE\n"
        )
        old_umask = os.umask(0o077)
        try:
            command(
                "/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:3072", "-sha256", "-nodes",
                "-days", "3650", "-config", str(config), "-keyout", str(key), "-out", str(certificate),
            )
            password = secrets.token_urlsafe(24)
            command(
                "/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(key), "-in", str(certificate),
                "-out", str(archive), "-passout", f"pass:{password}",
            )
            command(
                "/usr/bin/security", "import", str(archive), "-k", keychain, "-P", password,
                "-x",
            )
            fingerprint = certificate_fingerprint(certificate)
            shutil.copy2(certificate, CERTIFICATE_FILE)
            IDENTITY_FILE.write_text(fingerprint + "\n")
            command(
                "/usr/bin/security", "add-trusted-cert", "-p", "codeSign", "-r", "trustRoot",
                "-k", keychain, str(certificate),
            )
        finally:
            os.umask(old_umask)
    if not available(fingerprint, keychain):
        raise RuntimeError("本机签名身份尚未生效；控制程序没有被替换。")
    return fingerprint


def ensure_identity():
    keychain = default_keychain()
    if IDENTITY_FILE.exists():
        fingerprint = IDENTITY_FILE.read_text().strip().upper()
        if not re.fullmatch(r"[0-9A-F]{40}", fingerprint):
            raise RuntimeError("本机签名身份记录无效；控制程序没有被替换。")
        if available(fingerprint, keychain):
            return fingerprint
        print("原有本机签名身份目前不可用；安装已停止，旧程序没有被替换。")
        if CERTIFICATE_FILE.is_file() and certificate_fingerprint(CERTIFICATE_FILE) != fingerprint:
            raise RuntimeError("本机签名证书与记录不一致；不会信任未知证书。")
        if CERTIFICATE_FILE.is_file() and input("重新检查这张证书的代码签名信任？[y/N] ").strip().lower() in {"y", "yes"}:
            command(
                "/usr/bin/security", "add-trusted-cert", "-p", "codeSign", "-r", "trustRoot",
                "-k", keychain, str(CERTIFICATE_FILE),
            )
            if available(fingerprint, keychain):
                return fingerprint
        raise RuntimeError("原有本机签名身份不可用；不会创建新身份或覆盖已授权的程序。")

    print("首次安装将创建本机专用的代码签名证书，私钥只保存在登录钥匙串。")
    print("系统可能要求确认证书信任；从临时签名迁移后，辅助功能还需授权一次。")
    if input("继续创建本机签名身份？[y/N] ").strip().lower() not in {"y", "yes"}:
        raise RuntimeError("已取消，未修改控制程序或设备预设。")
    return create_identity(keychain)


if __name__ == "__main__":
    try:
        print("签名身份：" + ensure_identity())
    except (OSError, RuntimeError) as error:
        raise SystemExit(str(error))
