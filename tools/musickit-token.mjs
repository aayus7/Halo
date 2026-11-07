// Signs an Apple Music developer token (ES256 JWT) from your MusicKit .p8 key.
// Usage: node tools/musickit-token.mjs AuthKey_XXXX.p8 KEY_ID TEAM_ID [days=180]
import { readFileSync } from "node:fs";
import { createPrivateKey, sign } from "node:crypto";

const [keyPath, keyId, teamId, daysArg] = process.argv.slice(2);
if (!keyPath || !keyId || !teamId) {
  console.error("Usage: node tools/musickit-token.mjs AuthKey_XXXX.p8 KEY_ID TEAM_ID [days]");
  process.exit(1);
}
const days = Math.min(Number(daysArg || 180), 180);
const now = Math.floor(Date.now() / 1000);
const b64url = (obj) => Buffer.from(JSON.stringify(obj)).toString("base64url");
const header = b64url({ alg: "ES256", kid: keyId });
const payload = b64url({ iss: teamId, iat: now, exp: now + days * 86400 });
const key = createPrivateKey(readFileSync(keyPath));
const signature = sign("sha256", Buffer.from(`${header}.${payload}`), { key, dsaEncoding: "ieee-p1363" }).toString("base64url");
console.log(`${header}.${payload}.${signature}`);
