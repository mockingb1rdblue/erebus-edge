"""
cf_creds.py  –  DPAPI-backed Cloudflare credential store for deploy scripts.

Usage:
    from cf_creds import get_token
    token = get_token()          # returns stored token or prompts + stores
    token = get_token(reset=True) # force re-prompt
"""

import os, sys, json, ctypes, ctypes.wintypes, getpass, pathlib

CREDS_FILE = pathlib.Path(__file__).parent.parent / "keys" / "cf_creds.dpapi"

# ── Windows DPAPI via ctypes ──────────────────────────────────────────────────

class _DATA_BLOB(ctypes.Structure):
    _fields_ = [("cbData", ctypes.wintypes.DWORD),
                ("pbData", ctypes.POINTER(ctypes.c_char))]

_crypt32 = ctypes.windll.crypt32

def _dpapi_encrypt(plaintext: str) -> bytes:
    data = plaintext.encode("utf-8")
    blob_in = _DATA_BLOB(len(data), ctypes.cast(ctypes.c_char_p(data), ctypes.POINTER(ctypes.c_char)))
    blob_out = _DATA_BLOB()
    # CRYPTPROTECT_UI_FORBIDDEN = 0x01
    ok = _crypt32.CryptProtectData(ctypes.byref(blob_in), None, None, None, None, 0x01, ctypes.byref(blob_out))
    if not ok:
        raise RuntimeError(f"CryptProtectData failed: {ctypes.GetLastError()}")
    enc = ctypes.string_at(blob_out.pbData, blob_out.cbData)
    ctypes.windll.kernel32.LocalFree(blob_out.pbData)
    return enc

def _dpapi_decrypt(ciphertext: bytes) -> str:
    blob_in = _DATA_BLOB(len(ciphertext), ctypes.cast(ctypes.c_char_p(ciphertext), ctypes.POINTER(ctypes.c_char)))
    blob_out = _DATA_BLOB()
    ok = _crypt32.CryptUnprotectData(ctypes.byref(blob_in), None, None, None, None, 0x01, ctypes.byref(blob_out))
    if not ok:
        raise RuntimeError(f"CryptUnprotectData failed: {ctypes.GetLastError()}")
    plain = ctypes.string_at(blob_out.pbData, blob_out.cbData).decode("utf-8")
    ctypes.windll.kernel32.LocalFree(blob_out.pbData)
    return plain

# ── public API ────────────────────────────────────────────────────────────────

def get_token(reset: bool = False) -> str:
    """Return the stored CF API token, prompting and saving if missing."""
    CREDS_FILE.parent.mkdir(parents=True, exist_ok=True)

    if not reset and CREDS_FILE.exists():
        try:
            data = json.loads(_dpapi_decrypt(CREDS_FILE.read_bytes()))
            return data["cf_token"]
        except Exception:
            print("[creds] Failed to decrypt stored token - re-prompting.", file=sys.stderr)

    print()
    print("Cloudflare API token required.")
    print("  Dashboard -> My Profile -> API Tokens -> Create Token")
    print("  Permissions: Account: Cloudflare Tunnel Edit, Workers Scripts Edit")
    print()
    token = getpass.getpass("CF API Token: ").strip()
    if not token:
        raise ValueError("No token provided")

    save = input("Save token (DPAPI-encrypted, tied to this Windows login)? [Y/n]: ").strip().lower()
    if save != "n":
        creds = json.dumps({"cf_token": token})
        CREDS_FILE.write_bytes(_dpapi_encrypt(creds))
        print(f"[creds] Token saved to keys/cf_creds.dpapi")

    return token


if __name__ == "__main__":
    reset = "--reset" in sys.argv
    tok = get_token(reset=reset)
    print(f"[creds] Token loaded: {tok[:8]}...{tok[-4:]}")
