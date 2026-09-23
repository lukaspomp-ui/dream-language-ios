import {readFile, writeFile, mkdir, copyFile} from 'node:fs/promises';
import {resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';

// Run: node /path/to/dream-language-ios/web-companion/apply.mjs /path/to/Dream-Language
// This changes only the three companion files and the native-branch watchdog.
const target = process.argv[2];
if (!target) throw new Error('Pass the local Dream-Language web repository directory.');
const root = resolve(target);
const here = dirname(fileURLToPath(import.meta.url));
const authPath = resolve(root, 'src/pages/Auth.tsx');
const auth = await readFile(authPath, 'utf8');
const native = await readFile(resolve(root, 'src/lib/nativeAuth.ts'), 'utf8');
if (!native.includes('oauth-result') || !native.includes('oauth-signin')) {
  throw new Error('This is not the inspected Lovable native auth contract. Review before applying.');
}
const marker = 'if (hasNativeOAuth()) {';
if (auth.split(marker).length !== 2 || !auth.includes('clearTimeout(watchdog)')) {
  throw new Error('Auth.tsx changed: review the native branch and watchdog before applying.');
}
const addition = marker + '\n        // Native sign-in owns its 180-second timeout; do not fire the web redirect watchdog.\n        clearTimeout(watchdog);';
const updated = auth.includes('Native sign-in owns its 180-second timeout') ? auth : auth.replace(marker, addition);
// Preflight all sources before writing any destination.
const files = ['public/auth/native-callback.html', 'public/auth/native-callback.js', 'src/lib/nativeAuth.ts'];
for (const file of files) await readFile(resolve(here, file));
for (const file of files) {
  const destination = resolve(root, file);
  await mkdir(dirname(destination), {recursive: true});
  await copyFile(resolve(here, file), destination);
}
await writeFile(authPath, updated);
console.log('Applied OAuth relay, single-flight native bridge, and native watchdog fix. Review git diff, run the web checks, then publish.');
