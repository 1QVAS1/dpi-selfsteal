# CHOKEPOINT — информер о блокировках

## Оглавление

1. [О проекте](#1-о-проекте)
2. [Структура репозитория](#2-структура-репозитория)
3. [Требования](#3-требования)
4. [Быстрый старт](#4-быстрый-старт)
5. [Локальный запуск без домена](#5-локальный-запуск-без-домена)
6. [TLS-сертификаты и автопродление](#6-tls-сертификаты-и-автопродление)
   - [Как это устроено](#как-это-устроено)
   - [Включить, проверить, отключить](#включить-проверить-отключить)
   - [Ручной запуск](#ручной-запуск)
   - [Лог и срок действия](#лог-и-срок-действия)
   - [Вариант с systemd timer вместо cron](#вариант-с-systemd-timer-вместо-cron)
7. [Обновление контента](#7-обновление-контента)
   - [Новости](#новости)
   - [Как применить изменения](#как-применить-изменения)
   - [Тесты](#тесты)
8. [Режим «сайт-заглушка для REALITY» (3x-ui)](#8-режим-сайт-заглушка-для-reality-3x-ui)
   - [Как это устроено](#как-это-устроено-1)
   - [Требования](#требования)
   - [Включение](#включение)
   - [Что ввести в 3x-ui](#что-ввести-в-3x-ui)
   - [Переменные в `.env`](#переменные-в-env)
   - [Порядок при переходе между режимами](#порядок-при-переходе-между-режимами)
   - [Проверка](#проверка)
   - [Особенности](#особенности)
9. [Пасхалка](#9-пасхалка)
10. [Частые проблемы](#10-частые-проблемы)

## 1. О проекте

**CHOKEPOINT** — статический лендинг на русском языке о том, как в России устроена фильтрация интернет-трафика. В нём разделы:

- что такое DPI и чем он отличается от блокировки по IP и DNS;
- что такое ТСПУ: правовая основа, кто управляет системой, где стоит оборудование;
- известное из открытых источников оборудование и ПО — российское и мировое для сравнения;
- хронология ключевых событий;
- новости за последние 6 месяцев на момент сборки;
- полный список источников.

> **Дисклеймер.** Информация носит ознакомительный характер и собрана из открытых источников. Сайт не содержит инструкций и рекомендаций по обходу блокировок. Факты, подтверждённые только публикациями в прессе, помечены «по данным СМИ».

Сайт — чистая статика: HTML, CSS и vanilla JS на ES-модулях, без сборщиков. Всё нужное лежит локально, во время работы страница не обращается к внешним доменам. В Docker сайт раздаёт nginx с HTTPS от Let's Encrypt.

Актуально на **10.11.2026**.

## 2. Структура репозитория

```text
.
├── site/                       # сайт (монтируется в nginx только для чтения)
│   ├── index.html              # главная страница, внутри разметка свитка-пасхалки
│   ├── 404.html                # страница 404 в стилистике сайта
│   ├── css/                    # fonts.css, main.css, scroll.css (свиток), 404.css
│   ├── js/                     # ES-модули: main, hero-canvas, reveal, news, scroll-modal, easter-egg-counter
│   ├── data/news.json          # новости — правятся без изменения вёрстки
│   ├── assets/                 # логотип и SVG-текстуры
│   └── fonts/                  # woff2 (Inter, JetBrains Mono, Yeseva One, Cormorant Garamond) + лицензии OFL
├── nginx/
│   ├── templates/              # боевой конфиг-шаблон (envsubst подставляет ${DOMAIN})
│   ├── local-templates/        # конфиг для локального режима https://localhost:8443
│   ├── reality-templates/      # конфиг режима «сайт-заглушка для REALITY» (раздел 8)
│   ├── conf.d/00-http.conf     # http-уровень: server_tokens, gzip, TLS-параметры, кэш
│   └── snippets/               # заголовки безопасности, раздача сайта, ACME и /healthz
├── scripts/
│   ├── init-letsencrypt.sh     # первичный выпуск сертификата (есть флаг --staging)
│   ├── renew-certs.sh          # продление и reload nginx (для cron)
│   ├── cron.sh                 # install / remove / status / run для расписания продления
│   ├── reality.sh              # enable / disable / status / panel для режима REALITY
│   ├── lib.sh                  # общие функции скриптов
│   └── selfsigned.py           # временный самоподписанный сертификат (запускается в контейнере certbot)
├── tests/
│   ├── easter-egg-counter.test.mjs  # тесты логики пасхалки (node, без зависимостей)
│   ├── scroll-text.test.mjs         # сверка текста свитка с эталоном
│   ├── nginx-templates.test.mjs     # рендер шаблонов nginx и проверка директив
│   ├── scripts.test.sh              # тесты cron.sh и renew-certs.sh на заглушках
│   └── fixtures/scroll-text.txt     # эталонный текст свитка
├── tools/
│   ├── build-scroll.mjs        # генерирует разметку свитка из эталонного текста
│   └── dev-server.mjs          # локальный просмотр без Docker (с той же CSP)
├── research/notes.md           # исследование: каждый факт с источником и датой
├── logs/                       # сюда пишется renew.log
├── docker-compose.yml          # боевой режим: web (nginx) + certbot (profile)
├── docker-compose.local.yml    # локальный режим с самоподписанным сертификатом
├── docker-compose.reality.yml  # надстройка для режима REALITY (подключает scripts/reality.sh)
└── .env.example                # DOMAIN и LETSENCRYPT_EMAIL
```

## 3. Требования

- Linux-сервер (VPS) с белым IP.
- **Docker** и **Docker Compose v2**, то есть команда `docker compose`, а не `docker-compose`. Для режима REALITY (раздел 8) нужна версия Compose не ниже 2.24.4.
- **Домен**, A-запись которого указывает на IP сервера. Если у сервера есть IPv6 и вы добавляете AAAA-запись, она должна вести на этот же сервер.
- Открытые входящие порты **80** и **443**. Порт 80 нужен Let's Encrypt для проверки домена.
- На хосте **`cron`** и **`flock`**. `flock` входит в пакет `util-linux` и в большинстве дистрибутивов уже установлен.

Проверка:

```bash
docker --version
docker compose version
command -v crontab flock
getent hosts example.org     # подставьте свой домен: должен вернуться IP сервера
```

## 4. Быстрый старт

```bash
git clone <URL-репозитория> chokepoint
cd chokepoint
chmod +x scripts/*.sh

cp .env.example .env
nano .env        # укажите DOMAIN и LETSENCRYPT_EMAIL
```

Пробный выпуск на тестовом сервере Let's Encrypt. Он не упирается в лимиты, но браузеры такому сертификату не доверяют:

```bash
./scripts/init-letsencrypt.sh --staging
```

Если всё прошло успешно, выпустите настоящий сертификат. Скрипт сам заменит тестовый:

```bash
./scripts/init-letsencrypt.sh
```

Запуск, или проверка, что всё запущено:

```bash
docker compose up -d
docker compose ps          # у web должен быть статус healthy
```

Включите автопродление (подробнее в разделе 6):

```bash
./scripts/cron.sh install
```

Сайт доступен по адресу `https://ваш-домен/`.

> **Почему сначала `init-letsencrypt.sh`, а потом `up`.** Конфиг nginx ссылается на файлы сертификата. Без них nginx не стартует. Скрипт создаёт временный сертификат, поднимает nginx, получает настоящий сертификат и перезагружает nginx. После этого `docker compose up -d` только убеждается, что контейнер работает. Скрипт идемпотентен, повторный запуск ничего не сломает.

## 5. Локальный запуск без домена

Локальный режим поднимает тот же nginx с теми же заголовками на `https://localhost:8443`. Самоподписанный сертификат создаётся автоматически. Порт `8080` редиректит на HTTPS.

```bash
docker compose -f docker-compose.local.yml up -d
docker compose -f docker-compose.local.yml ps
```

Проверка:

```bash
curl -kI https://localhost:8443/                    # 200, CSP, HSTS, Cache-Control
curl -kI https://localhost:8443/data/news.json      # 200, короткий кэш
curl -kI https://localhost:8443/no-such-page        # 404, своя страница
curl -I  http://localhost:8080/                     # 301 → https://localhost:8443/
```

Браузер предупредит о самоподписанном сертификате, это ожидаемо. Остановка:

```bash
docker compose -f docker-compose.local.yml down
```

Чтобы посмотреть сайт совсем без Docker, нужен Node.js:

```bash
node tools/dev-server.mjs 8000      # http://localhost:8000
```

## 6. TLS-сертификаты и автопродление

### Как это устроено

Сертификаты Let's Encrypt действуют 90 дней. Команда `certbot renew` сама решает, пора ли продлевать: по умолчанию за 30 дней до истечения срока. В остальное время она ничего не делает, поэтому запускать её часто безопасно. Let's Encrypt рекомендует запуск дважды в сутки.

Почему расписание на хосте, а не в контейнере:

- Если ставить certbot пакетом прямо на систему, он сам добавляет systemd-таймер или задачу cron. В официальном Docker-образе `certbot/certbot` планировщика нет. Поэтому сервис `certbot` здесь одноразовый: он стоит под `profiles: ["certbot"]`, не стартует при `docker compose up` и запускается только скриптами.
- Флаг `--deploy-hook` в certbot выполняется внутри контейнера certbot. Перезагрузить оттуда nginx нельзя, он живёт в другом контейнере. Поэтому reload делает `scripts/renew-certs.sh` после `renew`, и только если отпечаток SHA-256 файла `fullchain.pem` изменился.

`renew-certs.sh` работает так:

- путь к проекту вычисляет от своего расположения;
- задаёт полный `PATH`, поэтому работает из cron;
- через `flock` не даёт двум запускам пересечься;
- пишет лог с датами в `logs/renew.log`;
- при ошибке возвращает ненулевой код.

### Включить, проверить, отключить

```bash
./scripts/cron.sh install    # запись вида: 17 3,15 * * * '/путь/scripts/renew-certs.sh' >/dev/null 2>&1 # chokepoint-renew
./scripts/cron.sh status     # запись и последние строки лога
crontab -l                   # убедиться напрямую
./scripts/cron.sh remove     # отключить
```

`install` выбирает случайную минуту и не создаёт дублей: повторный вызов только показывает существующую запись.

### Ручной запуск

```bash
./scripts/cron.sh run                  # то же, что делает cron
./scripts/renew-certs.sh --dry-run     # проверка цепочки на тестовом сервере LE, сертификат не меняется
./scripts/renew-certs.sh --force       # принудительное продление (--force-renewal)
```

> ⚠️ `--force` выпускает новый сертификат независимо от срока действия и расходует лимиты Let's Encrypt. Сейчас это 5 одинаковых сертификатов на один набор доменов за 7 дней. Для проверки используйте `--dry-run`.

### Лог и срок действия

```bash
tail -n 50 logs/renew.log
```

Узнать срок действия сертификата. Команда запускает openssl в отдельном одноразовом контейнере с томом сертификатов, доступным только для чтения:

```bash
. ./.env
docker run --rm -v chokepoint_letsencrypt:/etc/letsencrypt:ro alpine/openssl \
  x509 -enddate -noout -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
```

Ещё один вариант — встроенная команда certbot:

```bash
docker compose --profile certbot run --rm certbot certificates
```

Проверка «снаружи», того сертификата, который реально отдаёт nginx:

```bash
. ./.env
echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -enddate
```

### Вариант с systemd timer вместо cron

Если вы предпочитаете systemd, не включайте cron (`./scripts/cron.sh remove`). Вместо него создайте два файла, заменив `/opt/chokepoint` на путь к проекту.

`/etc/systemd/system/chokepoint-renew.service`:

```ini
[Unit]
Description=CHOKEPOINT: продление сертификата Let's Encrypt
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/opt/chokepoint/scripts/renew-certs.sh
# если проект принадлежит обычному пользователю из группы docker:
# User=deploy
```

`/etc/systemd/system/chokepoint-renew.timer`:

```ini
[Unit]
Description=CHOKEPOINT: продление сертификата дважды в сутки

[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
```

Включение и проверка:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now chokepoint-renew.timer
systemctl list-timers chokepoint-renew.timer
sudo systemctl start chokepoint-renew.service     # ручной запуск
journalctl -u chokepoint-renew.service -n 50
```

## 7. Обновление контента

### Новости

Новости хранятся в `site/data/news.json` и выводятся на странице через JS. Вёрстку трогать не нужно. Добавьте объект в массив `items`:

```json
{
  "id": "n13",
  "date": "2026-11-20",
  "title": "Короткий заголовок своими словами",
  "summary": "Одно-два предложения пересказа без длинных цитат.",
  "source": "Название издания",
  "url": "https://example.org/article",
  "tags": ["russia", "research"]
}
```

- `date` — дата публикации источника в формате `ГГГГ-ММ-ДД`. Карточки сортируются по ней, новые идут сверху.
- `id` — уникальный идентификатор. Под ним новость попадает в раздел «Источники» как «н13».
- `tags` — ключи из объекта `tags` в начале файла: `russia`, `world`, `research`, `courts`, `society`. По ним работают фильтры.
- Обновите поле `updated` и дату «Актуально на» в `site/index.html`: она указана в hero, в разделе новостей и в футере.

Проверить, что JSON корректен:

```bash
node -e "JSON.parse(require('fs').readFileSync('site/data/news.json','utf8')); console.log('ok')"
```

### Как применить изменения

Каталог `site/` смонтирован в контейнер напрямую, поэтому перезапуск не нужен. Достаточно обновить файлы на сервере:

```bash
git pull
```

HTML и `news.json` кэшируются на 5 минут. CSS, JS и изображения кэшируются на 30 дней, поэтому после правки стилей посетители увидят изменения не сразу. Чтобы изменения применились сразу, поменяйте имя файла или добавьте к ссылке параметр `?v=2`. Шрифты кэшируются на год.

Если вы меняли конфиг nginx:

```bash
docker compose exec web nginx -t && docker compose exec web nginx -s reload
```

Если меняли шаблон в `nginx/templates/`, контейнер нужно пересоздать, потому что envsubst выполняется при старте:

```bash
docker compose up -d --force-recreate web
```

### Тесты

```bash
node tests/easter-egg-counter.test.mjs
node tests/scroll-text.test.mjs
node tests/nginx-templates.test.mjs
bash tests/scripts.test.sh     # только на машине без настоящего crontab: тест подменяет crontab заглушкой
```

## 8. Режим «сайт-заглушка для REALITY» (3x-ui)

Сайт можно использовать как target-сервер для инбаунда VLESS + REALITY в [3x-ui](https://github.com/MHSanaei/3x-ui). В этом режиме на порту 443 работает Xray, а nginx уходит на loopback. Посетитель без ключа REALITY видит обычный сайт с настоящим сертификатом. Через тот же nginx проходят XHTTP и подписка 3x-ui.

Режим включается одной командой и так же выключается. Обычный режим из разделов 4–7 при этом не меняется.

### Как это устроено

```text
Интернет :443
   │
   ▼
Xray (3x-ui), инбаунд VLESS + TCP + REALITY (Vision), 0.0.0.0:443
   │  клиент с ключом REALITY → прокси
   │  все остальные (браузеры, сканеры, XHTTP-клиенты) → target
   ▼
nginx 127.0.0.1:9443 (сертификат Let's Encrypt, HTTP/2)   ← этот репозиторий
   ├── /                 → сайт CHOKEPOINT
   ├── XHTTP_PATH        → Xray, инбаунд XHTTP, 127.0.0.1:2023 (grpc_pass)
   ├── SUB_PATH          → подписка 3x-ui, 127.0.0.1:2096
   └── SUB_JSON_PATH     → JSON-подписка 3x-ui, 127.0.0.1:2096

nginx 0.0.0.0:80 → ACME-челлендж Let's Encrypt и 301-редирект на https
```

Что меняется по сравнению с обычным режимом (`docker-compose.reality.yml`):

- Контейнер `web` работает в сети хоста (`network_mode: host`). Так `127.0.0.1` внутри nginx — это loopback сервера, где слушают Xray и 3x-ui. Порт 443 nginx не занимает.
- Конфиг nginx собирается из `nginx/reality-templates/default.conf.template`. Блоки XHTTP и подписки в нём повторяют шаг 2 инструкции «Всё на 443»:
  - для XHTTP: `grpc_pass`, таймауты 1 ч, `client_max_body_size 0`, `grpc_buffer_size 16k`;
  - для подписки: `proxy_pass` с `Host $host`.
- Заголовки безопасности, кэш, страница 404, выпуск и продление сертификата работают так же, как в обычном режиме. Ставить nginx и certbot на хост, как в шаге 2 инструкции, **не нужно**. Если они уже стоят, остановите их, иначе займут порт 80.

Режим подключается через переменную `COMPOSE_FILE` в `.env`. Поэтому `docker compose up -d`, `init-letsencrypt.sh`, `renew-certs.sh` и cron сами работают в выбранном режиме.

### Требования

- Linux-хост: `network_mode: host` работает только на Linux.
- Docker Compose ≥ 2.24.4.
- 3x-ui, установленная на хост официальным скриптом `install.sh`. Если 3x-ui запущена в Docker в обычной сети, `127.0.0.1` из nginx до неё не достанет.
- Домен с A-записью на сервер, открытые порты 80 и 443.

### Включение

```bash
cp .env.example .env             # если ещё не сделано; укажите DOMAIN и LETSENCRYPT_EMAIL
./scripts/reality.sh enable      # записывает параметры в .env и пересоздаёт nginx
./scripts/init-letsencrypt.sh    # если сертификата ещё нет: нужен только порт 80
./scripts/cron.sh install        # автопродление, как в разделе 6
./scripts/reality.sh panel       # значения, которые нужно ввести в 3x-ui
```

`enable` при первом запуске придумывает случайные неочевидные пути XHTTP и подписки. Повторный вызов их не меняет: все параметры, не указанные явно, берутся из `.env`. Свои значения задаются флагами:

```bash
./scripts/reality.sh enable \
  --xhttp-path /media/7f3k9q/ \
  --sub-path /s9x/ --sub-json-path /s9xj/ \
  --target 127.0.0.1:9443
./scripts/reality.sh enable --no-xhttp    # вариант «только TCP» из инструкции; вернуть — --xhttp
./scripts/reality.sh enable --no-sub      # не проксировать подписку; вернуть — --sub
./scripts/reality.sh enable --no-apply    # только записать .env, nginx не трогать
./scripts/reality.sh status               # текущий режим и параметры
```

Выключенные пути (`--no-xhttp`, `--no-sub`) отвечают обычной страницей 404 сайта, как несуществующие. Поэтому не появляется ни 502, ни других отличий от обычного сайта.

### Что ввести в 3x-ui

`./scripts/reality.sh panel` печатает готовые значения для ваших пути и домена. Кратко:

| Где в 3x-ui | Поле | Значение |
| --- | --- | --- |
| Инбаунд `tcp-reality` | Protocol / Port | `vless` / `443`, Listen IP пусто |
|  | Transmission / Security | `TCP` (RAW), `Reality`, Xver `0` |
|  | Dest / Target | `127.0.0.1:9443` (`REALITY_TARGET_LISTEN`) |
|  | SNI / Server Names | ваш `DOMAIN` |
|  | Клиент | Flow `xtls-rprx-vision` |
| Инбаунд `xhttp` | Listen IP / Port | `127.0.0.1` / `2023` (`XHTTP_UPSTREAM`) |
|  | Transmission / Path | `XHTTP`, путь `XHTTP_PATH`, Mode `auto` |
|  | Security | `none`: TLS делает nginx |
|  | External Proxy | `tls`, ваш домен, `443` |
|  | Клиент | Flow пусто, тот же subId, что у TCP-клиента |
| Настройки → Подписка | Listen IP / Порт | `127.0.0.1` / `2096` (`SUB_UPSTREAM`) |
|  | URI Path | `SUB_PATH` |
|  | Reverse Proxy URI | `https://DOMAIN` + `SUB_PATH` (для JSON — `SUB_JSON_PATH`) |
|  | Сертификат и ключ | пусто |

Остальные шаги инструкции выполняются в 3x-ui и на хосте, как в ней описано:
- SSH-туннель к панели;
- Listen IP панели `127.0.0.1`;
- `ufw` с портами SSH, 80 и 443;
- fail2ban.

Порт `9443` слушает только `127.0.0.1`, поэтому открывать его в файрволе не нужно. Контейнер в сети хоста не обходит `ufw`, в отличие от проброшенных через `-p` портов.

### Переменные в `.env`

`enable` записывает их сам, но их можно править и руками, после правки выполните `./scripts/reality.sh enable`:

| Переменная | По умолчанию | Назначение |
| --- | --- | --- |
| `COMPOSE_FILE` | `docker-compose.yml:docker-compose.reality.yml` | включает режим; `disable` удаляет строку |
| `REALITY_TARGET_LISTEN` | `127.0.0.1:9443` | где nginx ждёт трафик от REALITY (Dest/Target) |
| `XHTTP_ENABLED` | `on` | `off` — вариант «только TCP» |
| `XHTTP_PATH` | `/media/<случайно>/` | путь XHTTP, с `/` в начале и в конце |
| `XHTTP_UPSTREAM` | `127.0.0.1:2023` | XHTTP-инбаунд Xray |
| `SUB_ENABLED` | `on` | `off` — не проксировать подписку |
| `SUB_PATH`, `SUB_JSON_PATH` | `/<случайно>/` | пути подписки и JSON-подписки |
| `SUB_UPSTREAM` | `127.0.0.1:2096` | сервер подписок 3x-ui |

Пути не могут пересекаться с файлами сайта (`/assets/`, `/css/`, `/js/`, `/fonts/`, `/data/`) и друг с другом, это проверяет скрипт.

### Порядок при переходе между режимами

- **Обычный режим → REALITY.** Сначала `./scripts/reality.sh enable`: nginx освобождает 443. Потом создайте или включите в 3x-ui инбаунд на 443.
- **REALITY → обычный режим.** Сначала выключите инбаунд Xray на 443, потом `./scripts/reality.sh disable`: nginx снова займёт 80 и 443. Параметры REALITY останутся в `.env` для повторного включения.

### Проверка

```bash
. ./.env
# на сервере: target отвечает сайтом с настоящим сертификатом и HTTP/2
curl -sI --resolve "$DOMAIN:9443:127.0.0.1" "https://$DOMAIN:9443/" | head -n 1
# снаружи: через Xray открывается тот же сайт
curl -sI "https://$DOMAIN/" | head -n 1
# конфиг nginx внутри контейнера: XHTTP и подписка на месте
docker compose exec web nginx -T 2>/dev/null | grep -E 'listen|location|grpc_pass|proxy_pass'
# подписка (подставьте subId клиента)
curl -s "https://$DOMAIN${SUB_PATH}<subId>" | base64 -d | head
# наружу открыты только SSH, 80 и 443
ss -tlnp
```

### Особенности

- **XHTTP требует HTTP/2.** `grpc_pass` работает только поверх HTTP/2, поэтому в клиентской ссылке нужен `alpn=h2`. Это ограничение схемы из инструкции, а не этого репозитория.
- **IP клиентов.** nginx видит все соединения с `127.0.0.1`, потому что их приводит Xray. Лимиты по IP в 3x-ui работают на TCP-инбаунде, для XHTTP — нет.
- **Сертификат.** Продление идёт через порт 80, Xray в этом не участвует. Отключать инбаунд на 443 на время выпуска сертификата не нужно, в отличие от шага 2 инструкции.

## 9. Пасхалка

На сайте есть пасхалка.

## 10. Частые проблемы

**Закрыт 80-й порт.** Let's Encrypt проверяет домен по HTTP на порту 80. Откройте его в файрволе сервера и в настройках облака: security group, firewall панели хостинга.

```bash
sudo ufw allow 80/tcp && sudo ufw allow 443/tcp     # если используется ufw
curl -I http://ваш-домен/.well-known/acme-challenge/test   # снаружи должен быть ответ 404 от nginx, а не таймаут
```

**DNS ещё не обновился.** Изменения A-записи расходятся до нескольких часов. Проверьте, что домен указывает на ваш сервер, и только потом запускайте выпуск:

```bash
getent hosts ваш-домен
dig +short ваш-домен @1.1.1.1
curl -s https://ifconfig.me    # IP сервера — должен совпадать
```

**Упёрлись в лимиты Let's Encrypt** (ошибка `too many certificates` или `too many failed authorizations`). Дождитесь окончания окна: обычно это неделя для повторных сертификатов и час для неудачных проверок. Пока ждёте, отлаживайтесь с `--staging` и `--dry-run`. Не запускайте `--force` без необходимости.

**cron не видит `docker`.** У cron минимальный `PATH`. Скрипты сами добавляют `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`. Если docker установлен в другое место, например через snap в `/snap/bin`, допишите путь в начало `scripts/lib.sh`. Пользователь, от имени которого стоит задача cron, должен иметь доступ к Docker: состоять в группе `docker` или быть root. Посмотрите `logs/renew.log`, ошибки вида «не найдена команда docker» попадают туда.

**nginx не стартует без сертификата** (в `docker compose logs web` видно `cannot load certificate`). Так бывает, если запустить `docker compose up -d` раньше `init-letsencrypt.sh` или если том с сертификатами удалили. Выполните:

```bash
./scripts/init-letsencrypt.sh
```

Если выпуск сертификата не удался, скрипт сам вернёт временный самоподписанный сертификат, чтобы nginx мог работать.

**Предупреждение `ssl_stapling ignored` в логах nginx.** Это нормально. В 2025 году Let's Encrypt прекратил поддержку OCSP, и в новых сертификатах нет OCSP-адреса. OCSP stapling в конфиге включён, но для сертификатов Let's Encrypt не используется.

**HSTS на localhost.** Локальный режим тоже отдаёт `Strict-Transport-Security`, чтобы его можно было проверить через `curl`. Некоторые браузеры запоминают HSTS и для `localhost`. Если потом http-сайты на localhost перестанут открываться, очистите HSTS для localhost в настройках браузера: в Chrome это `chrome://net-internals/#hsts`.

**Режим REALITY: nginx не стартует, `bind() to 0.0.0.0:80 failed (98: Address already in use)`.** Порт 80 на хосте занят: системным nginx из инструкции или Apache. Остановите их, например `sudo systemctl disable --now nginx`, и выполните `./scripts/reality.sh enable`.

**Режим REALITY: сайт по https не открывается, а на сервере `curl --resolve …:9443` работает.** Проверьте в инбаунде REALITY поле Dest/Target: должно быть `127.0.0.1:9443`, как в `REALITY_TARGET_LISTEN`. Проверьте и SNI/Server Names: должен быть ваш домен. Убедитесь, что инбаунд включён и слушает 443: `ss -tlnp | grep :443`.

**Режим REALITY: `docker compose` ругается на `!reset`.** Обновите Docker Compose до 2.24.4 или новее.

**Режим REALITY: XHTTP не подключается, в логе nginx 502.** Инбаунд XHTTP не запущен, либо его порт или путь не совпадает с `XHTTP_UPSTREAM` и `XHTTP_PATH`. Сверьте с `./scripts/reality.sh panel`, включая слеши.
