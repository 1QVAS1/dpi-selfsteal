// Мини-сервер для локального просмотра сайта без Docker (с той же CSP, что и в nginx).
// Запуск: node tools/dev-server.mjs [порт]   →   http://localhost:8000
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { extname, join, normalize, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'site');
const port = Number(process.argv[2]) || 8000;
const TYPES = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8', '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.txt': 'text/plain; charset=utf-8',
};
const CSP = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'none'; frame-ancestors 'none'";

createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  let p = normalize(decodeURIComponent(url.pathname)).replace(/^([/\\])+/, '');
  if (p.includes('..')) { res.writeHead(400).end(); return; }
  let file = join(root, p || 'index.html');
  try {
    if ((await stat(file)).isDirectory()) file = join(file, 'index.html');
    const body = await readFile(file);
    res.writeHead(200, { 'Content-Type': TYPES[extname(file)] || 'application/octet-stream', 'Content-Security-Policy': CSP, 'Cache-Control': 'no-cache' });
    res.end(body);
  } catch {
    const body = await readFile(join(root, '404.html'));
    res.writeHead(404, { 'Content-Type': TYPES['.html'], 'Content-Security-Policy': CSP });
    res.end(body);
  }
}).listen(port, () => console.log(`http://localhost:${port}`));
