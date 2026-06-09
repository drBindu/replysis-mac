"""
Ed25519 signing script for NetSparkle appcast.
Called by GitHub Actions: python3 sign_sparkle.py
Reads SPARKLE_PRIVATE_KEY env var, signs InterviewCopilot-update.zip,
prints base64 signature to stdout.
"""
import base64
import os
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

pk = Ed25519PrivateKey.from_private_bytes(
    base64.b64decode(os.environ["SPARKLE_PRIVATE_KEY"])
)
with open("InterviewCopilot-update.zip", "rb") as f:
    data = f.read()
print(base64.b64encode(pk.sign(data)).decode())
