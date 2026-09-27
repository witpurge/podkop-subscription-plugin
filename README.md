# luci-app-podkop-sub

*[Русская версия](README.ru.md)*

A plugin for [podkop](https://github.com/itdoginfo/podkop) on OpenWrt: a LuCI page that keeps
podkop's sections filled from VPN subscriptions.

podkop routes traffic through the proxy links you paste into its sections by hand. This plugin
takes those links from a subscription URL instead, writes the ones you choose into the sections you
choose, and keeps them working: a background service pings the node your traffic actually uses and
moves you to a working one when it stops answering.

## Install

podkop must already be installed.

```sh
wget -O /tmp/podkop-sub-install.sh https://github.com/witpurge/Podkop-subscription-plugin/releases/latest/download/install.sh && sh /tmp/podkop-sub-install.sh
```

The script picks `.apk` or `.ipk` for your OpenWrt and installs the release built for your podkop
version. A package downloaded by hand installs just as well:

```sh
apk add --allow-untrusted ./luci-app-podkop-sub-<version>-podkop<podkop>.apk   # 25.12
opkg install ./luci-app-podkop-sub_<version>_podkop<podkop>_all.ipk            # 24.10
```

Then open **Services → Podkop Subscriptions**, reloading with Ctrl+Shift+R because the browser
caches LuCI pages.

## Uninstall

Keep your subscriptions and settings, so a reinstall picks them back up:

```sh
wget -O /tmp/podkop-sub-uninstall.sh https://github.com/witpurge/Podkop-subscription-plugin/releases/latest/download/uninstall.sh && sh /tmp/podkop-sub-uninstall.sh
```

Remove everything, including the subscriptions, the cache and the `sysupgrade.conf` entries:

```sh
wget -O /tmp/podkop-sub-uninstall.sh https://github.com/witpurge/Podkop-subscription-plugin/releases/latest/download/uninstall.sh && sh /tmp/podkop-sub-uninstall.sh --purge
```

Either way podkop's sections go back to exactly what they held before the plugin touched them.

### Flags

| | |
|---|---|
| `install.sh -t <tag>` | install that release instead of the one built for your podkop |
| `install.sh --file <package>` | install a local `.ipk`/`.apk`, without contacting GitHub |
| `uninstall.sh --purge` | also delete `/etc/config/podkop-sub`, `/etc/podkop-sub/` and their `sysupgrade.conf` lines |

Without `--purge` the settings are kept on purpose, the same way opkg keeps a modified conffile.

## Quick start

1. **Services → Podkop Subscriptions → Add subscription.** Give it a name and paste the
   subscription URL.
2. **Refresh.** This downloads the subscription and reads its node list. Nothing is written to
   podkop yet.
3. **Nodes.** Pick the ones you want. Leave the field empty to use all of them — but watch the line
   underneath, which says how many outbounds that makes: nodes × sections. A large subscription
   spread over several sections can be more than sing-box will start with.
4. **podkop sections.** Choose which sections this subscription fills.
5. **Configuration type.** Selector or URLTest, per section.
6. **Save & Apply.** The links are written into podkop and podkop is restarted. A restart puts
   every section on its first node, so pick the one you want in podkop's own dashboard afterwards.

Start with a section you do not depend on. If anything goes wrong, clearing the subscription's
sections and saving puts that section back as it was.

## When a node stops working

The service checks every **check interval** minutes (60 by default). A healthy check costs one
ping and changes nothing — no download, no config write, no podkop restart.

**The node being tested is the one carrying your traffic** — whatever the selector currently points
at, not a random one. A URLTest section chooses for itself, so there it tests the section instead.

1. **It answers.** Done.
2. **It does not.** The plugin walks the section's other nodes in order, testing each, and switches
   the selector to the first that answers. It remembers that this node is *its* choice, not yours,
   and stays on it while it answers: the other nodes are tried again only if it dies too.
3. **Then the subscriptions are re-read** — without touching podkop. Node identity is the
   **title**, so your node is found in the fresh list even if the provider moved it, and the plugin
   checks its fresh link for reachability itself — changed or not, the server may simply be back.
4. **The fresh link answers.** It is written into podkop — the one restart of the whole sequence —
   and the selector goes back to your node. If it is the very link podkop already has, there is
   nothing to write: podkop itself is asked whether the server is back, and if it is, the selector
   returns to it without a restart. If the link does not answer, nothing changes: the reserve keeps
   the traffic and the next check tries again.
5. **Your node answers again** on its own. The selector goes back to it by itself.
6. **No node in the section answers.** Step 3 runs for every node the check tried, and with nothing
   left to lose, even a new link that cannot be checked (hy2) is applied. If none of them revives
   and the check tried the whole section, the plugin looks through the rest of the subscription for
   a node you did not pick, checking each for reachability *without touching podkop*, and borrows
   the first one that answers: it is written into the section, podkop restarts once, and the node
   is verified properly.
7. **One of your own nodes comes back.** The borrowed node is removed and the section returns to
   your selection alone.

Every step is written to the debug log with the node's name, and the page shows a notice while a
section is running on anything other than your own choice. A subscription is re-downloaded only
when a node stopped answering (once per check at most), or when you press Refresh or Update now,
and podkop restarts only for a link that answered — a working setup is never touched.

All of this is what happens with no one watching. The moment you step in — Save & Apply, Update now,
or moving the selector in podkop's dashboard — whatever you leave behind is the truth: the plugin
drops what it had remembered and starts again from the node your traffic runs on.

Two honest limits. The reachability check in step 5 opens a TCP connection and no more: it proves
the server is up, not that the tunnel will carry traffic. And nodes on UDP (`hy2`, `hysteria2`)
cannot be checked this way at all, so they are skipped rather than reported dead.

## The page

**Subscriptions** — the subscription list: name, URL, enabled, the node picker with its Refresh
button, which podkop sections it feeds, user agent, and the state of each subscription (number of
links, last update, expiry and traffic left when the provider reports them). Below it, the
configuration type of every targeted section, *Update now*, and *Show log*.

**Settings** — the auto-update service (running state, Start / Stop / Restart) and its knobs: check
interval, ping timeout, and how many nodes may fail in one check before it stops probing. Stopping
the service only turns off the background checks; *Update now* and *Save & Apply* keep working.

The same things work from the shell: `podkop-sub update|apply|check|restore|status|logs`.

## Versions

The plugin is tied to a podkop version. A tag is a plain version — `0.0.3` — and the podkop a
package was built for is stamped into its file name, so `install.sh` picks the release by its
packages rather than by its tag. A mismatch is a warning, never a refusal: the installer asks before
continuing and the page shows a notice.

| podkop | plugin |
|---|---|
| 0.7.22 | `0.0.3` |

Subscription URLs live in `/etc/config/podkop-sub` and never in podkop's own config — `podkop
show_config` is what people paste into bug reports, and it would leak them. The debug log masks the
middle of every address it prints. The plugin adds no dependencies of its own: it uses what podkop
already requires.

Development, test stands and builds: [CONTRIBUTING.md](CONTRIBUTING.md). Licensed under AGPL-3.0.
