// Sign-in failures and bad tokens, from a pod, straight at server pods.
//
//   node -e "$(cat probe.js)" <mode> <n> <host:port>...
//
// password      wrong passwords for one account, kw3-$RUN@lab.test
// password-xff  wrong passwords for a different account each time, each
//               "through a proxy" for a different client (X-Forwarded-For)
// bearer        a token the server never issued
//
// Targets take turns, PACE_MS apart (the server also limits unauthenticated
// requests to 100 a minute per address). Prints each run of identical answers.
const [mode, n, ...targets] = process.argv.slice(1);
const http = require("http");
function once(target, i) {
  const [host, port] = target.split(":");
  return new Promise((resolve) => {
    const opts = { host, port: +port, timeout: 15000, headers: {} };
    let body = null;
    if (mode === "bearer") Object.assign(opts, { method: "GET", path: "/jmap/session", headers: { authorization: "Bearer not-a-token-" + i } });
    else {
      const run = process.env.RUN || "0";
      const account = mode === "password-xff" ? `kw3-${run}-${i}@lab.test` : `kw3-${run}@lab.test`;
      body = JSON.stringify({ type: "authCode", accountName: account, accountSecret: "wrong-" + i, clientId: "inbuxa-admin",
        redirectUri: "https://admin.lab.test/oauth/callback", codeChallenge: "x".repeat(43), codeChallengeMethod: "S256", state: "s" });
      opts.method = "POST";
      opts.path = "/api/auth";
      opts.headers = { "content-type": "application/json", "content-length": Buffer.byteLength(body) };
      if (mode === "password-xff") opts.headers["x-forwarded-for"] = `198.51.100.${(i % 250) + 1}`;
    }
    const req = http.request(opts, (res) => {
      let d = "";
      res.on("data", (c) => (d += c));
      res.on("end", () => resolve(res.statusCode + " " + d.slice(0, 40).replace(/\s+/g, " ")));
    });
    req.on("timeout", () => { req.destroy(); resolve("timeout"); });
    req.on("error", (e) => resolve("error " + e.code));
    if (body) req.write(body);
    req.end();
  });
}
(async () => {
  let last = null, from = 0;
  for (let i = 0; i < +n; i++) {
    if (i) await new Promise((r) => setTimeout(r, +(process.env.PACE_MS || 0)));
    const r = await once(targets[i % targets.length], i);
    if (r !== last) { if (last !== null) console.log(`#${from}-#${i - 1}: ${last}`); last = r; from = i; }
  }
  console.log(`#${from}-#${+n - 1}: ${last}`);
})();
