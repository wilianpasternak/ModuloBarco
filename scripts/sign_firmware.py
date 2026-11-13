# ================================================================
#  Assina o firmware.bin (ECDSA P-256, esquema "Secure Boot V1" do
#  ESP-IDF) logo apos a geracao, substituindo o arquivo original.
#
#  O app em execucao so aceita, via OTA, imagens assinadas com a chave
#  cuja parte publica esta embutida nele (extraida da chave privada aqui).
#  O bootloader ignora a assinatura, entao o mesmo arquivo grava via USB.
#
#  A chave privada fica em pescaplus_signing_key.pem (NUNCA commitar).
# ================================================================
Import("env")  # noqa: F821  (fornecido pelo PlatformIO/SCons)

import os
import subprocess
import sys

PROJECT_DIR = env.subst("$PROJECT_DIR")  # noqa: F821
KEY = os.path.join(PROJECT_DIR, "pescaplus_signing_key.pem")
PYTHON = env.subst("$PYTHONEXE")  # noqa: F821


def _espsecure():
    pkg = env.PioPlatform().get_package_dir("tool-esptool")  # noqa: F821
    exe = os.path.join(pkg, "espsecure") if pkg else ""
    if exe and os.path.isfile(exe):
        return [exe]
    return [PYTHON, "-m", "espsecure"]


def sign_firmware(source, target, env):
    binfile = str(target[0])
    signed = binfile + ".signed"
    cmd = _espsecure() + [
        "sign-data", "--version", "1", "--keyfile", KEY, "-o", signed, binfile,
    ]
    print("Assinando %s (ECDSA)..." % os.path.basename(binfile))
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout + result.stderr)
        env.Exit(1)
    os.replace(signed, binfile)
    print("Firmware assinado: %s" % binfile)


def _require_key():
    if not os.path.isfile(KEY):
        sys.stderr.write(
            "\nERRO: chave de assinatura nao encontrada: %s\n"
            "      Gere com: python3 -m espsecure generate-signing-key --version 1 "
            "pescaplus_signing_key.pem\n"
            "      (veja docs/FIRMWARE.md)\n\n" % KEY
        )
        env.Exit(1)  # noqa: F821


def extract_public_key(dest):
    """Gera a chave publica que o IDF embute no app (o CMake do IDF faria
    isso com um custom command que o SCons do PlatformIO nao executa)."""
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    cmd = _espsecure() + ["extract-public-key", "--version", "1", "--keyfile", KEY, dest]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout + result.stderr)
        env.Exit(1)  # noqa: F821


_require_key()

# O build do bootloader do IDF exige o caminho da chave (-DSECURE_BOOT_SIGNING_KEY);
# o PlatformIO repassa este valor do env.
env["PIO_ESP32_SECURE_BOOT_SIGNING_KEY"] = KEY  # noqa: F821

def write_embed_asm(binpath, dest):
    """O bootloader do IDF tambem lista a chave como dado embutido (mesmo sem
    usa-la quando nao ha verificacao no boot), mas o PlatformIO so gera o .S
    para o app. Gera aqui no mesmo formato do IDF."""
    data = open(binpath, "rb").read()
    lines = [
        "/* * Data converted from %s (scripts/sign_firmware.py) */" % binpath,
        ".data",
        "#if !defined (__APPLE__) && !defined (__linux__)",
        ".section .rodata.embedded",
        "#endif",
        "",
        ".global signature_verification_key_bin",
        "signature_verification_key_bin:",
        "",
        ".global _binary_signature_verification_key_bin_start",
        "_binary_signature_verification_key_bin_start:",
    ]
    for i in range(0, len(data), 16):
        lines.append(".byte " + ", ".join("0x%02x" % b for b in data[i:i + 16]))
    lines += [
        "",
        ".global _binary_signature_verification_key_bin_end",
        "_binary_signature_verification_key_bin_end:",
        "",
        ".global signature_verification_key_bin_length",
        "signature_verification_key_bin_length:",
        ".word %d" % len(data),
        "",
    ]
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "w") as f:
        f.write("\n".join(lines))


BUILD_DIR = env.subst("$BUILD_DIR")  # noqa: F821
_pubkey = os.path.join(BUILD_DIR, "signature_verification_key.bin")
extract_public_key(_pubkey)
write_embed_asm(_pubkey, os.path.join(BUILD_DIR, "bootloader", "signature_verification_key.bin.S"))

env.AddPostAction("$BUILD_DIR/${PROGNAME}.bin", sign_firmware)  # noqa: F821
