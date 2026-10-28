# Development

## Requirements

| | |
|---|---|
| container engine | `docker` (`colima` on macOS) or `podman` |
| `shellcheck` | shell linting |

macOS:

```sh
brew install colima docker shellcheck
colima start --cpu 2 --memory 2
```

Linux: `apt install docker.io shellcheck` (for `podman`, set `CONTAINER_ENGINE=podman`).

## Tests

```sh
sh tests/run.sh              # everything
sh tests/run.sh env          # only tests/test_env.sh
sh tests/run.sh --rebuild    # rebuild the stand image
sh tests/run.sh --shell      # ash inside the stand, for poking around
shellcheck -s dash tests/*.sh
```

Tests run inside a container with a real OpenWrt rootfs: busybox ash, `uci`, `/lib/functions.sh`,
plus podkop's dependencies (`jq`, `curl`, `coreutils-base64`).

Two OpenWrt branches are supported — **24.10.x** (the target) and **25.12.x** (`apk` instead of
`opkg`). Run both before handing work over:

```sh
sh tests/run.sh
OPENWRT_VERSION=25.12.4 sh tests/run.sh
```

## Building the packages

```sh
sh build.sh ipk    # .ipk for 24.10, into dist/
sh build.sh apk    # .apk for 25.12, into dist/
```

Both run the official OpenWrt SDK image in a container — the first run pulls ~2.5 GB and takes a
while. `tests/test_package.sh` installs whatever is in `dist/` next to a real podkop and skips
itself when the directory is empty, so build first if you want that test to run.

## Dev stand: podkop and LuCI in the browser

```sh
sh tests/dev.sh              # start, creating it if needed (first run ~3 min: podkop and luci)
sh tests/dev.sh --port 9090  # serve on another port
sh tests/dev.sh --stop       # stop the container, keeping it for the next start
sh tests/dev.sh --reset      # delete the container and its image, then start clean

OPENWRT_VERSION=25.12.4 PORT=8081 sh tests/dev.sh   # the apk stand, alongside the 24.10 one
```

Each OpenWrt version gets its own container, so both stands can run at once on different ports.
It prints the address and how to get inside:

```
LuCI:    http://localhost:8080/cgi-bin/luci   login root, empty password
shell:   docker exec -it podkop-sub-dev-24.10.8 /bin/sh
project: mounted at /w
```

podkop's release packages are installed there. Working: LuCI pages, `podkop show_version` /
`show_config` / `get_status`, all of `uci` on `/etc/config/podkop`.

**`nft` does not work** — the container has no netlink, so podkop cannot set up routing or pass
traffic. That part is only testable on a router.

## Releasing

A release is a pushed tag, nothing else. `.github/workflows/release.yml` builds both formats,
creates the release and attaches the packages.

```sh
git tag 0.0.1 && git push origin 0.0.1
```

The tag is a plain `<major>.<minor>.<patch>` and carries no podkop version: that comes from
`TARGET_PODKOP` in `luci-app-podkop-sub/root/usr/share/podkop-sub/version`, which the build stamps
into every file name. To target another podkop, change that file and tag a new version.

## Variables

| | |
|---|---|
| `CONTAINER_ENGINE` | `docker` (default) or `podman` |
| `OPENWRT_VERSION` | branch version, default `24.10.8` |
| `OPENWRT_IMAGE` | full image reference, when a non-standard one is needed |
| `PODKOP_VERSION` | podkop for the dev stand; defaults to `TARGET_PODKOP` from the version file |
| `PORT` | dev stand LuCI port, default `8080` (same as `--port`) |

## The supported podkop version

One file decides it:

```
luci-app-podkop-sub/root/usr/share/podkop-sub/version
    TARGET_PODKOP='0.7.24'
```

Change that line and everything follows: the build stamps it into every package name, `install.sh`
matches a release by it, the page warns when the router runs a different podkop, and the dev stand
and `tests/test_package.sh` install that version of podkop to test against. It is never written
anywhere else — not in a tag, not in a workflow.

## When the stand misbehaves

**LuCI loads but everything behind the login is empty, console shows `404` on `/ubus`** — uhttpd is
missing `ubus_prefix`; rerun `sh tests/dev.sh`.

**Random segfaults and 30-second hangs** — the stand is running under emulation. The image must
match the host architecture; `tests/image.sh` resolves ARM images by digest because OpenWrt tags
them `aarch64_generic`, which docker will not match by tag.
