"""
Signs InterviewCopilot-update.zip with Ed25519 and writes appcast.xml.
Called by GitHub Actions — no heredocs needed in the YAML.

Required env vars:
  SPARKLE_PRIVATE_KEY  — base64-encoded raw 32-byte Ed25519 private key
  VERSION              — e.g. 1.0.28
  DOWNLOAD_URL         — full URL to the .zip release asset
  FILE_SIZE            — byte size of the zip (from stat)
  PUB_DATE             — RFC-2822 date string
"""
import base64
import os

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

# ── Sign ───────────────────────────────────────────────────────────────────
pk = Ed25519PrivateKey.from_private_bytes(
    base64.b64decode(os.environ["SPARKLE_PRIVATE_KEY"])
)
with open("InterviewCopilot-update.zip", "rb") as f:
    data = f.read()
signature = base64.b64encode(pk.sign(data)).decode()
print(f"Signature: {signature}")

# ── Write appcast.xml ──────────────────────────────────────────────────────
version      = os.environ["VERSION"]
download_url = os.environ["DOWNLOAD_URL"]
file_size    = os.environ["FILE_SIZE"]
pub_date     = os.environ["PUB_DATE"]

appcast = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>CoopilotX Interview Copilot</title>
    <link>https://coopilotxai.com</link>
    <description>Most recent update for Interview Copilot</description>
    <item>
      <title>Interview Copilot {version}</title>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <pubDate>{pub_date}</pubDate>
      <enclosure
        url="{download_url}"
        sparkle:version="{version}"
        sparkle:shortVersionString="{version}"
        sparkle:edSignature="{signature}"
        length="{file_size}"
        type="application/zip"/>
    </item>
  </channel>
</rss>"""

with open("appcast.xml", "w") as f:
    f.write(appcast)

print(f"appcast.xml written for version {version}")
print(appcast)
