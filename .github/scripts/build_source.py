"""Build source.json (AltStore/SideStore source format) from the GitHub releases.

Usage: python3 build_source.py <owner/repo> <output dir>

Every published release that has an .ipa and app-info.json (written by
build.yml) becomes one entry in "versions", newest first. The SHA-256 of
the IPA is checked against the digest that GitHub reports for the asset.
"""
import json
import os
import sys
import urllib.request

REPO = sys.argv[1]
OUT = sys.argv[2]
OWNER, NAME = REPO.split("/")
PAGES = f"https://{OWNER.lower()}.github.io/{NAME}"
TOKEN = os.environ.get("GH_TOKEN", "")

APP_NAME = "CocoLauncher"
DEVELOPER = "Coco Cobblemon"
TINT = "#3E8EDE"
SUBTITLE = "Chơi Coco Cobblemon (Minecraft Java) trên iPhone/iPad"
DESCRIPTION = (
    "CocoLauncher là launcher Minecraft: Java Edition cấu hình sẵn cho server Coco Cobblemon "
    "(bản sửa của Angel Aura Amethyst, mã nguồn mở GPLv3).\n\n"
    "- Tự tạo profile Coco (Minecraft 1.21.1 + Fabric) và tự tải gói Coco Lite.\n"
    "- Cần tài khoản Microsoft ĐÃ MUA Minecraft: Java Edition để tải game lần đầu.\n"
    "- Cần JIT: cài LocalDevVPN (App Store) và StikDebug.\n"
    "- Khuyên máy 8 GB RAM.\n\n"
    "Mã nguồn: https://github.com/" + REPO + "\n\n"
    "A Minecraft: Java Edition launcher preconfigured for the Coco Cobblemon server. "
    "Requires a Microsoft account that owns Minecraft: Java Edition, and JIT."
)


def api(path):
    req = urllib.request.Request(
        f"https://api.github.com/{path}",
        headers={
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cocolauncher-pages",
            **({"Authorization": f"Bearer {TOKEN}"} if TOKEN else {}),
        },
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def download_asset(asset):
    # Through the API asset endpoint, not browser_download_url: github.com/.../releases/download
    # can be down while the API still works (2026-11-08). The token is not forwarded on the redirect.
    req = urllib.request.Request(asset["url"], headers={"User-Agent": "cocolauncher-pages", "Accept": "application/octet-stream"})
    if TOKEN:
        req.add_unredirected_header("Authorization", f"Bearer {TOKEN}")
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


# Fixed download link that tries GitHub first and falls back to a Cloudflare R2 copy. It serves the copy
# kept in the "ios" release of Coconubs/cocolauncher-pack, so it is used only while that copy is the
# same file (same SHA-256) as the newest release here; otherwise the GitHub link stays.
MIRROR_IPA_URL = "https://tai.coconubs.workers.dev/ios/CocoLauncher-iOS.ipa"


def mirror_copy_sha256():
    try:
        rel = api("repos/Coconubs/cocolauncher-pack/releases/tags/ios")
    except Exception as e:  # no copy yet / API error -> keep the GitHub link
        print(f"mirror copy check skipped: {e}")
        return ""
    asset = next((a for a in rel.get("assets", []) if a["name"] == "CocoLauncher-iOS.ipa"), None)
    return (asset.get("digest") or "").removeprefix("sha256:") if asset else ""


versions = []
latest_info = None
for rel in api(f"repos/{REPO}/releases?per_page=50"):
    if rel.get("draft"):
        continue
    assets = {a["name"]: a for a in rel.get("assets", [])}
    ipa = next((a for n, a in assets.items() if n.endswith(".ipa")), None)
    info_asset = assets.get("app-info.json")
    if ipa is None or info_asset is None:
        print(f"skip {rel['tag_name']}: no IPA or app-info.json")
        continue
    info = json.loads(download_asset(info_asset))
    digest = (ipa.get("digest") or "").removeprefix("sha256:")
    if digest and digest != info["sha256"]:
        print(f"skip {rel['tag_name']}: sha256 of the IPA asset ({digest}) != app-info.json ({info['sha256']})")
        continue
    if ipa["size"] != info["size"]:
        print(f"skip {rel['tag_name']}: size of the IPA asset ({ipa['size']}) != app-info.json ({info['size']})")
        continue
    notes = (rel.get("body") or "").strip() or f"CocoLauncher {info['version']}"
    versions.append({
        "version": info["version"],
        "buildVersion": str(info.get("buildVersion", "1")),
        "date": rel["published_at"],
        "localizedDescription": notes[:3000],
        "downloadURL": ipa["browser_download_url"],
        "size": ipa["size"],
        "sha256": info["sha256"],
        "minOSVersion": info.get("minOSVersion", "14.0"),
    })
    if latest_info is None:
        latest_info = info
    print(f"add {rel['tag_name']}: {ipa['browser_download_url']} ({ipa['size']} bytes)")

if versions:
    mirror_sha = mirror_copy_sha256()
    if mirror_sha and mirror_sha == versions[0]["sha256"]:
        versions[0]["downloadURL"] = MIRROR_IPA_URL
        print(f"newest version {versions[0]['version']}: download through {MIRROR_IPA_URL}")
    else:
        print(f"newest version {versions[0]['version']}: mirror copy differs ({mirror_sha or 'none'}), keeping the GitHub link")

apps = []
if versions:
    latest = versions[0]
    apps.append({
        "name": APP_NAME,
        "bundleIdentifier": latest_info["bundleIdentifier"],
        "developerName": DEVELOPER,
        "subtitle": SUBTITLE,
        "localizedDescription": DESCRIPTION,
        "iconURL": f"{PAGES}/icon.png",
        "tintColor": TINT,
        "category": "games",
        "screenshotURLs": [],
        "versions": versions,
        "appPermissions": {
            "entitlements": latest_info.get("entitlements", []),
            "privacy": latest_info.get("privacy", {}),
        },
        # Older AltStore/SideStore versions read these fields
        "version": latest["version"],
        "buildVersion": latest["buildVersion"],
        "versionDate": latest["date"],
        "versionDescription": latest["localizedDescription"],
        "downloadURL": latest["downloadURL"],
        "size": latest["size"],
    })

source = {
    "name": "Coco Cobblemon",
    "identifier": "dev.coconubs.cocolauncher.source",
    "subtitle": "CocoLauncher cho iPhone/iPad",
    "description": "Nguồn chính thức của CocoLauncher iOS (server Coco Cobblemon). Mã nguồn: https://github.com/" + REPO,
    "iconURL": f"{PAGES}/icon.png",
    "website": f"{PAGES}/",
    "sourceURL": f"{PAGES}/source.json",
    "tintColor": TINT,
    "featuredApps": [a["bundleIdentifier"] for a in apps],
    "apps": apps,
    "news": [],
}

os.makedirs(OUT, exist_ok=True)
with open(os.path.join(OUT, "source.json"), "w", encoding="utf-8") as f:
    json.dump(source, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"wrote {OUT}/source.json with {len(versions)} version(s)")
