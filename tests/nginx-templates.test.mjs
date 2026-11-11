// Рендерит шаблоны nginx так же, как entrypoint образа nginx (envsubst только по заданным
// переменным), и проверяет результат: нет неподставленных ${VAR}, скобки сбалансированы,
// в режиме REALITY nginx не занимает 443 и есть нужные location.
// Запуск: node tests/nginx-templates.test.mjs
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const read = (p) => readFileSync(new URL(`../${p}`, import.meta.url), 'utf8');
const envsubst = (tpl, env) => tpl.replace(/\$\{([A-Z_][A-Z0-9_]*)\}/g, (m, k) => (k in env ? env[k] : m));
const stripComments = (s) => s.split('\n').map((l) => l.replace(/(^|\s)#.*$/, '')).join('\n');

function check(name, conf, expectVars) {
  const body = stripComments(conf);
  for (const v of expectVars) assert.ok(!body.includes('${' + v + '}'), `${name}: не подставлено \${${v}}`);
  let depth = 0;
  for (const ch of body) { if (ch === '{') depth++; if (ch === '}') depth--; assert.ok(depth >= 0, `${name}: лишняя }`); }
  assert.equal(depth, 0, `${name}: несбалансированные скобки`);
  return body;
}

let passed = 0;
const t = (name, fn) => { fn(); passed++; console.log(`  ok  ${name}`); };

const env = {
  DOMAIN: 'example.org',
  REALITY_TARGET_LISTEN: '127.0.0.1:9443',
  XHTTP_ENABLED: 'on', XHTTP_PATH: '/media/abc123/', XHTTP_UPSTREAM: '127.0.0.1:2023',
  SUB_ENABLED: 'on', SUB_PATH: '/s9x/', SUB_JSON_PATH: '/s9xj/', SUB_UPSTREAM: '127.0.0.1:2096',
};

console.log('nginx templates');
t('обычный режим: подстановка DOMAIN, 80 и 443', () => {
  const c = check('prod', envsubst(read('nginx/templates/default.conf.template'), { DOMAIN: env.DOMAIN }), ['DOMAIN']);
  assert.match(c, /listen 443 ssl;/);
  assert.match(c, /\/etc\/letsencrypt\/live\/example\.org\/fullchain\.pem/);
});

t('режим REALITY: все переменные подставлены', () => {
  check('reality', envsubst(read('nginx/reality-templates/default.conf.template'), env), Object.keys(env));
});

t('режим REALITY: 443 не занят, target на loopback с HTTP/2', () => {
  const c = check('reality', envsubst(read('nginx/reality-templates/default.conf.template'), env), []);
  assert.ok(!/listen\s+(\S+:)?443\b/.test(c), 'nginx не должен слушать 443');
  assert.match(c, /listen 127\.0\.0\.1:9443 ssl;/);
  assert.match(c, /http2 on;/);
  assert.match(c, /listen 80;/);
});

t('режим REALITY: location XHTTP (grpc_pass) и подписки (proxy_pass) как в инструкции', () => {
  const c = check('reality', envsubst(read('nginx/reality-templates/default.conf.template'), env), []);
  // тело location — до закрывающей скобки на уровне отступа location
  const block = (loc) => {
    const i = c.indexOf(`location ${loc} {`);
    assert.ok(i >= 0, `нет location ${loc}`);
    return c.slice(i, c.indexOf('\n    }', i));
  };
  const x = block('/media/abc123/');
  for (const d of ['grpc_pass grpc://127.0.0.1:2023;', 'client_max_body_size 0;', 'client_body_timeout 1h;', 'grpc_read_timeout 1h;', 'grpc_send_timeout 1h;', 'grpc_buffer_size 16k;', 'grpc_socket_keepalive on;', 'grpc_set_header Host $host;', 'grpc_set_header X-Real-IP $remote_addr;']) {
    assert.ok(x.includes(d), `XHTTP: нет директивы ${d}`);
  }
  for (const loc of ['/s9x/', '/s9xj/']) {
    const b = block(loc);
    assert.ok(b.includes('proxy_pass http://127.0.0.1:2096;') && b.includes('proxy_set_header Host $host;'), `подписка ${loc}`);
  }
  assert.match(c, /include \/etc\/nginx\/snippets\/site\.conf;/);
  // $host и $request_uri — переменные nginx, envsubst их не трогает
  assert.ok(c.includes('$request_uri') && c.includes('$host'));
});

t('compose-override: те же переменные, что в шаблоне', () => {
  const tpl = read('nginx/reality-templates/default.conf.template');
  const used = new Set([...stripComments(tpl).matchAll(/\$\{([A-Z_][A-Z0-9_]*)\}/g)].map((m) => m[1]));
  const compose = read('docker-compose.reality.yml') + read('docker-compose.yml');
  for (const v of used) assert.ok(compose.includes(`      ${v}: `), `переменная ${v} не передаётся в контейнер`);
});

console.log(`\n${passed} passed`);
