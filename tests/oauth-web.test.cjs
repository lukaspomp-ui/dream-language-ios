const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const {stripTypeScriptTypes} = require('node:module');
const base = path.resolve(__dirname, '..');
const relay = fs.readFileSync(path.join(base, 'web-companion/public/auth/native-callback.js'), 'utf8');
const state = 'a'.repeat(64);

function runRelay(parameters, options = {}) {
  const elements = {status: {}, return: {hidden: true}};
  const actions = [];
  const origin = options.origin || 'https://dream-language.lovable.app';
  const location = {
    origin, href: origin + '/auth/native-callback.html' + parameters,
    replace: url => actions.push(['redirect', url])
  };
  const window = {};
  window.top = options.iframe ? {} : window;
  vm.runInNewContext(relay, {
    URL, URLSearchParams, window, location,
    document: {getElementById: id => elements[id]},
    history: {replaceState: (...args) => actions.push(['scrub', args[2]])}
  });
  const target = actions.find(a => a[0] === 'redirect')?.[1];
  return {elements, actions, target, result: target ? new URLSearchParams(new URL(target).hash.slice(1)) : null};
}

test('fragment tokens survive encoding and the browser URL is scrubbed first', () => {
  const tokens = new URLSearchParams({state, access_token: "a'\\\"+&=#\n", refresh_token: 'b/+?&='});
  const r = runRelay(`?native_state=${state}#${tokens}`);
  assert.equal(r.result.get('access_token'), "a'\\\"+&=#\n");
  assert.equal(r.result.get('refresh_token'), 'b/+?&=');
  assert.equal(r.actions[0][0], 'scrub');
  assert.ok(r.target.startsWith('app.lovable.dream-language://oauth/callback#'));
});

test('query token response also works', () => {
  const q = new URLSearchParams({native_state: state, state, access_token: 'a', refresh_token: 'b'});
  assert.equal(runRelay('?' + q).result.get('access_token'), 'a');
});

for (const [name, fragment] of [
  ['missing state', 'access_token=a&refresh_token=b'],
  ['wrong state', 'state=wrong&access_token=a&refresh_token=b'],
  ['duplicate state', `state=${state}&state=${state}&access_token=a&refresh_token=b`],
  ['duplicate token', `state=${state}&access_token=a&access_token=b&refresh_token=c`],
  ['partial session', `state=${state}&access_token=a`],
  ['provider error', `state=${state}&error=access_denied&access_token=a&refresh_token=b`]
]) {
  test(name + ' never passes tokens', () => {
    const r = runRelay(`?native_state=${state}#${fragment}`);
    assert.equal(r.result.get('error'), 'oauth_failed');
    assert.equal(r.result.has('access_token'), false);
    assert.equal(r.result.get('state'), state);
  });
}
test('state duplicated across query and fragment is rejected', () => {
  const r = runRelay(`?native_state=${state}&state=${state}#state=${state}&access_token=a&refresh_token=b`);
  assert.equal(r.result.get('error'), 'oauth_failed');
});
test('untrusted origins, iframes and unsolicited links do not launch the app', () => {
  const valid = `?native_state=${state}#state=${state}&access_token=a&refresh_token=b`;
  for (const r of [runRelay(valid, {origin: 'https://evil.example'}), runRelay(valid, {iframe: true}),
    runRelay('#state=x&access_token=a&refresh_token=b'), runRelay(`?native_state=${state}&native_state=${state}`)]) {
    assert.equal(r.target, undefined);
  }
});
test('redirect parameters cannot change the app callback destination', () => {
  const r = runRelay(`?native_state=${state}&redirect_uri=https://evil.example#state=${state}&access_token=a&refresh_token=b`);
  assert.equal(new URL(r.target).host, 'oauth');
  assert.equal(new URL(r.target).protocol, 'app.lovable.dream-language:');
});

function bridge() {
  const listeners = new Set();
  const timers = new Map();
  const messages = [];
  let nextTimer = 0;
  const source = stripTypeScriptTypes(fs.readFileSync(path.join(base, 'web-companion/src/lib/nativeAuth.ts'), 'utf8'))
    .replace(/export /g, '');
  const context = vm.createContext({
    window: {webkit: {messageHandlers: {'oauth-signin': {postMessage: m => messages.push(m)}}},
      addEventListener: (_, f) => listeners.add(f), removeEventListener: (_, f) => listeners.delete(f)},
    navigator: {userAgent: ''},
    setTimeout: f => {timers.set(++nextTimer, f); return nextTimer;},
    clearTimeout: id => timers.delete(id)
  });
  vm.runInContext(source + '\nglobalThis.signIn = nativeOAuthSignIn;', context);
  return {context, listeners, timers, messages, signIn: context.signIn,
    emit: detail => [...listeners].forEach(f => f({detail}))};
}
test('web bridge resolves, removes listeners, ignores stale results and allows retry', async () => {
  const b = bridge();
  const p = b.signIn('google', 'https://dream-language.lovable.app/auth/callback');
  b.emit({ok: true, access_token: 'a', refresh_token: 'b'});
  assert.equal((await p).access_token, 'a');
  assert.equal(b.listeners.size, 0);
  assert.equal(b.timers.size, 0);
  b.emit({ok: false, error: 'late'});
  const next = b.signIn('apple', 'https://dream-language.lovable.app/auth/callback');
  b.emit({ok: false, error: 'Sign-in cancelled.'});
  await assert.rejects(next, /cancelled/);
});
test('concurrent web requests are rejected before sending a second native message', async () => {
  const b = bridge();
  const first = b.signIn('google', 'callback');
  await assert.rejects(b.signIn('apple', 'callback'), /already in progress/);
  assert.equal(b.messages.length, 1);
  b.emit({ok: false, error: 'cancelled'});
  await assert.rejects(first, /cancelled/);
});
test('timeout and thrown postMessage release the web bridge', async () => {
  const b = bridge();
  const first = b.signIn('google', 'callback');
  [...b.timers.values()][0]();
  await assert.rejects(first, /timed out/);
  assert.equal(b.listeners.size, 0);
  vm.runInContext("window.webkit.messageHandlers['oauth-signin'].postMessage = () => {throw new Error('bridge broke');};", b.context);
  await assert.rejects(b.signIn('google', 'callback'), /bridge broke/);
  assert.equal(b.listeners.size, 0);
  assert.equal(b.timers.size, 0);
});
