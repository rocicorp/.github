import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import {delimiter, dirname, join} from 'node:path';
import {afterEach, test} from 'node:test';
import {fileURLToPath} from 'node:url';

const scriptPath = fileURLToPath(
  new URL('./verify-signed-commit-authors.mjs', import.meta.url),
);
const baseSha = '1111111111111111111111111111111111111111';
const firstCommit = '2222222222222222222222222222222222222222';
const secondCommit = '3333333333333333333333333333333333333333';
const headSha = secondCommit;
const activeAllowedSigners =
  'alice@example.com namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey\n';
const tempDirs = [];

afterEach(() => {
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, {force: true, recursive: true});
  }
});

test('accepts pull request commits signed by allowed SSH keys', () => {
  const result = runVerifier();

  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.match(
    result.stdout,
    /Checking signatures against 1 allowed SSH key entry\./,
  );
  assert.match(
    result.stdout,
    /222222222222: allowed SSH signature for alice@example\.com using SHA256:alice/,
  );
  assert.match(
    result.stdout,
    /333333333333: allowed SSH signature for alice@example\.com using SHA256:alice/,
  );
  assert.match(
    result.stdout,
    /::notice::All 2 PR commit\(s\) are signed by allowed SSH keys\./,
  );

  const calls = readToolCalls(result.dir);
  assert.ok(
    calls.some(
      call =>
        call.command === 'git' &&
        call.args.includes('fetch') &&
        call.args.includes('--depth=3') &&
        call.args.includes('+refs/pull/42/head:refs/remotes/pull/42/head'),
    ),
    'expected git fetch of the pull request head',
  );
  assert.ok(
    calls.some(
      call =>
        call.command === 'git' &&
        call.args.includes(
          `gpg.ssh.allowedSignersFile=${result.allowedSignersPath}`,
        ),
    ),
    'expected git signature checks to use the action-local allowed signers file',
  );
});

test('rejects a commit whose signature is not made by an allowed key', () => {
  const result = runVerifier({
    env: {
      FAKE_GIT_DENY_COMMIT: secondCommit,
    },
  });

  assert.equal(result.status, 1);
  assert.match(
    result.stdout,
    /::error::Signed commit author check failed for 1\/2 commit\(s\):%0A- 333333333333: signature is not made by an allowed SSH signing key: signature key is not allowed - reject me/,
  );
});

test('rejects an allowed signers file with no active keys', () => {
  const result = runVerifier({
    allowedSigners: '# no active keys yet\n',
  });

  assert.equal(result.status, 1);
  assert.match(result.stdout, /has no active signing keys/);
});

function runVerifier({allowedSigners = activeAllowedSigners, env = {}} = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'verify-signed-commit-authors-test-'));
  tempDirs.push(dir);

  const binDir = join(dir, 'bin');
  const workspace = join(dir, 'workspace');
  const actionPath = join(
    dir,
    'action-repo',
    '.github',
    'actions',
    'verify-signed-commit-authors',
  );
  const allowedSignersPath = join(
    dir,
    'action-repo',
    '.github',
    'signing',
    'allowed_signers',
  );
  mkdirSync(binDir, {recursive: true});
  mkdirSync(workspace, {recursive: true});
  mkdirSync(actionPath, {recursive: true});
  mkdirSync(dirname(allowedSignersPath), {recursive: true});
  writeFileSync(allowedSignersPath, allowedSigners);

  const eventPath = join(dir, 'event.json');
  writeFileSync(
    eventPath,
    JSON.stringify({
      pull_request: {
        base: {sha: baseSha},
        commits: 2,
        head: {sha: headSha},
        number: 42,
      },
    }),
  );
  writeToolStubs(binDir, dir);

  const result = spawnSync(process.execPath, [scriptPath], {
    encoding: 'utf8',
    env: {
      GITHUB_EVENT_PATH: eventPath,
      GITHUB_TOKEN: 'github-token',
      GITHUB_WORKSPACE: workspace,
      PATH: `${binDir}${delimiter}${process.env.PATH ?? ''}`,
      SIGNED_COMMIT_ACTION_PATH: actionPath,
      ...env,
    },
  });

  return {
    ...result,
    allowedSignersPath,
    dir,
  };
}

function writeToolStubs(binDir, dir) {
  writeExecutable(
    join(binDir, 'git'),
    `#!/usr/bin/env node
import {appendFileSync} from 'node:fs';

const allArgs = process.argv.slice(2);
appendFileSync(
  ${JSON.stringify(join(dir, 'tool-calls.jsonl'))},
  JSON.stringify({command: 'git', args: allArgs}) + '\\n',
);

const args = stripConfigArgs(allArgs);
const command = args[0];

if (command === 'fetch') {
  process.exit(0);
}

if (command === 'cat-file' && args[1] === '-e') {
  process.exit(0);
}

if (command === 'rev-list') {
  process.stdout.write(${JSON.stringify(`${firstCommit}\n${secondCommit}\n`)});
  process.exit(0);
}

if (command === 'verify-commit') {
  if (args[1] === process.env.FAKE_GIT_DENY_COMMIT) {
    process.stderr.write('signature key is not allowed\\n');
    process.exit(1);
  }
  process.exit(0);
}

if (command === 'show' && args.includes('--format=%s')) {
  const commit = args[args.length - 1];
  process.stdout.write(commit === ${JSON.stringify(secondCommit)} ? 'reject me\\n' : 'accept me\\n');
  process.exit(0);
}

if (command === 'show' && args.includes('--format=%GS%x00%GK%x00%GT')) {
  process.stdout.write('alice@example.com\\0SHA256:alice\\0fully');
  process.exit(0);
}

process.stderr.write('unexpected git args: ' + allArgs.join(' '));
process.exit(1);

function stripConfigArgs(args) {
  const stripped = [...args];
  while (stripped[0] === '-c') {
    stripped.splice(0, 2);
  }
  return stripped;
}
`,
  );
}

function writeExecutable(path, content) {
  writeFileSync(path, content, {mode: 0o755});
}

function readToolCalls(dir) {
  return readFileSync(join(dir, 'tool-calls.jsonl'), 'utf8')
    .trim()
    .split('\n')
    .map(line => JSON.parse(line));
}
