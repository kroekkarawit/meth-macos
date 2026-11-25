// Meth distribution Worker.
//
// Stable public URLs in front of GitHub Releases, so the app's update feed and the
// download link never change even if the files later move (e.g. to R2):
//   /              landing page
//   /download      302 → latest Meth-<version>.dmg
//   /download/zip  302 → latest Sparkle archive
//   /appcast.xml   Sparkle feed (cached copy of the latest release's appcast.xml)
//   /latest.json   {"version","build","dmg","zip","notes"} for scripts
//   /icon.png      app icon
// No cookies, no analytics, no state.

const FEED_TTL = 300; // seconds

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
    }
    const repo = env.GITHUB_REPO;
    try {
      switch (url.pathname) {
        case "/":
          return page(await latest(repo, ctx));
        case "/appcast.xml": {
          const feed = await appcast(repo, ctx);
          if (!feed) return text("No release has been published yet.", 404);
          return new Response(feed, { headers: { "Content-Type": "application/xml; charset=utf-8", "Cache-Control": `public, max-age=${FEED_TTL}` } });
        }
        case "/download":
        case "/download/dmg":
        case "/download/zip": {
          const l = await latest(repo, ctx);
          if (!l) return text("No release has been published yet. Check back soon.", 404);
          return Response.redirect(url.pathname.endsWith("zip") ? l.zip : l.dmg, 302);
        }
        case "/latest.json": {
          const l = await latest(repo, ctx);
          if (!l) return json({ error: "no_release" }, 404);
          return json(l);
        }
        case "/icon.png":
          return proxy(`https://raw.githubusercontent.com/${repo}/main/docs/assets/logo.png`, "image/png", ctx);
        case "/robots.txt":
          return text("User-agent: *\nAllow: /\n");
        default:
          return text("Not found", 404);
      }
    } catch (e) {
      return text("Upstream error. Please try again shortly.", 502);
    }
  },
};

/** Cached fetch of the newest release's appcast (null if none yet). */
async function appcast(repo, ctx) {
  const src = `https://github.com/${repo}/releases/latest/download/appcast.xml`;
  const cache = caches.default;
  const key = new Request(`https://cache.meth.internal/appcast/${repo}`);
  const hit = await cache.match(key);
  if (hit) return hit.text();
  const res = await fetch(src, { redirect: "follow", cf: { cacheTtl: FEED_TTL } });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`appcast ${res.status}`);
  const body = await res.text();
  if (!body.includes("<rss")) throw new Error("appcast is not RSS");
  ctx.waitUntil(cache.put(key, new Response(body, { headers: { "Cache-Control": `public, max-age=${FEED_TTL}` } })));
  return body;
}

/** Highest-build item in the appcast. */
async function latest(repo, ctx) {
  const feed = await appcast(repo, ctx);
  if (!feed) return null;
  let best = null;
  for (const item of feed.split("<item>").slice(1)) {
    const build = Number(tag(item, "sparkle:version"));
    const version = tag(item, "sparkle:shortVersionString");
    const zip = (item.match(/<enclosure[^>]*url="([^"]+)"/) || [])[1];
    if (!version || !zip || !Number.isFinite(build)) continue;
    if (!best || build > best.build) {
      best = {
        version,
        build,
        zip,
        dmg: `https://github.com/${repo}/releases/download/v${version}/Meth-${version}.dmg`,
        notes: `https://github.com/${repo}/releases/tag/v${version}`,
        minimumSystemVersion: tag(item, "sparkle:minimumSystemVersion") || "14.0",
      };
    }
  }
  return best;
}

function tag(xml, name) {
  const m = xml.match(new RegExp(`<${name}>([^<]*)</${name}>`));
  return m ? m[1].trim() : null;
}

async function proxy(src, type, ctx) {
  const res = await fetch(src, { cf: { cacheTtl: 3600, cacheEverything: true } });
  if (!res.ok) return text("Not found", 404);
  return new Response(res.body, { headers: { "Content-Type": type, "Cache-Control": "public, max-age=3600" } });
}

function text(body, status = 200) {
  return new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8" } });
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj, null, 2), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": `public, max-age=${FEED_TTL}`, "Access-Control-Allow-Origin": "*" },
  });
}

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

function page(l) {
  const repoURL = "https://github.com/kroekkarawit/meth-macos";
  const cta = l
    ? `<a class="btn" href="/download">Download Meth ${esc(l.version)}</a>
       <p class="meta">Free · macOS 14 Sonoma or later · Apple silicon &amp; Intel · <a href="${esc(l.notes)}">Release notes</a></p>`
    : `<span class="btn disabled">Coming soon</span>
       <p class="meta">The first release is on its way. <a href="${repoURL}">Watch it on GitHub</a>.</p>`;
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Meth — Keep your Mac high. Never asleep.</title>
<meta name="description" content="A tiny native macOS menu bar app and CLI that keeps your Mac awake. For humans and AI agents.">
<link rel="icon" href="/icon.png">
<style>
  :root { --bg:#fbfbfd; --fg:#1d1d1f; --muted:#6e6e73; --card:#fff; --line:#d2d2d7; --accent:#0071e3; --code:#f5f5f7; }
  @media (prefers-color-scheme: dark) { :root { --bg:#000; --fg:#f5f5f7; --muted:#a1a1a6; --card:#1c1c1e; --line:#38383a; --accent:#2997ff; --code:#1c1c1e; } }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--fg); font:17px/1.47 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; -webkit-font-smoothing:antialiased; }
  main { max-width: 980px; margin: 0 auto; padding: 72px 22px 48px; }
  .hero { text-align:center; }
  .hero img { width:128px; height:128px; filter: drop-shadow(0 10px 24px rgba(0,0,0,.18)); }
  h1 { font-size: clamp(40px, 7vw, 64px); line-height:1.05; letter-spacing:-.02em; margin: 20px 0 8px; font-weight:700; }
  .tag { font-size: clamp(21px, 3vw, 28px); color: var(--muted); margin:0 0 32px; font-weight:500; }
  .btn { display:inline-block; background:var(--accent); color:#fff; text-decoration:none; padding:12px 26px; border-radius:980px; font-size:17px; font-weight:500; }
  .btn:hover { filter: brightness(1.08); }
  .btn.disabled { background: var(--line); color: var(--muted); }
  .meta { color:var(--muted); font-size:14px; margin-top:14px; }
  a { color: var(--accent); }
  .grid { display:grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap:16px; margin: 64px 0; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:18px; padding:22px; }
  .card h3 { margin:0 0 6px; font-size:19px; }
  .card p { margin:0; color:var(--muted); font-size:15px; }
  h2 { font-size: 32px; letter-spacing:-.01em; margin: 0 0 16px; text-align:center; }
  pre { background:var(--code); border:1px solid var(--line); border-radius:14px; padding:18px 20px; overflow:auto; font:14px/1.6 ui-monospace, "SF Mono", Menlo, monospace; }
  .note { color:var(--muted); font-size:13px; text-align:center; margin-top:56px; }
</style>
</head>
<body>
<main>
  <section class="hero">
    <img src="/icon.png" alt="Meth app icon" width="128" height="128">
    <h1>Meth</h1>
    <p class="tag">Keep your Mac high. Never asleep.</p>
    ${cta}
  </section>

  <section class="grid">
    <div class="card"><h3>Bump</h3><p>Keeps the Mac awake. The display can still sleep.</p></div>
    <div class="card"><h3>High</h3><p>Keeps the Mac and the display awake.</p></div>
    <div class="card"><h3>Overdose</h3><p>Even with the lid closed. Time-limited, and always restored.</p></div>
    <div class="card"><h3>Sober</h3><p>Back to normal sleep in one click.</p></div>
  </section>

  <h2>Made for scripts and AI agents</h2>
  <pre>meth high --for 2h            # keep awake for two hours
meth bump --while-pid $$       # until this shell exits
meth high --until 18:00
meth extend 30m
meth status --json             # stable schema, documented exit codes
meth sober</pre>

  <p class="note">Open source (MIT) on <a href="${repoURL}">GitHub</a>. Signed with Developer ID and notarized by Apple.<br>
  Parody notice: the names joke about macOS power management. Meth has nothing to do with drugs.</p>
</main>
</body>
</html>`;
  return new Response(html, { headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "public, max-age=300", "X-Content-Type-Options": "nosniff", "Content-Security-Policy": "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'" } });
}
