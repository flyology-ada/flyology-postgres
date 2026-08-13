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
  let toastTimer;

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

  function el(tag, className, text) {
    const value = document.createElement(tag);
    if (className) value.className = className;
    if (text !== undefined) value.textContent = text;
    return value;
  }

  function instanceNode(instance) {
    const labels = labelsOf(instance.Labels);
    const name = labels["org.flyology.psqlbench.instance"] || String(instance.Names || "").replace(/^psqlbench-/, "");
    const version = labels["org.flyology.psqlbench.version"] || String(instance.Image || "postgres:?").split(":")[1];
    const port = labels["org.flyology.psqlbench.port"] || "—";
    const running = String(instance.State || "").toLowerCase() === "running";
    const article = el("article", `node ${running ? "running" : "stopped"}`);
    const head = el("div", "node-head");
    const title = document.createElement("div");
    title.append(el("span", "node-version", `POSTGRES ${version}`));
    title.append(el("h3", "node-name", name));
    head.append(title, el("span", "node-status", running ? "running" : (instance.State || "stopped")));

    const meta = el("dl", "node-meta");
    [["host", `127.0.0.1:${port}`], ["container", instance.Names || `psqlbench-${name}`], ["health", instance.Status || "unknown"]]
      .forEach(([key, value]) => {
        const row = document.createElement("div");
        row.append(el("dt", "", key), el("dd", "", value));
        meta.append(row);
      });

    const actions = el("div", "node-actions");
    const stateAction = el("button", "button secondary", running ? "Stop" : "Start");
    stateAction.type = "button";
    stateAction.addEventListener("click", () => applyAction(name, running ? "stop" : "start", stateAction));
    const remove = el("button", "button danger", "Remove");
    remove.type = "button";
    remove.addEventListener("click", () => applyAction(name, "remove", remove));
    actions.append(stateAction, remove);
    article.append(head, meta, actions);
    return article;
  }

  function renderInstances(values) {
    list.replaceChildren();
    if (!values.length) {
      const empty = el("div", "empty-state");
      empty.append(el("span", "empty-glyph", "+"), el("h3", "", "No instances yet"), el("p", "", "Launch nodes from multiple Postgres generations, then connect them with a physical or logical replication path."));
      list.append(empty);
      return;
    }
    values.forEach(value => list.append(instanceNode(value)));
  }

  async function refreshStatus() {
    try {
      const status = await request("/api/status");
      daemon.className = `daemon ${status.docker_ready ? "ready" : "failed"}`;
      daemon.lastElementChild.textContent = status.docker_ready ? "Docker ready · CLI transport" : status.detail;
    } catch (error) {
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
    item.append(timestamp, type, el("span", "event-detail", Object.keys(detail).length ? JSON.stringify(detail) : "—"));
    events.prepend(item);
    while (events.children.length > 80) events.lastElementChild.remove();
  }

  function connectEvents() {
    const scheme = location.protocol === "https:" ? "wss:" : "ws:";
    const socket = new WebSocket(`${scheme}//${location.host}/api/events`);
    socket.addEventListener("open", () => {
      streamState.textContent = "Live";
      streamState.classList.add("live");
    });
    socket.addEventListener("message", message => {
      try {
        const value = JSON.parse(message.data);
        addEvent(value);
        if (String(value.type || "").startsWith("instance.")) refreshInstances();
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

  refreshStatus();
  refreshInstances();
  connectEvents();
  setInterval(refreshStatus, 5000);
  setInterval(refreshInstances, 8000);
})();
