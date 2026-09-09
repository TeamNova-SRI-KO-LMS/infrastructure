#!/usr/bin/env node
/**
 * Validate the infrastructure definitions without needing Docker.
 *
 *   npm run validate
 *
 * The CI pipeline does this properly — it builds the images and boots the
 * stack. This is the fast local version: it parses every YAML file, checks the
 * composite action against the rules the Marketplace enforces, and cross-checks
 * that the files the workflows and compose stacks reference actually exist.
 *
 * That last check is the one that repays writing it. A workflow referring to
 * `compose/docker-compose.ci.yml` is valid YAML whether or not the file is
 * there; the mistake only surfaces when the workflow runs, which for a
 * deployment workflow means the first deployment.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');

const ROOT = path.resolve(__dirname, '..');

const errors = [];
const warnings = [];
let checks = 0;

const rel = (file) => path.relative(ROOT, file);
const check = (condition, message) => {
  checks += 1;
  if (!condition) errors.push(message);
};

function walk(dir, filter, found = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      if (['node_modules', '.git', 'backups'].includes(entry.name)) continue;
      walk(path.join(dir, entry.name), filter, found);
    } else if (filter(entry.name)) {
      found.push(path.join(dir, entry.name));
    }
  }
  return found;
}

// ── Every YAML file parses ───────────────────────────────────────────────────

const yamlFiles = walk(ROOT, (name) => name.endsWith('.yml') || name.endsWith('.yaml'));

for (const file of yamlFiles) {
  checks += 1;
  try {
    yaml.load(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    errors.push(`${rel(file)}: ${error.message.split('\n')[0]}`);
  }
}

// ── Workflows ────────────────────────────────────────────────────────────────

const workflowDir = path.join(ROOT, '.github', 'workflows');
const workflows = fs.existsSync(workflowDir)
  ? fs.readdirSync(workflowDir).filter((name) => name.endsWith('.yml'))
  : [];

check(workflows.length > 0, 'no workflows found in .github/workflows');

for (const name of workflows) {
  const file = path.join(workflowDir, name);
  let spec;
  try {
    spec = yaml.load(fs.readFileSync(file, 'utf8'));
  } catch {
    continue; // already reported above
  }

  // `on:` is YAML 1.1's boolean true, which is why it arrives as a `true` key.
  const triggers = spec.on ?? spec[true];
  check(triggers !== undefined, `${name}: no trigger declared`);
  check(Boolean(spec.name), `${name}: no workflow name`);

  // A workflow with no `permissions` block inherits the repository default,
  // which is usually broader than the job needs. Making it explicit is the
  // cheapest hardening available.
  if (!spec.permissions) {
    warnings.push(
      `${name}: no top-level \`permissions\` — the job inherits the repository default`,
    );
  }

  // Two deployments running at once is a race with a production environment as
  // the shared resource.
  if (!spec.concurrency) {
    warnings.push(`${name}: no \`concurrency\` group`);
  }

  for (const [jobId, job] of Object.entries(spec.jobs || {})) {
    check(
      Boolean(job['runs-on'] || job.uses),
      `${name}: job "${jobId}" has neither runs-on nor uses`,
    );

    for (const step of job.steps || []) {
      // An unpinned action is remote code with this repository's token.
      if (typeof step.uses === 'string' && step.uses.includes('@')) {
        const ref = step.uses.split('@').pop();
        if (['main', 'master', 'develop', 'latest'].includes(ref)) {
          errors.push(`${name}: "${step.uses}" is pinned to a moving ref`);
        }
      }
    }
  }
}

// ── Compose stacks ───────────────────────────────────────────────────────────

const composeDir = path.join(ROOT, 'compose');
const composeFiles = fs.existsSync(composeDir)
  ? fs.readdirSync(composeDir).filter((name) => name.startsWith('docker-compose'))
  : [];

check(composeFiles.length > 0, 'no compose files found');

for (const name of composeFiles) {
  const file = path.join(composeDir, name);
  let spec;
  try {
    spec = yaml.load(fs.readFileSync(file, 'utf8'));
  } catch {
    continue;
  }

  check(Boolean(spec.services), `${name}: no services`);

  for (const [service, definition] of Object.entries(spec.services || {})) {
    check(
      Boolean(definition.image || definition.build),
      `${name}: service "${service}" has neither image nor build`,
    );

    // A service with no healthcheck cannot be waited on, so `up --wait`
    // returns as soon as the container is created — and a container that
    // crashes on start reads as a successful deployment.
    //
    // Our own images carry a HEALTHCHECK in the Dockerfile, which Compose
    // inherits, so a service that builds from them or runs one of them needs
    // no `healthcheck:` block. Only third-party images have to declare one.
    const image = definition.image || '';
    const isOurs = Boolean(definition.build) || /sri-ko|BACKEND_IMAGE|FRONTEND_IMAGE/.test(image);

    if (!definition.healthcheck && !isOurs) {
      warnings.push(`${name}: service "${service}" declares no healthcheck`);
    }
  }
}

// ── The composite action ─────────────────────────────────────────────────────

const actionFile = path.join(ROOT, 'action.yml');
if (fs.existsSync(actionFile)) {
  const action = yaml.load(fs.readFileSync(actionFile, 'utf8'));

  for (const key of ['name', 'description', 'author', 'branding', 'runs']) {
    check(
      Boolean(action[key]),
      `action.yml: missing "${key}" (required for a Marketplace listing)`,
    );
  }

  check(action.runs?.using === 'composite', 'action.yml: runs.using must be "composite"');

  (action.runs?.steps || []).forEach((step, index) => {
    if (step.run && !step.shell) {
      errors.push(`action.yml: step ${index} ("${step.name || '?'}") has \`run\` but no \`shell\``);
    }
  });

  for (const [key, value] of Object.entries(action.inputs || {})) {
    check(Boolean(value.description), `action.yml: input "${key}" has no description`);
    if (value.required && value.default) {
      errors.push(`action.yml: input "${key}" is required but also has a default`);
    }
  }

  for (const [key, value] of Object.entries(action.outputs || {})) {
    check(Boolean(value.description), `action.yml: output "${key}" has no description`);
  }
}

// ── Referenced files exist ───────────────────────────────────────────────────

const referenced = [
  ...composeFiles.map((name) => `compose/${name}`),
  'docker/backend.Dockerfile',
  'docker/frontend.Dockerfile',
  'docker/nginx/default.conf',
  'docker/mongo/init/01-init.js',
  'scripts/deploy.sh',
  'scripts/rollback.sh',
  'scripts/smoke-test.sh',
  'scripts/backup-mongo.sh',
  '.env.example',
  'README.md',
];

for (const target of referenced) {
  check(fs.existsSync(path.join(ROOT, target)), `missing: ${target}`);
}

// Scripts must be executable, or the deploy action's `run:` fails on the host
// with "permission denied" after it has already stopped the old stack.
for (const script of walk(path.join(ROOT, 'scripts'), (name) => name.endsWith('.sh'))) {
  checks += 1;
  // eslint-disable-next-line no-bitwise
  if (!(fs.statSync(script).mode & 0o111)) {
    errors.push(`${rel(script)} is not executable (chmod +x)`);
  }
}

// ── Nothing that looks like a secret ─────────────────────────────────────────

const SECRET_PATTERNS = [
  [/\bAKIA[0-9A-Z]{16}\b/, 'AWS access key id'],
  [/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/, 'private key'],
  [/\bgh[pousr]_[A-Za-z0-9]{36,}\b/, 'GitHub token'],
  // A literal password in a connection string. `${VAR}` interpolation and the
  // obvious placeholders are not one — the compose files are full of the
  // former and .env.example is full of the latter, and flagging those would
  // make the check something people switch off.
  [
    /\bmongodb(?:\+srv)?:\/\/(?!\$)[^\s:$]+:(?!\$|change-me|REPLACE_ME|password|example|<)[^\s@$]{8,}@/,
    'MongoDB URI with a literal password',
  ],
];

for (const file of walk(ROOT, (name) => !name.endsWith('.png') && !name.endsWith('.lock'))) {
  if (rel(file).startsWith('node_modules')) continue;
  checks += 1;
  let content;
  try {
    content = fs.readFileSync(file, 'utf8');
  } catch {
    continue;
  }
  for (const [pattern, label] of SECRET_PATTERNS) {
    if (pattern.test(content)) {
      errors.push(`${rel(file)}: looks like it contains a ${label}`);
    }
  }
}

// ── Report ───────────────────────────────────────────────────────────────────

process.stdout.write('\n');

if (warnings.length > 0) {
  process.stdout.write(`  ${warnings.length} warning(s):\n`);
  for (const warning of warnings) process.stdout.write(`    ! ${warning}\n`);
  process.stdout.write('\n');
}

if (errors.length > 0) {
  process.stderr.write(`  ✗ ${errors.length} error(s):\n`);
  for (const error of errors) process.stderr.write(`    ✗ ${error}\n`);
  process.stderr.write('\n');
  process.exit(1);
}

process.stdout.write(
  `  ✓ ${checks} checks passed — ${workflows.length} workflows, ` +
    `${composeFiles.length} compose stacks, ${yamlFiles.length} YAML files\n\n`,
);
