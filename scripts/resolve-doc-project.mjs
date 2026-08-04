#!/usr/bin/env node

import { spawnSync } from "node:child_process";

const requestedProject = process.argv[2];
if (!requestedProject) {
  console.error("usage: node scripts/resolve-doc-project.mjs <project-file-name>");
  process.exit(2);
}

const inspection = spawnSync(
  "gprinspect",
  ["--display=json-compact", "-r", "-P", "flyology_postgres.gpr"],
  { encoding: "utf8" }
);

if (inspection.status !== 0) {
  process.stderr.write(inspection.stderr);
  process.exit(inspection.status ?? 1);
}

const graph = JSON.parse(inspection.stdout);
const match = graph.projects.find(
  (entry) => entry.project?.["simple-name"] === requestedProject
);

if (!match?.project?.["file-name"]) {
  console.error(`unable to resolve ${requestedProject} from the project graph`);
  process.exit(1);
}

process.stdout.write(`${match.project["file-name"]}\n`);
