"""Exercise Sparkle's installer against two isolated, signed copies of CCS."""

import base64
import functools
import http.server
import os
import plistlib
import subprocess
import tempfile
import threading
import uuid
from pathlib import Path


def run(*args, **kwargs):
    return subprocess.run(args, check=True, timeout=120, **kwargs)


def rehearse(work, feed, base_url):
    root = Path(__file__).resolve().parents[1]
    app = root / "build/CCS.app"
    framework_dir = app / "Contents/Frameworks"
    source = root / ".build/checkouts/Sparkle/sparkle-cli"
    tools = root / ".build/artifacts/sparkle/Sparkle/bin"
    identity = os.environ["CCS_SIGN_IDENTITY"]
    client = work / "sparkle-cli"
    client_info = work / "client.plist"
    client_info.write_bytes(plistlib.dumps(dict(CFBundleIdentifier="io.github.alexamber.ccs.update-test",
                                                CFBundleName="CCS Update Test", CFBundleVersion="1")))
    run("xcrun", "clang", "-fobjc-arc", "-DSPU_OBJC_DIRECT=__attribute__((objc_direct))",
        "-DSPU_OBJC_DIRECT_MEMBERS=__attribute__((objc_direct_members))",
        "-F", framework_dir, "-framework", "Sparkle", "-framework", "Cocoa",
        "-Xlinker", "-rpath", "-Xlinker", framework_dir, "-Wl,-sectcreate,__TEXT,__info_plist," + str(client_info),
        *sorted(source.glob("*.m")), "-o", client)
    run("codesign", "--force", "--sign", identity, "--options", "runtime", client)

    # Sparkle accepts an Ed25519 seed on stdin. Keep this throwaway key in memory.
    keys = run("xcrun", "swift", "-e",
               "import CryptoKit; import Foundation; let k = Curve25519.Signing.PrivateKey(); "
               "print(k.rawRepresentation.base64EncodedString(), k.publicKey.rawRepresentation.base64EncodedString())",
               capture_output=True).stdout.split()
    private, public = keys
    assert len(base64.b64decode(public)) == 32
    identifier = "io.github.alexamber.ccs.rehearsal." + uuid.uuid4().hex
    installed = work / "installed/CCS.app"
    candidate = work / "candidate/CCS.app"
    info = Path("Contents/Info.plist")
    for bundle, version in [(installed, "1"), (candidate, "2")]:
        bundle.parent.mkdir()
        run("ditto", app, bundle)
        settings = plistlib.loads((bundle / info).read_bytes())
        settings.update(CFBundleIdentifier=identifier, CFBundleVersion=version,
                        SUPublicEDKey=public.decode(), SUFeedURL=base_url + "appcast.xml")
        (bundle / info).write_bytes(plistlib.dumps(settings))
        run("codesign", "--force", "--sign", identity, "--options", "runtime",
            "--entitlements", root / "macOS/CCS.entitlements", bundle)

    archive = feed / "CCS.zip"
    run("ditto", "-c", "-k", "--keepParent", candidate, archive)
    run(tools / "generate_appcast", "--ed-key-file", "-", "--download-url-prefix", base_url,
        feed, input=private)
    command = [client, "--check-immediately", "--verbose", installed]

    tamper_test = work / "tamper-test/CCS.app"
    tamper_test.parent.mkdir()
    run("ditto", installed, tamper_test)
    run(*command)
    if plistlib.loads((installed / info).read_bytes())["CFBundleVersion"] != "2":
        raise RuntimeError("Sparkle did not install build 2")
    run("codesign", "--verify", "--strict", "--deep", installed)
    run(installed / "Contents/MacOS/ccs", "--version")
    current = subprocess.run(command, timeout=120)
    if current.returncode != 4:  # sparkle-cli's no-update status
        raise RuntimeError("Sparkle did not recognize the installed build as current")

    # A same-length change to the archive must fail before installation.
    with archive.open("r+b") as handle:
        original = handle.read(1)
        handle.seek(0)
        handle.write(bytes([original[0] ^ 1]))
    rejected = subprocess.run([client, "--check-immediately", "--verbose", tamper_test], timeout=120, capture_output=True, text=True)
    print(rejected.stderr, flush=True)
    if (rejected.returncode != 1 or "improperly signed" not in rejected.stderr
            or plistlib.loads((tamper_test / info).read_bytes())["CFBundleVersion"] != "1"):
        raise RuntimeError("Sparkle did not reject the altered archive and retain build 1")
    print("Passed: altered archive rejected, build 1 upgraded to build 2, installed build current.")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="ccs-update-", dir="build") as directory:
        work = Path(directory).resolve()
        feed = work / "feed"
        feed.mkdir()
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(feed))
        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                rehearse(work, feed, f"http://127.0.0.1:{server.server_port}/")
            finally:
                server.shutdown()
