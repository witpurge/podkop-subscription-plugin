"use strict";
"require view";
"require form";
"require fs";
"require ui";
"require uci";

const CORE = "/usr/bin/podkop-sub";
const INIT = "/etc/init.d/podkop-sub";
const LOG_STYLE =
  "max-height:60vh;overflow:auto;white-space:pre-wrap;word-break:break-all";
const NO_STATUS = {
  version: "",
  podkop_version: "",
  target_podkop: "",
  subs: [],
  sections: [],
  service: { running: false, enabled: false },
};

// podkop-sub status is the only runtime data source; the page re-reads it after every action
let coreStatus = NO_STATUS;
// one warning banner per subscription, so a re-read replaces its own banner instead of stacking
let missingBanners = {};
// the same, per podkop section, for the states the plugin put a section into
let healthBanners = {};

function readCoreStatus() {
  return fs
    .exec(CORE, ["status"])
    .then((res) => (coreStatus = JSON.parse(res.stdout || "")))
    .catch(() => (coreStatus = NO_STATUS));
}

function lastOutputLine(res) {
  const lines = [res.stderr || "", res.stdout || ""]
    .join("\n")
    .split("\n")
    .filter((line) => line.trim() !== "");
  return lines.length ? lines[lines.length - 1].trim() : "";
}

function execCore(args) {
  return fs.exec(CORE, args).then((res) => {
    if (res.code !== 0) {
      throw new Error(
        lastOutputLine(res) ||
          _("podkop-sub %s failed with code %d").format(args[0], res.code),
      );
    }
    return res;
  });
}

function refresh(map) {
  return readCoreStatus()
    .then(() => warnAboutMissingNodes())
    .then(() => warnAboutSectionHealth())
    .then(() => map.reset());
}

function runCommands(map, commands, successText) {
  let chain = Promise.resolve();
  commands.forEach((args) => {
    chain = chain.then(() => execCore(args));
  });
  return chain
    .then(() => ui.addNotification(null, E("p", successText), "info"))
    .catch((err) => ui.addNotification(null, E("p", err.message), "error"))
    .then(() => refresh(map));
}

function runService(map, action) {
  return fs
    .exec(INIT, [action])
    .then((res) => {
      if (res.code !== 0) {
        throw new Error(
          lastOutputLine(res) ||
            _("The service failed to %s (code %d)").format(action, res.code),
        );
      }
      ui.addNotification(null, E("p", _("Service: %s done.").format(action)), "info");
    })
    .catch((err) => ui.addNotification(null, E("p", err.message), "error"))
    .then(() => refresh(map));
}

// The core keeps the log out of flash and capped; the page only reads and clears it.
function showLogModal() {
  return execCore(["logs"]).then((res) => {
    const empty = _("The log is empty.");
    const body = E("pre", { style: LOG_STYLE }, (res.stdout || "").trim() || empty);
    ui.showModal(_("Debug log"), [
      body,
      // LuCI's Esc clicks the first button in .right, so Close has to be the first one
      E("div", { class: "right" }, [
        E(
          "button",
          { class: "cbi-button cbi-button-neutral", click: ui.hideModal },
          _("Close"),
        ),
        " ",
        E(
          "button",
          {
            class: "cbi-button cbi-button-remove",
            click: ui.createHandlerFn(null, () =>
              execCore(["logs", "--clear"]).then(() => {
                body.textContent = empty;
              }),
            ),
          },
          _("Clear log"),
        ),
      ]),
    ]);
    // newest entries are at the bottom, so start the view there
    body.scrollTop = body.scrollHeight;
  });
}

function formatTime(epoch) {
  return new Date(epoch * 1000).toLocaleString();
}

// a subscription row is matched to its status entry by URL; the id is the core's, never recomputed
function subEntry(sid) {
  const url = uci.get("podkop-sub", sid, "url") || "";
  return url ? coreStatus.subs.filter((entry) => entry.url === url)[0] : null;
}

function cachedNodes(sid) {
  const sub = subEntry(sid);
  return (sub && sub.nodes) || [];
}

function describeSubscription(sub) {
  if (!sub || sub.status === "never") {
    return _("Never updated");
  }

  const facts = [];
  if (sub.status === "ok") {
    facts.push(_("Links: %d").format(sub.count));
  } else {
    facts.push(_("Error: %s").format(sub.error || _("unknown")));
  }
  if (sub.updated > 0) {
    facts.push(_("updated %s").format(formatTime(sub.updated)));
  }
  if (sub.expire > 0) {
    facts.push(_("expires %s").format(formatTime(sub.expire)));
  }
  // total=0 is an unlimited plan and the core clamps its leftover to 0, so 0 means "no figure"
  if (sub.traffic_left > 0) {
    facts.push(_("%s left").format("%1024.2mB".format(sub.traffic_left)));
  }
  return facts.join(" · ");
}

// what apply will write: the nodes that survive the choice, times the sections this feeds
function outboundText(sid, picked, targets) {
  const names = cachedNodes(sid);
  if (!names.length) {
    return "";
  }
  if (!picked.length) {
    return _("All nodes (%d) × sections (%d) = %d outbounds in podkop").format(
      names.length,
      targets.length,
      names.length * targets.length,
    );
  }
  // the core falls back to the first node when nothing the user picked is still on offer
  const kept = picked.filter((name) => names.indexOf(name) >= 0).length || 1;
  return _("Nodes (%d of %d) × sections (%d) = %d outbounds in podkop").format(
    kept,
    names.length,
    targets.length,
    kept * targets.length,
  );
}

// state.json remembers the vanished names, so this warning survives a reload until it is dismissed
function warnAboutMissingNodes() {
  Object.keys(missingBanners).forEach((id) => {
    const node = missingBanners[id];
    if (node && node.parentNode) {
      node.parentNode.removeChild(node);
    }
  });
  missingBanners = {};

  coreStatus.subs.forEach((sub) => {
    const missing = sub.missing || [];
    if (!missing.length) {
      return;
    }
    const banner = ui.addNotification(
      null,
      E(
        "p",
        _("Subscription %s no longer offers these nodes: %s. They are skipped until they come back.").format(
          sub.name || sub.id,
          missing.join(", "),
        ),
      ),
      "warning",
    );
    missingBanners[sub.id] = banner;
    // the stock Dismiss button is the close the owner sees; acknowledging is what makes it stay away
    const dismiss = banner.querySelector("button");
    if (dismiss) {
      dismiss.addEventListener("click", () => execCore(["ack", sub.id]));
    }
  });
}

// podkop's own dashboard shows which node is live; this says only what the plugin moved, and why
function healthText(section) {
  if (section.health === "failover") {
    return _("Section %s: your node %s is not answering, so traffic goes through %s, another node of your selection.").format(
      section.name,
      section.selected,
      section.failover,
    );
  }
  if (section.health === "added") {
    return _("Section %s: none of your nodes answer, so %s was borrowed from the subscription to keep the section alive. It is dropped as soon as one of yours comes back.").format(
      section.name,
      section.added,
    );
  }
  if (section.health === "fail") {
    return _("Section %s: no node answered. The plugin keeps probing it.").format(
      section.name,
    );
  }
  return "";
}

// the core reports health as ok while the current state is acknowledged, so a dismissal survives a
// reload, a recovery clears it, and a section that degrades differently warns again
function warnAboutSectionHealth() {
  Object.keys(healthBanners).forEach((name) => {
    const node = healthBanners[name];
    if (node && node.parentNode) {
      node.parentNode.removeChild(node);
    }
  });
  healthBanners = {};

  (coreStatus.sections || []).forEach((section) => {
    const text = healthText(section);
    if (!text) {
      return;
    }
    const banner = ui.addNotification(null, E("p", text), "warning");
    healthBanners[section.name] = banner;
    const dismiss = banner.querySelector("button");
    if (dismiss) {
      dismiss.addEventListener("click", () =>
        execCore(["ack-section", section.name]),
      );
    }
  });
}

function podkopSectionNames() {
  return uci.sections("podkop", "section").map((section) => section[".name"]);
}

// A section is managed only while an enabled subscription targets it, form state included
function isTargeted(subscriptions, enabledFlag, sectionPicker, podkopSection) {
  return subscriptions.cfgsections().some((sid) => {
    if (enabledFlag.formvalue(sid) !== enabledFlag.enabled) {
      return false;
    }
    const picked = sectionPicker.formvalue(sid);
    return Array.isArray(picked) && picked.indexOf(podkopSection) >= 0;
  });
}

function addModeOption(holder, podkopSection, targeted) {
  const mode = holder.option(form.ListValue, podkopSection, podkopSection);
  mode.ucisection = podkopSection;
  mode.ucioption = "mode";
  mode.value("", _("-- select --"));
  mode.value("selector", _("Selector"));
  mode.value("urltest", _("URLTest"));
  mode.rmempty = false;
  mode.validate = (sid, value) =>
    value ? true : _("Choose a configuration type");
  mode.checkDepends = () => targeted(podkopSection);
  // uci.set is a no-op on a section that does not exist yet, so create it on first write
  mode.write = (sid, value) => {
    if (!uci.get("podkop-sub", podkopSection)) {
      uci.add("podkop-sub", "managed_section", podkopSection);
    }
    uci.set("podkop-sub", podkopSection, "mode", value);
  };
  // the section only ever holds the mode, so drop it whole once nothing targets it
  mode.remove = () => uci.remove("podkop-sub", podkopSection);
  return mode;
}

function subscriptionsTab(map) {
  const tab = map.section(
    form.NamedSection,
    "settings",
    "subscriptions",
    _("Subscriptions"),
  );
  tab.addremove = false;
  // the tab strip already names it
  tab.hidetitle = true;

  const list = tab.option(
    form.SectionValue,
    "_list",
    form.TypedSection,
    "subscription",
    null,
    _("Every enabled subscription feeds the podkop sections it targets."),
  );
  const subscriptions = list.subsection;
  subscriptions.anonymous = true;
  subscriptions.addremove = true;
  subscriptions.addbtntitle = _("Add subscription");

  const name = subscriptions.option(
    form.Value,
    "name",
    _("Name"),
    _("Your own label for this subscription."),
  );
  name.placeholder = _("Main");

  const url = subscriptions.option(form.TextValue, "url", _("Subscription URL"));
  url.rows = 3;
  // soft wrap so a long URL is readable whole, the way podkop's own proxy_string field does it
  url.wrap = "soft";
  url.rmempty = false;
  // a textarea is for reading the URL, not for pasting several: still exactly one, trimmed
  url.validate = (sid, value) =>
    /^\s*https?:\/\/\S+\s*$/.test(value || "")
      ? true
      : _("Expecting exactly one http(s) URL");
  url.write = (sid, value) =>
    uci.set("podkop-sub", sid, "url", String(value).trim());

  const enabled = subscriptions.option(form.Flag, "enabled", _("Enabled"));
  enabled.default = enabled.enabled;

  const reload = subscriptions.option(form.Button, "_refresh", _("Node list"));
  reload.inputtitle = _("Refresh");
  reload.inputstyle = "reload";
  reload.description = _("Fetch this subscription's nodes. Nothing is written to podkop.");
  reload.onclick = (ev, sid) => {
    const sub = subEntry(sid);
    if (!sub) {
      ui.addNotification(null, E("p", _("Save the subscription first.")), "warning");
      return Promise.resolve();
    }
    return runCommands(map, [["update", sub.id]], _("Node list refreshed."));
  };

  const nodes = subscriptions.option(
    form.MultiValue,
    "nodes",
    _("Nodes"),
    _("Nodes this subscription hands to podkop. Select none to use all of them."),
  );
  nodes.display_size = 5;
  nodes.dropdown_size = 10;
  // the choices differ per subscription, which a shared keylist cannot express
  nodes.renderWidget = function (sid, optionIndex, cfgvalue) {
    const names = cachedNodes(sid);
    if (!names.length) {
      return E("em", {}, _("No nodes cached yet — press Refresh."));
    }
    const choices = {};
    names.forEach((name) => (choices[name] = name));
    return new ui.Dropdown(L.toArray(cfgvalue), choices, {
      id: this.cbid(sid),
      sort: names,
      multiple: true,
      optional: true,
      select_placeholder: _("All nodes"),
      display_items: this.display_size,
      dropdown_items: this.dropdown_size,
    }).render();
  };
  // a name the provider dropped is not in the widget, so carry it over instead of losing it
  nodes.write = (sid, value) => {
    const names = cachedNodes(sid);
    const gone = L.toArray(uci.get("podkop-sub", sid, "nodes")).filter(
      (name) => names.indexOf(name) < 0,
    );
    uci.set("podkop-sub", sid, "nodes", L.toArray(value).concat(gone));
  };
  // without a widget there is nothing to read the choice back from, so leave it in uci untouched
  nodes.remove = (sid) => {
    if (cachedNodes(sid).length) {
      uci.unset("podkop-sub", sid, "nodes");
    }
  };

  const outbounds = subscriptions.option(form.DummyValue, "_outbounds", " ");
  const countId = (sid) => "podkop-sub-outbounds-" + sid;
  outbounds.renderWidget = (sid) =>
    E(
      "div",
      { id: countId(sid) },
      outboundText(
        sid,
        L.toArray(uci.get("podkop-sub", sid, "nodes")),
        L.toArray(uci.get("podkop-sub", sid, "sections")),
      ),
    );
  const recount = (ev, sid) => {
    const node = document.getElementById(countId(sid));
    if (node) {
      node.textContent = outboundText(
        sid,
        L.toArray(nodes.formvalue(sid)),
        L.toArray(sections.formvalue(sid)),
      );
    }
  };
  nodes.onchange = recount;

  const sections = subscriptions.option(
    form.MultiValue,
    "sections",
    _("podkop sections"),
    _("Sections whose proxy list this subscription fills."),
  );
  podkopSectionNames().forEach((section) => sections.value(section, section));
  sections.onchange = recount;

  const userAgent = subscriptions.option(
    form.Value,
    "user_agent",
    _("User agent"),
  );
  userAgent.placeholder = "v2rayNG/1.9.0";

  const state = subscriptions.option(form.DummyValue, "_state", _("State"));
  state.cfgvalue = (sid) => describeSubscription(subEntry(sid));

  const modes = tab.option(
    form.SectionValue,
    "_modes",
    form.NamedSection,
    "settings",
    "modes",
    _("Configuration type per section"),
    _("A podkop section has one type, so it is chosen here and not per subscription."),
  );
  const targeted = (podkopSection) =>
    isTargeted(subscriptions, enabled, sections, podkopSection);
  podkopSectionNames().forEach((section) =>
    addModeOption(modes.subsection, section, targeted),
  );

  const update = tab.option(form.Button, "_update", _("Update now"));
  update.inputtitle = _("Update now");
  update.inputstyle = "apply";
  update.description = _("Download every subscription, then write the result into podkop.");
  update.onclick = () =>
    runCommands(
      map,
      [["update", "--all"], ["apply"]],
      _("Subscriptions updated and applied."),
    );

  const logs = tab.option(form.Button, "_logs", _("Debug log"));
  logs.inputtitle = _("Show log");
  logs.inputstyle = "reload";
  logs.description = _("What the plugin did, newest last. Nothing secret is written here.");
  logs.onclick = () =>
    showLogModal().catch((err) =>
      ui.addNotification(null, E("p", err.message), "error"),
    );
}

function serviceState() {
  const service = coreStatus.service || {};
  return [
    service.running ? _("Running") : _("Stopped"),
    service.enabled ? _("starts on boot") : _("does not start on boot"),
  ].join(" · ");
}

function serviceButton(map, action, label, style) {
  return E(
    "button",
    {
      class: "cbi-button cbi-button-" + style,
      click: ui.createHandlerFn(null, () => runService(map, action)),
    },
    label,
  );
}

function settingsTab(map) {
  const tab = map.section(
    form.NamedSection,
    "settings",
    "settings",
    _("Settings"),
  );
  tab.addremove = false;
  tab.hidetitle = true;

  const service = tab.option(
    form.DummyValue,
    "_service",
    _("Auto-update service"),
    _("Stopping it only turns off background checks: Update now and Save & Apply keep working."),
  );
  service.cfgvalue = () =>
    E("span", {}, [
      E("span", {}, serviceState()),
      " ",
      serviceButton(map, "start", _("Start"), "apply"),
      " ",
      serviceButton(map, "stop", _("Stop"), "remove"),
      " ",
      serviceButton(map, "restart", _("Restart"), "reload"),
    ]);

  const checkInterval = tab.option(
    form.Value,
    "check_interval",
    _("Check interval"),
    _("Minutes between automatic checks."),
  );
  checkInterval.datatype = "range(1,10080)";
  checkInterval.default = "60";

  const pingTimeout = tab.option(
    form.Value,
    "ping_timeout",
    _("Ping timeout"),
    _("Milliseconds to wait for a node to answer."),
  );
  pingTimeout.datatype = "uinteger";
  pingTimeout.default = "2000";

  const maxFailures = tab.option(
    form.Value,
    "max_failures",
    _("Max failures"),
    _("How many nodes may fail in one check before it stops probing."),
  );
  maxFailures.datatype = "uinteger";
  maxFailures.default = "5";
}

function warnAboutPodkopVersion() {
  const built = coreStatus.target_podkop;
  const installed = coreStatus.podkop_version;
  if (!built || !installed || built === installed) {
    return;
  }
  ui.addNotification(
    null,
    E(
      "p",
      _("This plugin was built for podkop %s, but podkop %s is installed. Everything still works, but instabilities are possible.").format(
        built,
        installed,
      ),
    ),
    "warning",
  );
}

return view.extend({
  load() {
    return Promise.all([uci.load("podkop"), readCoreStatus()]);
  },

  render() {
    warnAboutPodkopVersion();
    warnAboutMissingNodes();
    warnAboutSectionHealth();

    const map = new form.Map(
      "podkop-sub",
      _("Podkop Subscriptions"),
      _("Keep podkop's section configs in sync with VPN subscriptions."),
    );
    map.tabbed = true;
    this.map = map;

    subscriptionsTab(map);
    settingsTab(map);

    return map.render();
  },

  // The stock flow stops after committing uci; podkop's sections are written by the core
  handleSaveApply(ev) {
    return this.handleSave(ev)
      .then(() => uci.changes())
      // uci.apply() rejects with "No data received" when nothing is staged, and that must not
      // stop the core from running: applying an unchanged config to podkop is the usual case
      .then((changes) =>
        Object.keys(changes || {}).length ? uci.apply() : null,
      )
      .then(() => ui.changes.init())
      .then(() =>
        runCommands(this.map, [["apply"]], _("Saved and applied to podkop.")),
      );
  },
});
