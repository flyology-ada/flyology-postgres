(() => {
  "use strict";

  const daemon = document.querySelector("#daemon-status");
  const list = document.querySelector("#instance-list");
  const form = document.querySelector("#create-form");
  const openCreate = document.querySelector("#open-create");
  const closeCreate = document.querySelector("#close-create");
  const events = document.querySelector("#event-list");
  const streamState = document.querySelector("#stream-state");
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

  let toastTimer;
  let instances = [];
  let links = [];
  let selectedName = "";
  let activeTab = "query";
  let querySocket;
  let queryGeneration = 0;
  let queryRunning = false;
  let resultBody;
  let logSocket;
  let logGeneration = 0;
  let logLines = 0;

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
    return {
      name: labels["org.flyology.psqlbench.instance"] || String(instance.Names || "").replace(/^psqlbench-/, ""),
      version: labels["org.flyology.psqlbench.version"] || String(instance.Image || "postgres:?").split(":")[1],
      port: labels["org.flyology.psqlbench.port"] || "-",
      running: String(instance.State || "").toLowerCase() === "running"
    };
  }

  function el(tag, className, text) {
    const value = document.createElement(tag);
    if (className) value.className = className;
    if (text !== undefined) value.textContent = text;
    return value;
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
    [["host", `127.0.0.1:${details.port}`], ["container", instance.Names || `psqlbench-${details.name}`], ["health", instance.Status || "unknown"]]
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
    openLink.disabled = running.length < 2;
  }

  function linkNode(link) {
    const article = el("article", `link-card ${link.status}`);
    const heading = el("div", "link-card-heading");
    const title = document.createElement("div");
    const streamed = link.mode === "logical-streaming";
    title.append(el("span", "node-version", streamed ? "LOGICAL · STREAMING · PGOUTPUT V2" : "LOGICAL · COMMITTED · PGOUTPUT V1"), el("h3", "node-name", link.name));
    heading.append(title, el("span", "node-status", link.status));

    const route = el("div", "link-route");
    route.append(
      el("strong", "", link.source),
      el("span", "", "client → server → client"),
      el("strong", "", link.target)
    );

    const stats = el("dl", "link-stats");
    [["table", `public.${link.table}`], ["changes", String(link.changes || 0)], ["last lsn", link.last_lsn || "waiting"], ["relay", `127.0.0.1:${link.relay_port}`]]
      .forEach(([key, value]) => {
        const row = document.createElement("div");
        row.append(el("dt", "", key), el("dd", "", value));
        stats.append(row);
      });

    const detail = el("p", "link-detail", link.detail || "Waiting for supervised link activity");
    const actions = el("div", "node-actions");
    const insert = el("button", "button primary", "Insert demo row");
    insert.type = "button";
    insert.disabled = link.status !== "running";
    insert.addEventListener("click", () => {
      selectInstance(link.source);
      queryInput.value = `insert into public."${link.table}" (id, payload)\nvalues ((extract(epoch from clock_timestamp()) * 1000000)::bigint,\n        'sent through ${link.name}')\nreturning *;`;
      switchTab("query");
      queryInput.focus();
    });
    const inspect = el("button", "button secondary", "Inspect target");
    inspect.type = "button";
    inspect.addEventListener("click", () => {
      selectInstance(link.target);
      queryInput.value = `select * from public."${link.table}" order by id desc limit 20;`;
      switchTab("query");
    });
    const pattern = el("button", "button secondary", streamed ? "Load streamed transaction" : "Load message patterns");
    pattern.type = "button";
    pattern.disabled = link.status !== "running";
    pattern.addEventListener("click", () => {
      selectInstance(link.source);
      queryInput.value = streamed
        ? `insert into public."${link.table}" (id, payload)\nselect 1000000 + n, repeat('streamed-', 128) || n\nfrom generate_series(1, 300) as n;`
        : `select pg_logical_emit_message(false, 'psqlbench', 'non-transactional message');\nbegin;\nselect pg_logical_emit_message(true, 'psqlbench', 'transactional message');\ninsert into public."${link.table}" (id, payload)\nvalues ((extract(epoch from clock_timestamp()) * 1000000)::bigint, 'same transaction');\ncommit;`;
      switchTab("query");
      queryInput.focus();
    });
    const stop = el("button", "button secondary", "Stop");
    stop.type = "button";
    stop.disabled = !["running", "starting", "pending"].includes(link.status);
    stop.addEventListener("click", () => applyLinkAction(link.name, "stop", stop));
    actions.append(insert, pattern, inspect, stop);
    article.append(heading, route, stats, detail, actions);
    return article;
  }

  function renderLinks(values) {
    links = values;
    linkList.replaceChildren();
    if (!values.length) {
      const empty = el("div", "link-empty");
      empty.append(el("p", "", "No logical bridges yet. Create two running instances to connect a managed demo table."));
      linkList.append(empty);
      return;
    }
    values.forEach(value => linkList.append(linkNode(value)));
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
      daemon.lastElementChild.textContent = status.docker_ready ? "Docker ready · CLI transport" : status.detail;
    } catch (_error) {
      daemon.className = "daemon failed";
      daemon.lastElementChild.textContent = "Control plane unavailable";
    }
  }

  async function refreshInstances() {
    try {
      renderInstances(await request("/api/instances"));
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
    const item = el("li", "event");
    const timestamp = el("time", "", new Date().toLocaleTimeString([], { hour12: false }));
    const type = el("span", "event-type", value.type || "event");
    const detail = { ...value };
    delete detail.type;
    item.append(timestamp, type, el("span", "event-detail", Object.keys(detail).length ? JSON.stringify(detail) : "-"));
    events.prepend(item);
    while (events.children.length > 80) events.lastElementChild.remove();
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
        if (String(value.type || "").startsWith("instance.")) refreshInstances();
        if (String(value.type || "").startsWith("link.")) refreshLinks();
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
    linkForm.elements.name.focus();
  });
  closeLink.addEventListener("click", () => { linkForm.hidden = true; });
  linkForm.addEventListener("submit", async event => {
    event.preventDefault();
    const submit = linkForm.querySelector("[type=submit]");
    submit.disabled = true;
    try {
      const data = new FormData(linkForm);
      await request("/api/links", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: data.get("name"), source: data.get("source"), target: data.get("target"), mode: data.get("mode") })
      });
      linkForm.reset();
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

  refreshStatus();
  refreshInstances();
  refreshLinks();
  connectEvents();
  setInterval(refreshStatus, 5000);
  setInterval(refreshInstances, 8000);
  setInterval(refreshLinks, 3000);
})();
