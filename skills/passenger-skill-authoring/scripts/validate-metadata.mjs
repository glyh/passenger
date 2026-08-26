// Validates a site skill's metadata.json against schema/metadata.schema.json.
//
// It walks the schema rather than restating it, deliberately: a hand-written
// checker beside a schema file is two copies of one rule, and the copy that
// stops being read is the one that stops being true. The subset of JSON Schema
// interpreted here is exactly what metadata.schema.json uses -- adding a
// keyword to the schema without adding it below fails loudly (see `unknown
// keyword` at the bottom) instead of silently passing everything.
//
//   node validate-metadata.mjs path/to/passenger-<site>/metadata.json
//
// Exits 0 and prints a per-table summary, or exits 1 listing every failure at
// its JSON path. Zero dependencies on purpose: it is run off disk, from
// anywhere, by whoever is about to commit a skill.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const SCHEMA = join(dirname(fileURLToPath(import.meta.url)), "..", "schema", "metadata.schema.json");

const KNOWN = new Set([
  "$schema", "$id", "title", "description", "$defs", "$ref",
  "type", "required", "properties", "additionalProperties", "patternProperties",
  "minProperties", "minItems", "minLength", "pattern", "enum", "const", "items", "oneOf",
]);

const typeOf = v => Array.isArray(v) ? "array" : v === null ? "null" : typeof v;

function resolve(ref, root) {
  if (!ref.startsWith("#/")) throw new Error(`only local $ref supported: ${ref}`);
  return ref.slice(2).split("/").reduce((node, seg) => {
    if (node === undefined) throw new Error(`$ref does not resolve: ${ref}`);
    return node[seg.replace(/~1/g, "/").replace(/~0/g, "~")];
  }, root);
}

function check(value, schema, root, path, errs) {
  for (const k of Object.keys(schema)) {
    if (!KNOWN.has(k)) errs.push(`${path}: schema uses unknown keyword \`${k}\` — teach the validator or drop it`);
  }
  if (schema.$ref) return check(value, resolve(schema.$ref, root), root, path, errs);

  if (schema.oneOf) {
    // Report the branch that got furthest rather than every branch's noise: a
    // table is either shipped or upstream, and the author knows which they meant.
    const attempts = schema.oneOf.map(s => { const e = []; check(value, s, root, path, e); return e; });
    if (!attempts.some(e => e.length === 0)) {
      const best = attempts.reduce((a, b) => (b.length < a.length ? b : a));
      errs.push(...best);
    }
    return;
  }

  if (schema.type && typeOf(value) !== schema.type) {
    return void errs.push(`${path}: expected ${schema.type}, got ${typeOf(value)}`);
  }
  if (schema.const !== undefined && value !== schema.const) {
    errs.push(`${path}: must be ${JSON.stringify(schema.const)}`);
  }
  if (schema.enum && !schema.enum.includes(value)) {
    errs.push(`${path}: must be one of ${schema.enum.join(" | ")}, got ${JSON.stringify(value)}`);
  }
  if (schema.minLength !== undefined && typeof value === "string" && value.length < schema.minLength) {
    errs.push(`${path}: must not be empty`);
  }
  if (schema.pattern && typeof value === "string" && !new RegExp(schema.pattern).test(value)) {
    errs.push(`${path}: ${JSON.stringify(value)} does not match ${schema.pattern}`);
  }

  if (typeOf(value) === "array") {
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      errs.push(`${path}: needs at least ${schema.minItems} item(s)`);
    }
    if (schema.items) value.forEach((v, i) => check(v, schema.items, root, `${path}[${i}]`, errs));
  }

  if (typeOf(value) === "object") {
    if (schema.minProperties !== undefined && Object.keys(value).length < schema.minProperties) {
      errs.push(`${path}: needs at least ${schema.minProperties} entr(y|ies)`);
    }
    for (const req of schema.required ?? []) {
      if (!(req in value)) errs.push(`${path}: missing required \`${req}\``);
    }
    const patterns = Object.entries(schema.patternProperties ?? {});
    for (const [k, v] of Object.entries(value)) {
      const sub = `${path}.${k}`;
      if (schema.properties?.[k]) { check(v, schema.properties[k], root, sub, errs); continue; }
      const hit = patterns.find(([p]) => new RegExp(p).test(k));
      if (hit) { check(v, hit[1], root, sub, errs); continue; }
      if (schema.additionalProperties === false) {
        errs.push(patterns.length
          ? `${path}: key \`${k}\` does not match ${patterns.map(([p]) => p).join(" | ")}`
          : `${path}: unexpected key \`${k}\``);
      }
    }
  }
}

const target = process.argv[2];
if (!target) {
  console.error("usage: node validate-metadata.mjs path/to/passenger-<site>/metadata.json");
  process.exit(2);
}

const schema = JSON.parse(readFileSync(SCHEMA, "utf8"));

// This file gets hand-edited, so a trailing comma is the most likely failure of
// all. Node's own message names the line and column; a stack trace on top of it
// only buries that.
let doc;
try {
  doc = JSON.parse(readFileSync(target, "utf8"));
} catch (e) {
  console.error(`${target}: not valid JSON — ${e.message}`);
  process.exit(1);
}

const errs = [];
check(doc, schema, schema, "metadata", errs);

if (errs.length) {
  console.error(`${target}: ${errs.length} problem(s)\n`);
  for (const e of errs) console.error("  " + e);
  process.exit(1);
}

// The summary is the point of running this even when it passes: `derived` rows
// and `partial` coverage are the two things a reader mistakes for measured fact.
console.log(`${target}: ok — site \`${doc.site}\``);
for (const [name, t] of Object.entries(doc.tables)) {
  if (t.source === "upstream") {
    console.log(`  ${name}: upstream, not shipped — ${t.url}`);
    continue;
  }
  const unverified = t.entries.filter(e => !e.verified).length;
  console.log(
    `  ${name}: ${t.entries.length} row(s), ${t.coverage}, measured ${t.measured}` +
    (unverified ? `  ⚠ ${unverified} unverified (source: ${t.source})` : ""));
}
