// Example Halo addon: searches the Internet Archive's free/public-domain audio.
// Deploy free on Cloudflare Workers (dash.cloudflare.com → Workers → Create → paste → Deploy),
// then paste https://<your-worker>.workers.dev/manifest.json into Halo › Addons.

const MANIFEST = {
  id: "halo.example.internetarchive",
  name: "Internet Archive",
  version: "1.0.0",
  description: "Free & public-domain recordings from archive.org",
  icon: "https://archive.org/images/glogo.png",
  resources: ["search", "stream"],
};

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "access-control-allow-origin": "*" },
  });

const PLAYABLE = /\.(mp3|m4a|flac|ogg)$/i;

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "");

    if (path === "" || path === "/manifest.json") return json(MANIFEST);

    if (path === "/search") {
      const q = (url.searchParams.get("q") || "").trim();
      if (!q) return json({ tracks: [] });
      const api = new URL("https://archive.org/advancedsearch.php");
      api.searchParams.set("q", `(${q}) AND mediatype:audio`);
      ["identifier", "title", "creator"].forEach((f) => api.searchParams.append("fl[]", f));
      api.searchParams.set("rows", "25");
      api.searchParams.set("output", "json");
      const res = await fetch(api);
      if (!res.ok) return json({ tracks: [] });
      const data = await res.json();
      const tracks = (data.response?.docs || []).map((d) => ({
        id: d.identifier,
        title: Array.isArray(d.title) ? d.title[0] : d.title || d.identifier,
        artist: Array.isArray(d.creator) ? d.creator[0] : d.creator || "Internet Archive",
        artworkURL: `https://archive.org/services/img/${d.identifier}`,
      }));
      return json({ tracks });
    }

    const m = path.match(/^\/stream\/(.+)$/);
    if (m) {
      const id = decodeURIComponent(m[1]);
      const res = await fetch(`https://archive.org/metadata/${encodeURIComponent(id)}`);
      if (!res.ok) return json({ error: "Not found" }, 404);
      const meta = await res.json();
      const files = (meta.files || []).filter((f) => PLAYABLE.test(f.name) && !/ogg$/i.test(f.name));
      const pick = files.find((f) => /mp3$/i.test(f.name)) || files[0];
      if (!pick) return json({ error: "No playable audio in this item" }, 404);
      return json({
        url: `https://archive.org/download/${encodeURIComponent(id)}/${pick.name.split("/").map(encodeURIComponent).join("/")}`,
        format: pick.name.split(".").pop().toLowerCase(),
      });
    }

    return json({ error: "Not found" }, 404);
  },
};
