#!/usr/bin/env node

import { access, readFile, writeFile } from "node:fs/promises";
import { basename, dirname, resolve } from "node:path";

const requestedIndex = process.argv[2];
if (!requestedIndex) {
  console.error("usage: node scripts/fix-gnatdoc-index-links.mjs <index.html>");
  process.exit(2);
}

const indexPath = resolve(requestedIndex);
const outputDirectory = dirname(indexPath);
const html = await readFile(indexPath, "utf8");
const links = Array.from(
  html.matchAll(/<a\s+href=(?:"([^"]+)"|'([^']+)'|([^\s>]+))[^>]*>([^<]+)<\/a>/g),
  (match) => ({
    href: match[1] || match[2] || match[3],
    label: match[4],
  })
);
const units = new Map(
  links
    .filter(({ href }) => href.endsWith(".html"))
    .map(({ href, label }) => [label, href])
);

let corrected = html;
let correctionCount = 0;

for (const { href, label } of links) {
  if (!href.endsWith(".html") || (await exists(resolve(outputDirectory, href)))) {
    continue;
  }

  const unitName = longestUnitPrefix(label, units);
  if (!unitName) continue;

  const unitHref = units.get(unitName);
  const anchor = basename(href, ".html");
  const unitHtml = await readFile(resolve(outputDirectory, unitHref), "utf8");
  if (!unitHtml.includes(`id=${anchor}`) &&
      !unitHtml.includes(`id="${anchor}"`) &&
      !unitHtml.includes(`id='${anchor}'`)) {
    continue;
  }

  corrected = corrected.replace(`href=${href}>${label}</a>`,
                                `href=${unitHref}#${anchor}>${label}</a>`);
  correctionCount += 1;
}

if (correctionCount > 0) await writeFile(indexPath, corrected);
console.log(`Corrected ${correctionCount} GNATdoc index link(s).`);

async function exists(path) {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

function longestUnitPrefix(label, unitMap) {
  let candidate = label;
  while (candidate.includes(".")) {
    candidate = candidate.slice(0, candidate.lastIndexOf("."));
    if (unitMap.has(candidate)) return candidate;
  }
  return null;
}
