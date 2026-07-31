# Browser-based fetching

Some sources need a real browser: JS-rendered pages, or hosts that reject `curl`.
Playwright is installed and working on this machine.

## Setup, already done

```
npx playwright install chromium          # browsers only, no sudo
```

Chromium needed exactly one system library that was missing, `libasound.so.2`. Installed
**without sudo** by extracting the Ubuntu package into a user directory:

```
apt-get download libasound2t64            # no root needed
dpkg-deb -x libasound2t64_*.deb /tmp/pw/libs/root
export LD_LIBRARY_PATH=/tmp/pw/libs/root/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
```

After that `ldd .../chrome-linux64/chrome | grep -c 'not found'` returns 0. If the extracted
directory is cleaned up, repeat those three lines. Making it permanent means moving the
`.so` somewhere stable under `~/.local/lib` and exporting the path from a shell profile.

## What this does and does not solve

**Solves:** pages that need JavaScript to render, hosts that block `curl` by User-Agent,
and anything requiring cookies established by a prior navigation.

**Does not solve:** Cloudflare's JS interrogation. `dl.acm.org` returns HTTP 403 with the
title "Just a moment..." to headless Chromium, on both the PDF URL and the DOI landing page,
including with `--disable-blink-features=AutomationControlled` and a patched
`navigator.webdriver`.

Defeating that would need stealth plugins or challenge-solving, which is deliberate evasion
of an anti-bot control rather than automation of the intended access path. **Not done, and
should not be.** The two affected papers are open access and take one manual browser click
each; see the known-gaps section of `docs/phases/00-compiler-research/PLAN.md` for their
DOIs.
