# Design capture verification

Audience: maintainer verification.

This record supports the active real-browser, exact-viewport, staged-artifact, destination-copy, bounded-readiness, and process-group cleanup guarantees in `bin/fm-capture.sh`.
The executable's header and `--help` own current mechanics.
The design-directions skill owns when the fleet uses those mechanics.

## Environment

The real-browser pass ran on 2026-07-31 on Darwin 25.3.0 arm64 with `chrome-devtools-axi` 0.1.27, Python 3.13.14, and curl 8.7.1.
The exact version commands and output were:

```text
$ export PATH="$HOME/.npm-global/bin:$PATH"
$ chrome-devtools-axi --version
0.1.27
$ python3 --version
Python 3.13.14
$ curl --version | sed -n '1p'
curl 8.7.1 (x86_64-apple-darwin25.0) libcurl/8.7.1 (SecureTransport) LibreSSL/3.3.6 zlib/1.2.12 nghttp2/1.68.0
$ uname -srm
Darwin 25.3.0 arm64
```

## Executable failure semantics

The focused executable suite uses a real loopback static server and a browser-command test double.
It exercises bounded timeout diagnostics, missing and empty zero-exit screenshots, `/tmp` staging, byte-verified copies, mismatched pixel dimensions, process-group descendants, and an unrelated live server.

```text
$ export PATH="$HOME/.npm-global/bin:$PATH"
$ tests/fm-capture.test.sh
ok - fm-capture bounds readiness diagnostics and cleans only its recorded process group
ok - fm-capture rejects missing and empty screenshot artifacts
ok - fm-capture stages under /tmp and verifies the destination copy
ok - fm-capture rejects a non-empty but corrupt destination copy
ok - fm-capture rejects screenshots whose pixels do not match the viewport matrix
```

## Real static browser pass

The tracked fixture includes a responsive static page, a real SVG image, a build check, a readiness text gate, both standard viewports, a preparation script, and a visible-state selector.
The following exact command captured it through the installed browser bridge:

```sh
export PATH="$HOME/.npm-global/bin:$PATH"
mkdir -p /tmp/fm-design-directions-build-b1/verified-emulated-output \
  /tmp/fm-design-directions-build-b1/verified-emulated-evidence
bin/fm-capture.sh \
  --contract tests/fixtures/fm-capture-static/serve.json \
  --matrix tests/fixtures/fm-capture-static/matrix.json \
  --workdir tests/fixtures/fm-capture-static \
  --output-dir /tmp/fm-design-directions-build-b1/verified-emulated-output \
  --task-temp /tmp/fm-design-directions-build-b1/verified-emulated-evidence \
  --session design-directions-build-b1-emulated \
  --deadline 10
```

Exact output:

```text
capture complete: 2 artifact(s) verified in /private/tmp/fm-design-directions-build-b1/verified-emulated-output
capture evidence: /private/tmp/fm-design-directions-build-b1/verified-emulated-evidence/fm-capture-design-directions-build-b1-emulated-20260731T155421-69283
```

The following post-run check asserted non-empty outputs, byte equality with the retained `/tmp` staging files, recorded-process-group termination, and exact PNG dimensions before stopping the exact named browser session used by the verification:

```sh
verified_meta=$(find /tmp/fm-design-directions-build-b1/verified-emulated-evidence -name run.meta -type f -print -quit)
verified_run=$(dirname "$verified_meta")
bridge_port=$(sed -n 's/^bridge_port=//p' "$verified_meta")
server_pgid=$(sed -n 's/^server_pgid=//p' "$verified_meta")
test -s /tmp/fm-design-directions-build-b1/verified-emulated-output/desktop-hero.png
test -s /tmp/fm-design-directions-build-b1/verified-emulated-output/mobile-active.png
cmp -s "$verified_run/staging/desktop-hero.png" \
  /tmp/fm-design-directions-build-b1/verified-emulated-output/desktop-hero.png
cmp -s "$verified_run/staging/mobile-active.png" \
  /tmp/fm-design-directions-build-b1/verified-emulated-output/mobile-active.png
if python3 - "$server_pgid" <<'PY' 2>/dev/null
import os
import sys
os.killpg(int(sys.argv[1]), 0)
PY
then
  printf 'server_group=alive\n'
else
  printf 'server_group=terminated\n'
fi
sips -g pixelWidth -g pixelHeight \
  /tmp/fm-design-directions-build-b1/verified-emulated-output/desktop-hero.png \
  /tmp/fm-design-directions-build-b1/verified-emulated-output/mobile-active.png
printf 'staged_destination_cmp=ok\n'
CHROME_DEVTOOLS_AXI_SESSION=design-directions-build-b1-emulated \
CHROME_DEVTOOLS_AXI_PORT="$bridge_port" \
  chrome-devtools-axi stop
```

Exact output:

```text
server_group=terminated
/private/tmp/fm-design-directions-build-b1/verified-emulated-output/desktop-hero.png
  pixelWidth: 1440
  pixelHeight: 900
/private/tmp/fm-design-directions-build-b1/verified-emulated-output/mobile-active.png
  pixelWidth: 390
  pixelHeight: 844
staged_destination_cmp=ok
status: stopped
```

Both captures were also inspected at original resolution.
The desktop image rendered the intended two-column composition and the mobile image rendered the responsive single-column composition with the prepared state visibly active.
