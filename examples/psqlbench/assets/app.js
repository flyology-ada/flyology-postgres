(() => {
  "use strict";

  const daemon = document.querySelector("#daemon-status");
  const list = document.querySelector("#instance-list");
  const form = document.querySelector("#create-form");
  const openCreate = document.querySelector("#open-create");
  const closeCreate = document.querySelector("#close-create");
  const events = document.querySelector("#event-list");
  const streamState = document.querySelector("#stream-state");
  const activityFilter = document.querySelector("#activity-filter");
  const activityTitle = document.querySelector("#activity-title");
  const toast = document.querySelector("#toast");
  const workspace = document.querySelector("#instance-workspace");
  const workspaceInstance = document.querySelector("#workspace-instance");
  const queryTab = document.querySelector("#query-tab");
  const logsTab = document.querySelector("#logs-tab");
  const queryPanel = document.querySelector("#query-panel");
  const logsPanel = document.querySelector("#logs-panel");
  const queryInput = document.querySelector("#query-input");
  const runQuery = document.querySelector("#run-query");
  const cancelQuery = document.querySelector("#cancel-query");
  const queryState = document.querySelector("#query-state");
  const queryMessages = document.querySelector("#query-messages");
  const queryResult = document.querySelector("#query-result");
  const commandTag = document.querySelector("#command-tag");
  const logStreamState = document.querySelector("#log-stream-state");
  const logOutput = document.querySelector("#log-output");
  const followLogs = document.querySelector("#follow-logs");
  const clearLogs = document.querySelector("#clear-logs");
  const linkList = document.querySelector("#link-list");
  const linkForm = document.querySelector("#link-form");
  const openLink = document.querySelector("#open-link");
  const closeLink = document.querySelector("#close-link");
  const linkSource = document.querySelector("#link-source");
  const linkTarget = document.querySelector("#link-target");
  const linkMode = document.querySelector("#link-mode");
  const logicalTargetField = document.querySelector("#logical-target-field");
  const physicalTargetField = document.querySelector("#physical-target-field");
  const physicalPortField = document.querySelector("#physical-port-field");
  const logicalRelationFields = document.querySelectorAll(".logical-relation-field");
  const linkStandby = document.querySelector("#link-standby");
  const linkTargetPort = document.querySelector("#link-target-port");
  const linkFormTitle = document.querySelector("#link-form-title");
  const linkPathLabel = document.querySelector("#link-path-label");
  const logicalContract = document.querySelector("#logical-contract");
  const physicalContract = document.querySelector("#physical-contract");
  const linkFormNote = document.querySelector("#link-form-note");
  const topologyPreset = document.querySelector("#topology-preset");
  const launchPreset = document.querySelector("#launch-preset");
  const topologyState = document.querySelector("#topology-state");
  const topologySummary = document.querySelector("#topology-summary");
  const openReset = document.querySelector("#open-reset");
  const resetPanel = document.querySelector("#reset-panel");
  const resetSummary = document.querySelector("#reset-summary");
  const cancelReset = document.querySelector("#cancel-reset");
  const confirmReset = document.querySelector("#confirm-reset");

  let toastTimer;
  let instances = [];
  let links = [];
  let desiredTopology = { instances: [], links: [], state_file: "" };
  const linkActivity = new Map();
  const quietLinkActivityKinds = new Set([
    "PRIMARY_KEEPALIVE",
    "STANDBY_STATUS_UPDATE",
    "HOT_STANDBY_FEEDBACK",
    "UPSTREAM_ACK"
  ]);
  let selectedName = "";
  let activeTab = "query";
  let querySocket;
  let queryGeneration = 0;
  let queryRunning = false;
  let resultBody;
  let logSocket;
  let logGeneration = 0;
  let logLines = 0;

  const topologyPresets = {
    "logical-stream": {
      instances: [
        { name: "preset-source-17", version: "17.10", port: 55510 },
        { name: "preset-target-18", version: "18.4", port: 55511 }
      ],
      links: [
        { name: "preset-stream", source: "preset-source-17", target: "preset-target-18", mode: "logical-streaming" }
      ]
    },
    "physical-standby": {
      instances: [
        { name: "preset-primary-18", version: "18.4", port: 55512 }
      ],
      links: [
        { name: "preset-wal", source: "preset-primary-18", target: "preset-standby-18", target_port: 55513, mode: "physical-streaming" }
      ]
    },
    "mixed-lab": {
      instances: [
        { name: "lab-primary-14", version: "14.23", port: 55514 },
        { name: "lab-logical-18", version: "18.4", port: 55515 }
      ],
      links: [
        { name: "lab-committed", source: "lab-primary-14", target: "lab-logical-18", mode: "logical-committed" },
        { name: "lab-physical", source: "lab-primary-14", target: "lab-standby-14", target_port: 55516, mode: "physical-streaming" }
      ]
    },
    "transaction-lab": {
      instances: [
        { name: "tx-primary-18", version: "18.4", port: 55517 },
        { name: "tx-replica-18", version: "18.4", port: 55518 }
      ],
      links: [
        { name: "tx-committed", source: "tx-primary-18", target: "tx-replica-18", mode: "logical-two-phase" },
        { name: "tx-streamed", source: "tx-primary-18", target: "tx-replica-18", mode: "logical-two-phase-streaming" }
      ]
    }
  };

  function showError(message) {
    clearTimeout(toastTimer);
    toast.textContent = message;
    toast.hidden = false;
    toastTimer = setTimeout(() => { toast.hidden = true; }, 6500);
  }

  async function request(path, options = {}) {
    const response = await fetch(path, options);
    const body = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error(body.detail || body.title || `Request failed (${response.status})`);
    }
    return body;
  }

  function labelsOf(value) {
    return Object.fromEntries(String(value || "").split(",")
      .map(item => item.trim().split(/=(.*)/s).slice(0, 2))
      .filter(pair => pair.length === 2 && pair[0]));
  }

  function detailsOf(instance) {
    const labels = labelsOf(instance.Labels);
    const name = labels["org.flyology.psqlbench.instance"] || String(instance.Names || "").replace(/^psqlbench-/, "");
    const desired = desiredTopology.instances.find(value => value.name === name);
    const linkManaged = labels["org.flyology.psqlbench.role"] === "physical-standby";
    return {
      name,
      version: labels["org.flyology.psqlbench.version"] || String(instance.Image || "postgres:?").split(":")[1],
      port: labels["org.flyology.psqlbench.port"] || "-",
      running: String(instance.State || "").toLowerCase() === "running",
      desiredRunning: desired ? Boolean(desired.running) : null,
      linkManaged
    };
  }

  function el(tag, className, text) {
    const value = document.createElement(tag);
    if (className) value.className = className;
    if (text !== undefined) value.textContent = text;
    return value;
  }

  function formatBytes(value) {
    const bytes = Math.max(0, Number(value) || 0);
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
  }

  function wsURL(path) {
    const scheme = location.protocol === "https:" ? "wss:" : "ws:";
    return `${scheme}//${location.host}${path}`;
  }

  function instanceNode(instance) {
    const details = detailsOf(instance);
    const article = el("article", `node ${details.running ? "running" : "stopped"}`);
    const head = el("div", "node-head");
    const title = document.createElement("div");
    title.append(el("span", "node-version", `POSTGRES ${details.version}`));
    title.append(el("h3", "node-name", details.name));
    head.append(title, el("span", "node-status", details.running ? "running" : (instance.State || "stopped")));

    const meta = el("dl", "node-meta");
    [["host", `127.0.0.1:${details.port}`], ["container", instance.Names || `psqlbench-${details.name}`], ["health", instance.Status || "unknown"], ["desired", details.linkManaged ? "link-managed" : (details.desiredRunning === null ? "discovered" : (details.desiredRunning ? "running" : "stopped"))]]
      .forEach(([key, value]) => {
        const row = document.createElement("div");
        row.append(el("dt", "", key), el("dd", "", value));
        meta.append(row);
      });

    const actions = el("div", "node-actions");
    const inspect = el("button", "button primary", "Inspect");
    inspect.type = "button";
    inspect.addEventListener("click", () => selectInstance(details.name));
    const stateAction = el("button", "button secondary", details.running ? "Stop" : "Start");
    stateAction.type = "button";
    stateAction.addEventListener("click", () => applyAction(details.name, details.running ? "stop" : "start", stateAction));
    const remove = el("button", "button danger", "Remove");
    remove.type = "button";
    remove.addEventListener("click", () => applyAction(details.name, "remove", remove));
    actions.append(inspect, stateAction, remove);
    article.append(head, meta, actions);
    return article;
  }

  function syncInstanceSelector() {
    const known = instances.map(detailsOf);
    workspaceInstance.replaceChildren(...known.map(details => {
      const option = document.createElement("option");
      option.value = details.name;
      option.textContent = `${details.name} · PostgreSQL ${details.version}`;
      return option;
    }));
    if (selectedName && known.some(value => value.name === selectedName)) {
      workspaceInstance.value = selectedName;
    } else if (selectedName) {
      closeQuerySocket();
      closeLogSocket();
      selectedName = "";
      workspace.hidden = true;
    }

    const running = known.filter(value => value.running);
    [linkSource, linkTarget].forEach((select, selectIndex) => {
      const previous = select.value;
      select.replaceChildren(...running.map(details => {
        const option = document.createElement("option");
        option.value = details.name;
        option.textContent = `${details.name} · PostgreSQL ${details.version}`;
        return option;
      }));
      if (running.some(value => value.name === previous)) select.value = previous;
      else if (running.length > selectIndex) select.value = running[selectIndex].name;
    });
    openLink.disabled = running.length < 1;
  }

  function syncLinkMode() {
    const physical = linkMode.value === "physical-streaming";
    logicalTargetField.hidden = physical;
    physicalTargetField.hidden = !physical;
    physicalPortField.hidden = !physical;
    logicalRelationFields.forEach(field => { field.hidden = physical; });
    logicalContract.hidden = physical;
    physicalContract.hidden = !physical;
    linkTarget.required = !physical;
    linkStandby.required = physical;
    linkTargetPort.required = physical;
    linkFormTitle.textContent = physical ? "Managed physical standby" : "Managed logical bridge";
    linkPathLabel.textContent = physical ? "Flyology client → server → Postgres walreceiver" : "Flyology client → server → client";
    linkFormNote.textContent = physical
      ? "The base backup is a bootstrap step. Every live recovery WAL byte passes through the Flyology relay."
      : "Source slot acknowledgements advance only after the target transaction commits.";
  }

  function linkStructure(link) {
    return JSON.stringify([
      link.name, link.source, link.target, link.target_version,
      link.target_port, link.table, link.source_relation,
      link.target_relation, link.status, link.mode,
      link.relay_port, link.detail, link.desired_running, link.column_map,
      link.flow_paused, link.latency_ms, link.bandwidth_kib, link.disconnects
    ]);
  }

  function faultProfileLabel(link) {
    const parts = [];
    if (link.flow_paused) parts.push("paused");
    if (Number(link.latency_ms)) parts.push(`${link.latency_ms} ms`);
    if (Number(link.bandwidth_kib)) parts.push(`${link.bandwidth_kib} KiB/s`);
    return parts.length ? parts.join(" · ") : "nominal";
  }

  function replayStateLabel(link) {
    const lag = formatBytes(link.lag_bytes);
    const shaped = link.flow_paused || Number(link.latency_ms) || Number(link.bandwidth_kib);
    if (link.flow_paused) return `Paused · ${lag} queued`;
    if (!link.caught_up) return `${shaped ? "Shaping" : "Catching up"} · ${lag} behind`;
    return shaped ? "Shaped · caught up" : "Caught up";
  }

  function updateLinkMetrics(article, link) {
    const physical = link.mode === "physical-streaming";
    const values = {
      endpoint: physical ? `127.0.0.1:${link.target_port}` : link.target_relation,
      changes: String(link.changes || 0),
      "last-lsn": link.last_lsn || "waiting",
      relay: physical ? `0.0.0.0:${link.relay_port}` : `127.0.0.1:${link.relay_port}`
    };
    Object.entries(values).forEach(([name, value]) => {
      const output = article.querySelector(`[data-stat="${name}"]`);
      if (output && output.textContent !== value) output.textContent = value;
    });

    const replay = article.querySelector(".replay-progress");
    replay.classList.toggle("caught-up", Boolean(link.caught_up));
    replay.classList.toggle("paused", Boolean(link.flow_paused));
    replay.classList.toggle("shaped", Boolean(Number(link.latency_ms) || Number(link.bandwidth_kib)));
    replay.querySelector(".replay-state").textContent = replayStateLabel(link);
    replay.querySelector(".replay-lsns").textContent =
      `${link.applied_lsn || "waiting"} → ${link.last_lsn || "waiting"}`;
    const meter = replay.querySelector("meter");
    const spanBytes = Math.max(1, Number(link.span_bytes) || 0);
    meter.max = spanBytes;
    meter.value = link.caught_up
      ? spanBytes
      : Math.min(spanBytes, Number(link.replayed_bytes) || 0);
    replay.querySelector(".replay-summary").textContent =
      `${formatBytes(link.replayed_bytes)} replayed across ${formatBytes(link.span_bytes)} observed`;
  }

  function linkNode(link) {
    const article = el("article", `link-card ${link.status}`);
    article.dataset.link = link.name;
    article.dataset.snapshot = linkStructure(link);
    const heading = el("div", "link-card-heading");
    const title = document.createElement("div");
    const streamed = ["logical-streaming", "logical-two-phase-streaming"].includes(link.mode);
    const twoPhase = ["logical-two-phase", "logical-two-phase-streaming"].includes(link.mode);
    const physical = link.mode === "physical-streaming";
    const modeLabel = physical
      ? `PHYSICAL · WAL STREAMING · POSTGRES ${link.target_version}`
      : (twoPhase
        ? `LOGICAL · ${streamed ? "STREAMED + " : ""}2PC · PGOUTPUT V${streamed ? 4 : 3}`
        : (streamed ? "LOGICAL · STREAMING · PGOUTPUT V2" : "LOGICAL · COMMITTED · PGOUTPUT V1"));
    title.append(el("span", "node-version", modeLabel), el("h3", "node-name", link.name));
    heading.append(title, el("span", "node-status", link.status));

    const route = el("div", "link-route");
    route.append(
      el("strong", "", link.source),
      el("span", "", physical ? "client → server → walreceiver" : "client → server → client"),
      el("strong", "", link.target)
    );

    const stats = el("dl", "link-stats");
    [["endpoint", physical ? "standby port" : "target", physical ? `127.0.0.1:${link.target_port}` : link.target_relation], ["changes", physical ? "wal frames" : "changes", String(link.changes || 0)], ["last-lsn", "last lsn", link.last_lsn || "waiting"], ["relay", "relay", physical ? `0.0.0.0:${link.relay_port}` : `127.0.0.1:${link.relay_port}`], ["desired", "desired", link.desired_running ? "running" : "stopped"]]
      .forEach(([name, key, value]) => {
        const row = document.createElement("div");
        const output = el("dd", "", value);
        output.dataset.stat = name;
        row.append(el("dt", "", key), output);
        stats.append(row);
      });

    const replay = el(
      "div",
      `replay-progress${link.caught_up ? " caught-up" : ""}${link.flow_paused ? " paused" : ""}${Number(link.latency_ms) || Number(link.bandwidth_kib) ? " shaped" : ""}`
    );
    const replayHead = el("div", "replay-progress-head");
    replayHead.append(
      el("strong", "replay-state", replayStateLabel(link)),
      el("span", "replay-lsns", `${link.applied_lsn || "waiting"} → ${link.last_lsn || "waiting"}`)
    );
    const meter = document.createElement("meter");
    const spanBytes = Math.max(1, Number(link.span_bytes) || 0);
    meter.min = 0;
    meter.max = spanBytes;
    meter.value = link.caught_up ? spanBytes : Math.min(spanBytes, Number(link.replayed_bytes) || 0);
    meter.setAttribute("aria-label", `${link.name} replica replay progress`);
    replay.append(replayHead, meter, el("small", "replay-summary", `${formatBytes(link.replayed_bytes)} replayed across ${formatBytes(link.span_bytes)} observed`));

    const failureLab = document.createElement("details");
    failureLab.className = "failure-lab";
    const failureSummary = document.createElement("summary");
    failureSummary.append(
      el("span", "failure-lab-title", "Failure lab"),
      el("span", "failure-lab-profile", faultProfileLabel(link))
    );
    const failureBody = el("div", "failure-lab-body");
    const faultControls = el("div", "fault-controls");
    const pauseLabel = el("label", "fault-toggle");
    const pause = document.createElement("input");
    pause.type = "checkbox";
    pause.checked = Boolean(link.flow_paused);
    pauseLabel.append(pause, el("span", "", "Hold relay delivery"));

    function profileSelect(labelText, values, selected) {
      const label = document.createElement("label");
      label.append(el("span", "", labelText));
      const select = document.createElement("select");
      values.forEach(([value, text]) => {
        const option = document.createElement("option");
        option.value = String(value);
        option.textContent = text;
        select.append(option);
      });
      select.value = String(selected || 0);
      label.append(select);
      return { label, select };
    }

    const latency = profileSelect("Added latency", [
      [0, "None"], [50, "50 ms"], [250, "250 ms"],
      [1000, "1 second"], [3000, "3 seconds"]
    ], link.latency_ms);
    const bandwidth = profileSelect("Relay ceiling", [
      [0, "Unlimited"], [1024, "1 MiB/s"], [256, "256 KiB/s"],
      [64, "64 KiB/s"], [16, "16 KiB/s"]
    ], link.bandwidth_kib);
    faultControls.append(pauseLabel, latency.label, bandwidth.label);

    const faultNote = el(
      "p", "failure-lab-note",
      `Runtime-only controls. ${Number(link.disconnects) || 0} supervised reconnect${Number(link.disconnects) === 1 ? "" : "s"} injected.`
    );
    const faultActions = el("div", "failure-lab-actions");
    const applyFaults = el("button", "button secondary", "Apply shaping");
    applyFaults.type = "button";
    applyFaults.disabled = link.status !== "running";
    applyFaults.addEventListener("click", () => applyLinkFaults(link.name, {
      paused: pause.checked,
      latency_ms: Number(latency.select.value),
      bandwidth_kib: Number(bandwidth.select.value)
    }, applyFaults));
    const disconnect = el("button", "button danger", "Disconnect now");
    disconnect.type = "button";
    disconnect.disabled = link.status !== "running" || !link.desired_running;
    disconnect.addEventListener("click", () => applyLinkAction(link.name, "disconnect", disconnect));
    faultActions.append(applyFaults, disconnect);
    failureBody.append(faultControls, faultNote, faultActions);
    failureLab.append(failureSummary, failureBody);

    const detail = el("p", "link-detail", link.detail || "Waiting for supervised link activity");
    const mapping = document.createElement("details");
    mapping.className = "link-mapping";
    const mappingRules = String(link.column_map || "").split("\n")
      .map(value => value.trim())
      .filter(value => value && !value.startsWith("#"));
    const mappingSummary = document.createElement("summary");
    mappingSummary.textContent = mappingRules.length
      ? `Column projection · ${mappingRules.length} ${mappingRules.length === 1 ? "rule" : "rules"}`
      : "Column projection · identity";
    mapping.append(mappingSummary);
    if (mappingRules.length) mapping.append(el("pre", "", mappingRules.join("\n")));
    const live = el("section", "link-live");
    live.setAttribute("aria-label", `${link.name} live replication activity`);
    const liveHeading = el("div", "link-live-heading");
    liveHeading.append(
      el("strong", "", "Live replication"),
      el("span", "", physical ? "WAL + feedback" : "pgoutput + apply")
    );
    const liveEvents = el("ol", "link-event-stream");
    (linkActivity.get(link.name) || []).forEach(value => liveEvents.append(linkEventNode(value)));
    if (!liveEvents.children.length) {
      liveEvents.append(el("li", "link-event-empty", "Waiting for replication traffic"));
    }
    live.append(liveHeading, liveEvents);
    const actions = el("div", "node-actions");
    const insert = el("button", "button primary", "Insert demo row");
    insert.type = "button";
    const managedRelation = link.source_relation === `public.${link.table}`;
    insert.hidden = !physical && !managedRelation;
    insert.disabled = link.status !== "running";
    insert.addEventListener("click", () => {
      selectInstance(link.source);
      queryInput.value = physical
        ? `create table if not exists public.psqlbench_physical_probe (id bigserial primary key, payload text, changed_at timestamptz default clock_timestamp());\ninsert into public.psqlbench_physical_probe (payload) values ('WAL through ${link.name}') returning *;`
        : `insert into ${link.source_relation} (id, payload)\nvalues ((extract(epoch from clock_timestamp()) * 1000000)::bigint,\n        'sent through ${link.name}')\nreturning *;`;
      switchTab("query");
      queryInput.focus();
    });
    const inspect = el("button", "button secondary", "Inspect target");
    inspect.type = "button";
    inspect.addEventListener("click", () => {
      selectInstance(link.target);
      queryInput.value = physical
        ? "select pg_is_in_recovery() as in_recovery, pg_last_wal_replay_lsn() as replay_lsn;\nselect * from public.psqlbench_physical_probe order by id desc limit 20;"
        : (managedRelation
          ? `select * from ${link.target_relation} order by id desc limit 20;`
          : `select * from ${link.target_relation} limit 20;`);
      switchTab("query");
    });
    const pattern = el("button", "button secondary", twoPhase ? "Load prepared transaction" : (streamed ? "Load streamed transaction" : "Load message patterns"));
    pattern.type = "button";
    pattern.disabled = physical || link.status !== "running";
    if (physical) pattern.hidden = true;
    pattern.addEventListener("click", () => {
      selectInstance(link.source);
      queryInput.value = twoPhase
        ? `begin;\ninsert into ${link.source_relation} (id, payload)\nvalues ((extract(epoch from clock_timestamp()) * 1000000)::bigint, '${streamed ? "streamed + " : ""}prepared through ${link.name}');\nprepare transaction '${link.name}-demo';\n-- Run COMMIT PREPARED '${link.name}-demo'; or ROLLBACK PREPARED '${link.name}-demo'; next.`
        : (streamed
          ? `insert into ${link.source_relation} (id, payload)\nselect 1000000 + n, repeat('streamed-', 128) || n\nfrom generate_series(1, 300) as n;`
          : `select pg_logical_emit_message(false, 'psqlbench', 'non-transactional message');\nbegin;\nselect pg_logical_emit_message(true, 'psqlbench', 'transactional message');\ninsert into ${link.source_relation} (id, payload)\nvalues ((extract(epoch from clock_timestamp()) * 1000000)::bigint, 'same transaction');\ncommit;`);
      switchTab("query");
      queryInput.focus();
    });
    const stateAction = el("button", "button secondary", link.desired_running ? "Stop" : "Resume");
    stateAction.type = "button";
    stateAction.disabled = link.desired_running
      ? !["running", "starting", "pending", "restoring"].includes(link.status)
      : !["stopped", "failed"].includes(link.status);
    stateAction.addEventListener("click", () => applyLinkAction(link.name, link.desired_running ? "stop" : "start", stateAction));
    const activity = el("button", "button secondary", "View activity");
    activity.type = "button";
    activity.addEventListener("click", () => {
      activityFilter.value = link.name;
      applyActivityFilter();
      events.scrollIntoView({ behavior: "smooth", block: "start" });
    });
    actions.append(insert, pattern, inspect, activity, stateAction);
    article.append(heading, route, stats);
    if (!physical) article.append(mapping);
    article.append(replay, failureLab, detail, live, actions);
    return article;
  }

  function linkEventNode(value) {
    const item = el("li", "link-event");
    item.append(
      el("span", "link-event-kind", value.kind || "event"),
      el("span", "link-event-path", [value.stage, value.direction].filter(Boolean).join(" · ")),
      el("span", "link-event-lsn", value.lsn || value.detail || "observed")
    );
    const tupleEvent = ["INSERT_MESSAGE", "UPDATE_MESSAGE", "DELETE_MESSAGE"].includes(value.kind);
    if (tupleEvent && value.detail) {
      item.classList.add("inspectable");
      item.tabIndex = 0;
      item.setAttribute("aria-label", `${value.kind}: ${value.detail}`);
      const popup = el("aside", "link-event-popover");
      popup.setAttribute("role", "tooltip");
      popup.append(
        el("strong", "", value.kind.replace("_MESSAGE", "")),
        el("span", "", [value.stage, value.direction, value.lsn].filter(Boolean).join(" · ")),
        el("code", "", value.detail)
      );
      item.append(popup);
    }
    return item;
  }

  function updateLinkEventNode(item, value) {
    item.querySelector(".link-event-kind").textContent = value.kind || "event";
    item.querySelector(".link-event-path").textContent =
      [value.stage, value.direction].filter(Boolean).join(" · ");
    item.querySelector(".link-event-lsn").textContent =
      value.lsn || value.detail || "observed";
    const popup = item.querySelector(".link-event-popover");
    if (popup) {
      popup.querySelector("span").textContent =
        [value.stage, value.direction, value.lsn].filter(Boolean).join(" · ");
      popup.querySelector("code").textContent = value.detail;
      item.setAttribute("aria-label", `${value.kind}: ${value.detail}`);
    }
  }

  function rememberLinkActivity(value) {
    if (value.type !== "link.activity" || !value.link) return;
    const retained = linkActivity.get(value.link) || [];
    const quietIndex = quietLinkActivityKinds.has(value.kind)
      ? retained.findIndex(previous =>
        previous.kind === value.kind &&
        previous.direction === value.direction)
      : -1;
    if (quietIndex >= 0) {
      const previous = retained[quietIndex];
      if (previous.lsn === value.lsn && previous.detail === value.detail) return;
      retained[quietIndex] = value;
      linkActivity.set(value.link, retained);
      const card = Array.from(document.querySelectorAll(".link-card"))
        .find(item => item.dataset.link === value.link);
      const row = card?.querySelector(".link-event-stream")?.children[quietIndex];
      if (row) updateLinkEventNode(row, value);
      return;
    }
    retained.unshift(value);
    if (retained.length > 10) retained.length = 10;
    linkActivity.set(value.link, retained);

    const card = Array.from(document.querySelectorAll(".link-card"))
      .find(item => item.dataset.link === value.link);
    const stream = card?.querySelector(".link-event-stream");
    if (stream) {
      stream.querySelector(".link-event-empty")?.remove();
      stream.prepend(linkEventNode(value));
      while (stream.children.length > 10) stream.lastElementChild.remove();
    }
  }

  function renderLinks(values) {
    links = values;
    const names = new Set(values.map(value => value.name));
    for (const name of linkActivity.keys()) {
      if (!names.has(name)) linkActivity.delete(name);
    }
    const filterSignature = values.map(value => `${value.name}:${value.mode}`).join("|");
    if (activityFilter.dataset.signature !== filterSignature) {
      const selectedActivity = activityFilter.value;
      activityFilter.replaceChildren(
        new Option("All activity", ""),
        ...values.map(value => new Option(`${value.name} · ${value.mode.startsWith("physical") ? "physical" : "logical"}`, value.name))
      );
      activityFilter.dataset.signature = filterSignature;
      if (values.some(value => value.name === selectedActivity)) {
        activityFilter.value = selectedActivity;
      }
    }
    applyActivityFilter();
    if (!values.length) {
      linkList.replaceChildren();
      const empty = el("div", "link-empty");
      empty.append(el("p", "", "No replication links yet. Connect two nodes logically, or create a physical standby from one running source."));
      linkList.append(empty);
      return;
    }
    linkList.querySelector(".link-empty")?.remove();
    const existing = new Map(Array.from(linkList.querySelectorAll(".link-card"))
      .map(card => [card.dataset.link, card]));
    values.forEach(value => {
      let card = existing.get(value.name);
      const snapshot = linkStructure(value);
      if (!card || card.dataset.snapshot !== snapshot) {
        const replacement = linkNode(value);
        if (card) card.replaceWith(replacement);
        card = replacement;
      } else {
        updateLinkMetrics(card, value);
      }
      linkList.append(card);
      existing.delete(value.name);
    });
    existing.forEach(card => card.remove());
  }

  async function refreshLinks() {
    try {
      renderLinks(await request("/api/links"));
    } catch (error) {
      showError(error.message);
    }
  }

  async function applyLinkAction(name, action, button) {
    button.disabled = true;
    try {
      await request(`/api/links/${encodeURIComponent(name)}/${action}`, { method: "POST" });
      await refreshLinks();
    } catch (error) {
      showError(error.message);
    } finally {
      button.disabled = false;
    }
  }

  async function applyLinkFaults(name, profile, button) {
    button.disabled = true;
    try {
      await request(`/api/links/${encodeURIComponent(name)}/faults`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(profile)
      });
      await refreshLinks();
    } catch (error) {
      showError(error.message);
    } finally {
      button.disabled = false;
    }
  }

  async function ensurePresetInstance(specification) {
    const current = (await request("/api/instances")).map(detailsOf);
    const existing = current.find(value => value.name === specification.name);
    if (existing) {
      if (existing.version !== specification.version ||
          Number(existing.port) !== specification.port) {
        throw new Error(`${specification.name} already exists with a different version or port`);
      }
      if (!existing.running) {
        await request(`/api/instances/${encodeURIComponent(specification.name)}/start`, { method: "POST" });
      }
      return;
    }
    await request("/api/instances", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(specification)
    });
  }

  async function ensurePresetLink(specification) {
    const current = await request("/api/links");
    const existing = current.find(value => value.name === specification.name);
    if (existing) {
      const matches = existing.source === specification.source &&
        existing.target === specification.target &&
        existing.mode === specification.mode &&
        (specification.mode !== "physical-streaming" ||
          Number(existing.target_port) === specification.target_port);
      if (!matches) throw new Error(`${specification.name} already names a different link`);
      if (["stopped", "failed"].includes(existing.status)) {
        throw new Error(`${specification.name} is stopped; remove it before recreating this preset`);
      }
      return;
    }
    await request("/api/links", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ target_port: 0, ...specification })
    });
  }

  async function waitForPresetInstances(names) {
    const deadline = Date.now() + 60000;
    while (Date.now() < deadline) {
      const current = await request("/api/instances");
      const ready = new Set(current
        .filter(value => String(value.Status || "").toLowerCase().includes("healthy"))
        .map(value => detailsOf(value).name));
      if (names.every(name => ready.has(name))) return;
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
    throw new Error("Timed out waiting for preset Postgres instances to become healthy");
  }

  async function createPreset(name) {
    const preset = topologyPresets[name];
    if (!preset) throw new Error("Choose a known topology preset");
    for (const instance of preset.instances) {
      launchPreset.textContent = `Starting ${instance.name}`;
      await ensurePresetInstance(instance);
    }
    launchPreset.textContent = "Waiting for Postgres";
    await waitForPresetInstances(preset.instances.map(instance => instance.name));
    await refreshInstances();
    for (const link of preset.links) {
      launchPreset.textContent = `Linking ${link.name}`;
      await ensurePresetLink(link);
    }
    await refreshLinks();
  }

  function renderInstances(values) {
    instances = values;
    list.replaceChildren();
    if (!values.length) {
      const empty = el("div", "empty-state");
      empty.append(el("span", "empty-glyph", "+"), el("h3", "", "No instances yet"), el("p", "", "Launch nodes from multiple Postgres generations, then connect them with a physical or logical replication path."));
      list.append(empty);
    } else {
      values.forEach(value => list.append(instanceNode(value)));
    }
    syncInstanceSelector();
  }

  async function refreshStatus() {
    try {
      const status = await request("/api/status");
      daemon.className = `daemon ${status.docker_ready ? "ready" : "failed"}`;
      daemon.lastElementChild.textContent = status.docker_ready
        ? `Docker ready · ${status.desired_instances} ${status.desired_instances === 1 ? "node" : "nodes"} / ${status.desired_links} ${status.desired_links === 1 ? "link" : "links"} saved`
        : status.detail;
      daemon.title = status.state_file || "";
    } catch (_error) {
      daemon.className = "daemon failed";
      daemon.lastElementChild.textContent = "Control plane unavailable";
    }
  }

  async function refreshInstances() {
    try {
      const [topology, actual] = await Promise.all([
        request("/api/topology"),
        request("/api/instances")
      ]);
      desiredTopology = topology;
      const nodeCount = topology.instances.length;
      const linkCount = topology.links.length;
      topologySummary.textContent =
        `${nodeCount} ${nodeCount === 1 ? "node" : "nodes"} and ${linkCount} ${linkCount === 1 ? "link" : "links"} persist across control-plane restarts`;
      topologyState.title = topology.state_file || "";
      renderInstances(actual);
      openReset.disabled = nodeCount === 0 && linkCount === 0 && actual.length === 0;
    } catch (error) {
      showError(error.message);
    }
  }

  async function applyAction(name, action, button) {
    button.disabled = true;
    try {
      await request(`/api/instances/${encodeURIComponent(name)}/${action}`, { method: "POST" });
      await refreshInstances();
    } catch (error) {
      showError(error.message);
    } finally {
      button.disabled = false;
    }
  }

  function addEvent(value) {
    if (value.type === "heartbeat") return;
    rememberLinkActivity(value);
    const item = el("li", "event");
    item.dataset.link = value.link || "";
    const timestamp = el("time", "", new Date().toLocaleTimeString([], { hour12: false }));
    const isLinkActivity = value.type === "link.activity";
    const type = el("span", "event-type", isLinkActivity ? `${value.link} / ${value.kind}` : (value.type || "event"));
    const detail = isLinkActivity
      ? [value.stage, value.direction, value.lsn, value.detail].filter(Boolean).join(" · ")
      : (() => {
          const fields = { ...value };
          delete fields.type;
          return Object.keys(fields).length ? JSON.stringify(fields) : "-";
        })();
    item.append(timestamp, type, el("span", "event-detail", detail));
    events.prepend(item);
    while (events.children.length > 80) events.lastElementChild.remove();
    applyActivityFilter();
  }

  function applyActivityFilter() {
    const selected = activityFilter.value;
    events.querySelectorAll(".event").forEach(item => {
      item.hidden = Boolean(selected) && item.dataset.link !== selected;
    });
    activityTitle.textContent = selected ? `${selected} activity stream` : "Live events";
  }

  function connectEvents() {
    const socket = new WebSocket(wsURL("/api/events"));
    socket.addEventListener("open", () => {
      streamState.textContent = "Live";
      streamState.classList.add("live");
    });
    socket.addEventListener("message", message => {
      try {
        const value = JSON.parse(message.data);
        addEvent(value);
        if (String(value.type || "").startsWith("instance.")
          || value.type === "topology.reconciled" || value.type === "topology.reset") refreshInstances();
        if (String(value.type || "").startsWith("link.") || value.type === "topology.reset") refreshLinks();
        if (value.type === "topology.reset") refreshStatus();
      } catch (_error) {
        addEvent({ type: "invalid.event", payload: String(message.data) });
      }
    });
    socket.addEventListener("close", () => {
      streamState.textContent = "Reconnecting";
      streamState.classList.remove("live");
      setTimeout(connectEvents, 1250);
    });
  }

  function resetQueryOutput() {
    resultBody = undefined;
    queryMessages.replaceChildren();
    queryResult.replaceChildren(el("p", "output-empty", "Waiting for columns and rows."));
    commandTag.textContent = "running";
  }

  function addQueryMessage(message, error = false) {
    queryMessages.append(el("div", `query-message${error ? " error" : ""}`, message));
  }

  function beginTable(columns) {
    const table = el("table", "result-table");
    const head = document.createElement("thead");
    const headRow = document.createElement("tr");
    columns.forEach(column => {
      const cell = document.createElement("th");
      cell.append(
        document.createTextNode(column.name || "column"),
        el("small", "", `${column.type_name || "unknown"} · OID ${column.type_oid}`)
      );
      headRow.append(cell);
    });
    head.append(headRow);
    resultBody = document.createElement("tbody");
    table.append(head, resultBody);
    queryResult.replaceChildren(table);
  }

  function addResultRow(values) {
    if (!resultBody) beginTable(values.map((_value, index) => ({ name: `column ${index + 1}`, type_oid: "?" })));
    const row = document.createElement("tr");
    values.forEach(value => {
      const cell = document.createElement("td");
      if (value === null) {
        cell.className = "null";
        cell.textContent = "NULL";
      } else {
        cell.textContent = value;
        cell.title = value;
      }
      row.append(cell);
    });
    resultBody.append(row);
  }

  function handleQueryEvent(value) {
    switch (value.type) {
      case "query.attached":
        queryState.textContent = `Attached on 127.0.0.1:${value.port}`;
        runQuery.disabled = false;
        break;
      case "query.started":
        queryRunning = true;
        runQuery.disabled = true;
        cancelQuery.disabled = false;
        queryState.textContent = `Running on ${value.instance}`;
        resetQueryOutput();
        break;
      case "query.columns": beginTable(value.columns || []); break;
      case "query.row": addResultRow(value.values || []); break;
      case "query.complete": commandTag.textContent = value.command || "complete"; break;
      case "query.notice": addQueryMessage(`${value.sql_state || "NOTICE"}: ${value.message}`); break;
      case "query.error":
        commandTag.textContent = "error";
        addQueryMessage(`${value.sql_state || "ERROR"}: ${value.message}`, true);
        break;
      case "query.cancelling": queryState.textContent = "Cancellation requested"; break;
      case "query.ready":
        queryRunning = false;
        runQuery.disabled = false;
        cancelQuery.disabled = true;
        queryState.textContent = `${value.rows} rows · ${value.elapsed_ms} ms${value.truncated ? " · output bounded" : ""}${value.cancelled ? " · cancelled" : ""}`;
        if (value.cancelled) commandTag.textContent = "cancelled";
        else if (commandTag.textContent === "running") commandTag.textContent = "ready";
        break;
      case "query.events-dropped": addQueryMessage(`${value.count} result events were dropped by the bounded stream`, true); break;
      case "query.output-truncated": addQueryMessage("A result event exceeded the 16 KiB message bound", true); break;
      case "query.busy":
      case "query.idle": addQueryMessage(value.message); break;
      default: break;
    }
  }

  function closeQuerySocket() {
    queryGeneration += 1;
    if (querySocket) querySocket.close();
    querySocket = undefined;
    queryRunning = false;
    runQuery.disabled = true;
    cancelQuery.disabled = true;
  }

  function connectQuery() {
    closeQuerySocket();
    if (!selectedName) return;
    const generation = queryGeneration;
    queryState.textContent = "Attaching query session";
    const socket = new WebSocket(wsURL(`/api/instances/${encodeURIComponent(selectedName)}/query`));
    querySocket = socket;
    socket.addEventListener("message", message => {
      if (generation !== queryGeneration) return;
      try { handleQueryEvent(JSON.parse(message.data)); }
      catch (_error) { addQueryMessage(`Invalid server event: ${message.data}`, true); }
    });
    socket.addEventListener("close", () => {
      if (generation !== queryGeneration) return;
      queryState.textContent = "Query session disconnected";
      runQuery.disabled = true;
      cancelQuery.disabled = true;
      if (selectedName) setTimeout(() => {
        if (generation === queryGeneration) connectQuery();
      }, 1250);
    });
    socket.addEventListener("error", () => {
      if (generation === queryGeneration) queryState.textContent = "Unable to attach query session";
    });
  }

  function appendLog(line) {
    if (logLines === 0) logOutput.textContent = "";
    logOutput.append(document.createTextNode(`${line}\n`));
    logLines += 1;
    while (logLines > 1200 && logOutput.firstChild) {
      logOutput.firstChild.remove();
      logLines -= 1;
    }
    if (followLogs.checked) logOutput.scrollTop = logOutput.scrollHeight;
  }

  function closeLogSocket() {
    logGeneration += 1;
    if (logSocket) logSocket.close();
    logSocket = undefined;
  }

  function connectLogs() {
    closeLogSocket();
    if (!selectedName || activeTab !== "logs") return;
    const generation = logGeneration;
    logStreamState.textContent = "Opening stream";
    logStreamState.classList.remove("live");
    logLines = 0;
    logOutput.innerHTML = "<span>Loading retained server output…</span>";
    const socket = new WebSocket(wsURL(`/api/instances/${encodeURIComponent(selectedName)}/logs`));
    logSocket = socket;
    socket.addEventListener("open", () => {
      if (generation !== logGeneration) return;
      logStreamState.textContent = "Live";
      logStreamState.classList.add("live");
    });
    socket.addEventListener("message", message => {
      if (generation !== logGeneration) return;
      try {
        const value = JSON.parse(message.data);
        if (value.type === "instance.log") appendLog(value.line);
      } catch (_error) {
        appendLog(`invalid log event: ${message.data}`);
      }
    });
    socket.addEventListener("close", () => {
      if (generation !== logGeneration) return;
      logStreamState.textContent = "Reconnecting";
      logStreamState.classList.remove("live");
      if (selectedName && activeTab === "logs") setTimeout(() => {
        if (generation === logGeneration) connectLogs();
      }, 1250);
    });
  }

  function switchTab(tab) {
    activeTab = tab;
    const querySelected = tab === "query";
    queryTab.setAttribute("aria-selected", String(querySelected));
    logsTab.setAttribute("aria-selected", String(!querySelected));
    queryPanel.hidden = !querySelected;
    logsPanel.hidden = querySelected;
    if (!querySelected) connectLogs();
    else closeLogSocket();
  }

  function selectInstance(name) {
    if (name !== selectedName) {
      selectedName = name;
      workspaceInstance.value = name;
      closeLogSocket();
      connectQuery();
    }
    workspace.hidden = false;
    if (activeTab === "logs") connectLogs();
    workspace.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  openCreate.addEventListener("click", () => {
    form.hidden = false;
    form.elements.name.focus();
  });
  closeCreate.addEventListener("click", () => { form.hidden = true; });
  form.addEventListener("submit", async event => {
    event.preventDefault();
    const submit = form.querySelector("[type=submit]");
    submit.disabled = true;
    try {
      const data = new FormData(form);
      await request("/api/instances", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: data.get("name"), version: data.get("version"), port: Number(data.get("port")) })
      });
      form.reset();
      form.elements.port.value = "55432";
      form.hidden = true;
      await refreshInstances();
    } catch (error) {
      showError(error.message);
    } finally {
      submit.disabled = false;
    }
  });

  openLink.addEventListener("click", () => {
    linkForm.hidden = false;
    syncLinkMode();
    linkForm.elements.name.focus();
  });
  openReset.addEventListener("click", () => {
    const actualCount = instances.length;
    const desiredCount = desiredTopology.instances.length;
    const linkCount = desiredTopology.links.length;
    resetSummary.textContent =
      `Remove ${actualCount} managed ${actualCount === 1 ? "container" : "containers"}, including ${desiredCount} desired ${desiredCount === 1 ? "node" : "nodes"}, and ${linkCount} replication ${linkCount === 1 ? "link" : "links"}.`;
    resetPanel.hidden = false;
    confirmReset.focus();
  });
  cancelReset.addEventListener("click", () => {
    resetPanel.hidden = true;
    openReset.focus();
  });
  confirmReset.addEventListener("click", async () => {
    const creationControls = [openCreate, openLink, topologyPreset, launchPreset];
    creationControls.forEach(control => { control.disabled = true; });
    openReset.disabled = true;
    confirmReset.disabled = true;
    cancelReset.disabled = true;
    resetPanel.setAttribute("aria-busy", "true");
    confirmReset.textContent = "Resetting lab";
    try {
      await request("/api/lab/reset", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ confirmation: "reset-lab" })
      });
      closeQuerySocket();
      closeLogSocket();
      selectedName = "";
      workspace.hidden = true;
      resetPanel.hidden = true;
      await Promise.all([refreshInstances(), refreshLinks(), refreshStatus()]);
      openCreate.focus();
    } catch (error) {
      await Promise.allSettled([refreshInstances(), refreshLinks(), refreshStatus()]);
      showError(error.message);
    } finally {
      resetPanel.removeAttribute("aria-busy");
      confirmReset.textContent = "Reset lab";
      confirmReset.disabled = false;
      cancelReset.disabled = false;
      creationControls.forEach(control => { control.disabled = false; });
      openReset.disabled = desiredTopology.instances.length === 0
        && desiredTopology.links.length === 0 && instances.length === 0;
    }
  });
  launchPreset.addEventListener("click", async () => {
    launchPreset.disabled = true;
    topologyPreset.disabled = true;
    try {
      await createPreset(topologyPreset.value);
      launchPreset.textContent = "Preset ready";
      setTimeout(() => { launchPreset.textContent = "Create topology"; }, 1800);
    } catch (error) {
      showError(error.message);
      launchPreset.textContent = "Create topology";
    } finally {
      launchPreset.disabled = false;
      topologyPreset.disabled = false;
    }
  });
  closeLink.addEventListener("click", () => { linkForm.hidden = true; });
  linkMode.addEventListener("change", syncLinkMode);
  linkForm.addEventListener("submit", async event => {
    event.preventDefault();
    const submit = linkForm.querySelector("[type=submit]");
    submit.disabled = true;
    try {
      const data = new FormData(linkForm);
      const physical = data.get("mode") === "physical-streaming";
      const sourceRelation = String(data.get("source_relation") || "").split(".");
      const targetRelation = String(data.get("target_relation") || "").split(".");
      await request("/api/links", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: data.get("name"), source: data.get("source"), target: physical ? data.get("standby") : data.get("target"), target_port: physical ? Number(data.get("target_port")) : 0, mode: data.get("mode"), source_schema: sourceRelation.length === 2 ? sourceRelation[0] : "", source_table: sourceRelation.length === 2 ? sourceRelation[1] : "", target_schema: targetRelation.length === 2 ? targetRelation[0] : "", target_table: targetRelation.length === 2 ? targetRelation[1] : "", column_map: physical ? "" : String(data.get("column_map") || "").trim() })
      });
      linkForm.reset();
      linkTargetPort.value = "55434";
      syncLinkMode();
      linkForm.hidden = true;
      await refreshLinks();
    } catch (error) {
      showError(error.message);
    } finally {
      submit.disabled = false;
    }
  });

  workspaceInstance.addEventListener("change", () => selectInstance(workspaceInstance.value));
  queryTab.addEventListener("click", () => switchTab("query"));
  logsTab.addEventListener("click", () => switchTab("logs"));
  runQuery.addEventListener("click", () => {
    if (!querySocket || querySocket.readyState !== WebSocket.OPEN) {
      showError("The query session is not attached yet");
      return;
    }
    if (!queryInput.value.trim()) {
      showError("Enter a SQL statement first");
      return;
    }
    querySocket.send(JSON.stringify({ sql: queryInput.value }));
  });
  cancelQuery.addEventListener("click", () => {
    if (querySocket?.readyState === WebSocket.OPEN && queryRunning) {
      querySocket.send(JSON.stringify({ type: "cancel" }));
      cancelQuery.disabled = true;
      queryState.textContent = "Requesting cancellation";
    }
  });
  queryInput.addEventListener("keydown", event => {
    if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      runQuery.click();
    }
  });
  clearLogs.addEventListener("click", () => {
    logLines = 0;
    logOutput.textContent = "View cleared. New server output will appear here.\n";
  });
  activityFilter.addEventListener("change", applyActivityFilter);

  refreshStatus();
  refreshInstances();
  refreshLinks();
  connectEvents();
  setInterval(refreshStatus, 5000);
  setInterval(refreshInstances, 8000);
  setInterval(refreshLinks, 3000);
})();
