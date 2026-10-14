#!/usr/bin/env node
/**
 * link-workspaces.mjs
 *
 * For a worktree whose root `node_modules` is a symlink to another worktree's
 * (e.g. main) node_modules, re-link the *workspace* packages so `@scope/*`
 * imports resolve to THIS worktree's source instead of the shared one.
 *
 * Mechanism: node walks up from the importing file checking each ancestor's
 * node_modules. We place a small override at each top-level workspace parent
 * (e.g. packages/node_modules/@scope/<pkg>), found BEFORE the root symlink.
 * Third-party deps are untouched and keep resolving live through the root
 * symlink, so main adding/removing third-party packages never breaks or misses
 * anything here. Only the workspace set needs re-running (rare).
 *
 * Idempotent. Usage:
 *   node link-workspaces.mjs [rootDir]              # create/refresh overrides (absolute targets)
 *   node link-workspaces.mjs [rootDir] --relative   # use relative targets (survive moving the repo)
 *   node link-workspaces.mjs [rootDir] --clean      # remove the overrides we manage
 *   node link-workspaces.mjs [rootDir] --check      # report missing/wrong overrides; change nothing (exit 1 if any)
 */
import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, readlinkSync, rmSync, symlinkSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';

const args = process.argv.slice(2);
const clean = args.includes('--clean');
const check = args.includes('--check');
const useRelative = args.includes('--relative');
const root = resolve(args.find((a) => !a.startsWith('--')) ?? process.cwd());

// A non-workspace repo (no package.json, or no workspaces field) has nothing to
// link — report and exit 0 so callers (wt-link) treat it as "ok".
let rootPkg = {};
try { rootPkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')); } catch {}
const patterns = rootPkg.workspaces ?? [];
if (patterns.length === 0) {
  console.log('No workspaces configured; nothing to link.');
  if (check) console.log('ISSUES=0');
  process.exit(0);
}

// Expand a workspace pattern to package dirs (dirs containing a package.json).
// Segment-based glob: each `*` matches exactly one path segment, so patterns
// like `packages/*`, `packages/*/*`, and literal `tools` all work.
function expand(pattern) {
  const segments = pattern.replace(/\\/g, '/').replace(/^\/+|\/+$/g, '').split('/');
  let current = [root];
  for (const seg of segments) {
    const next = [];
    for (const dir of current) {
      if (seg === '*') {
        if (!existsSync(dir)) continue;
        for (const e of readdirSync(dir, { withFileTypes: true })) {
          if (e.isDirectory()) next.push(join(dir, e.name));
        }
      } else {
        next.push(join(dir, seg));
      }
    }
    current = next;
  }
  return current.filter((d) => existsSync(join(d, 'package.json')));
}

const packages = [...new Set(patterns.flatMap(expand))]
  .map((dir) => ({ dir, name: JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8')).name }))
  .filter((p) => p.name);

// Top-level parents (first path segment relative to root): packages / surfaces / tools.
const parents = [...new Set(packages.map((p) => relative(root, p.dir).split('/')[0]))];

let okCount = 0;
let badCount = 0;

for (const parent of parents) {
  for (const { dir, name } of packages) {
    const linkPath = join(root, parent, 'node_modules', name); // name may be @scope/pkg
    if (clean) {
      try {
        if (lstatSync(linkPath).isSymbolicLink()) {
          rmSync(linkPath);
          console.log(`removed ${relative(root, linkPath)}`);
        }
      } catch {}
      continue;
    }
    if (check) {
      const expected = useRelative ? relative(dirname(linkPath), dir) : dir;
      let st = null;
      try { st = lstatSync(linkPath); } catch {}
      if (st && st.isSymbolicLink()) {
        const actual = readlinkSync(linkPath);
        const resolves = existsSync(resolve(dirname(linkPath), actual));
        if (actual === expected && resolves) {
          okCount++;
        } else if (!resolves) {
          badCount++; console.log(`  ${relative(root, linkPath)}: broken -> ${actual}`);
        } else {
          badCount++; console.log(`  ${relative(root, linkPath)}: wrong -> ${actual}`);
        }
      } else if (st) {
        badCount++; console.log(`  ${relative(root, linkPath)}: real (expected symlink)`);
      } else {
        badCount++; console.log(`  ${relative(root, linkPath)}: missing`);
      }
      continue;
    }
    // Only create the scope dir for scoped names (@scope/pkg); for unscoped
    // names the leaf path is the link itself, so mkdir the parent node_modules.
    const scopeDir = name.includes('/')
      ? join(root, parent, 'node_modules', name.split('/')[0])
      : join(root, parent, 'node_modules');
    mkdirSync(scopeDir, { recursive: true });
    try {
      const st = lstatSync(linkPath);
      if (st.isSymbolicLink()) rmSync(linkPath);
      else if (st.isDirectory()) rmSync(linkPath, { recursive: true, force: true });
      else rmSync(linkPath);
    } catch {}
    const target = useRelative ? relative(dirname(linkPath), dir) : dir;
    symlinkSync(target, linkPath, 'dir');
    console.log(`linked ${relative(root, linkPath)} -> ${target}`);
  }
}
if (check) {
  console.log(`Workspaces: ${okCount} ok, ${badCount} issue(s).`);
  // Machine-readable summary for callers (wt-link.sh).
  console.log(`ISSUES=${badCount}`);
  process.exit(badCount ? 1 : 0);
}
console.log(clean ? 'Cleaned.' : `Done. ${packages.length} package(s) x ${parents.length} parent(s).`);
