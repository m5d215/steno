// steno-mobile の POST /ingest を受ける最小サーバ(依存ゼロ・Node 標準のみ)。
// pipe(iPhone → 受け口)を実機で検証するためのリファレンス実装。本番の Slack 注入サーバは
// この contract(下記)を満たせば差し替え可能。
//
//   実行:  node example-server/ingest.mjs
//   環境:  PORT   待受ポート(既定 8787)
//          TOKEN  設定すると Authorization: Bearer <TOKEN> を必須にする(未設定なら認証なし)
//          LOG    受信レコードを追記する jsonl パス(未設定なら書かない。標準出力には常に出す)
//
// contract:
//   GET  /         → 200 "ok"(ヘルスチェック)
//   POST /ingest   body = WireRecord の JSON 配列
//                   header Authorization: Bearer <token>(TOKEN 設定時)
//                   → 200 {"acked": <受理した最大 seq>}
//   WireRecord = { deviceId, ts, epoch, seq, source, text }
//   dedup は (deviceId, seq)。seq はクライアント側でグローバル単調増加。
//   ack した seq までクライアントは送信済みとみなし再送しない(at-least-once)。

import { createServer } from "node:http";
import { appendFile } from "node:fs/promises";

const PORT = Number(process.env.PORT ?? 8787);
const TOKEN = process.env.TOKEN ?? "";
const LOG = process.env.LOG ?? "";

// deviceId → これまでに受理した最大 seq。再起動で消える(PoC 用途では十分)。
const lastSeq = new Map();

const server = createServer((req, res) => {
    if (req.method === "GET" && req.url === "/") {
        res.writeHead(200, { "content-type": "text/plain" });
        res.end("ok");
        return;
    }

    if (req.method !== "POST" || req.url !== "/ingest") {
        res.writeHead(404).end();
        return;
    }

    if (TOKEN && req.headers.authorization !== `Bearer ${TOKEN}`) {
        res.writeHead(401, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: "unauthorized" }));
        return;
    }

    let body = "";
    req.on("data", (chunk) => {
        body += chunk;
        if (body.length > 4_000_000) req.destroy(); // 暴走ガード
    });
    req.on("end", () => {
        void handle(body, res);
    });
});

async function handle(body, res) {
    let records;
    try {
        records = JSON.parse(body);
        if (!Array.isArray(records)) throw new Error("body must be a JSON array");
    } catch (e) {
        res.writeHead(400, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: String(e.message ?? e) }));
        return;
    }

    let ackedMax = 0;
    const lines = [];

    for (const r of records) {
        if (
            typeof r?.deviceId !== "string" ||
            typeof r?.seq !== "number" ||
            typeof r?.text !== "string"
        ) {
            continue; // 壊れたレコードは黙って捨てる
        }
        ackedMax = Math.max(ackedMax, r.seq);

        const seen = lastSeq.get(r.deviceId) ?? 0;
        if (r.seq <= seen) continue; // dedup: 既に受理済み
        lastSeq.set(r.deviceId, r.seq);

        const t = typeof r.ts === "string" ? r.ts.slice(11, 19) : "--:--:--";
        console.log(`[${t}] ${r.deviceId} #${r.seq} ${r.source ?? "?"}: ${r.text}`);
        if (LOG) lines.push(JSON.stringify(r));
    }

    if (LOG && lines.length) {
        try {
            await appendFile(LOG, lines.join("\n") + "\n");
        } catch (e) {
            console.error(`append failed: ${e.message ?? e}`);
        }
    }

    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ acked: ackedMax }));
}

server.listen(PORT, () => {
    console.log(`ingest server on :${PORT}` + (TOKEN ? " (bearer required)" : " (no auth)"));
});
