# CHOKEPOINT — информер о блокировках

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
│   ├── conf.d/00-http.conf     # http-уровень: server_tokens, gzip, TLS-параметры, кэш
│   └── snippets/               # заголовки безопасности, раздача сайта, ACME и /healthz
├── scripts/
│   ├── init-letsencrypt.sh     # первичный выпуск сертификата (есть флаг --staging)
│   ├── renew-certs.sh          # продление и reload nginx (для cron)
│   ├── cron.sh                 # install / remove / status / run для расписания продления
│   ├── lib.sh                  # общие функции скриптов
│   └── selfsigned.py           # временный самоподписанный сертификат (запускается в контейнере certbot)
├── tests/
│   ├── easter-egg-counter.test.mjs  # тесты логики пасхалки (node, без зависимостей)
│   ├── scroll-text.test.mjs         # сверка текста свитка с эталоном
│   ├── scripts.test.sh              # тесты cron.sh и renew-certs.sh на заглушках
│   └── fixtures/scroll-text.txt     # эталонный текст свитка
├── tools/
│   ├── build-scroll.mjs        # генерирует разметку свитка из эталонного текста
│   └── dev-server.mjs          # локальный просмотр без Docker (с той же CSP)
├── research/notes.md           # исследование: каждый факт с источником и датой
├── logs/                       # сюда пишется renew.log
├── docker-compose.yml          # боевой режим: web (nginx) + certbot (profile)
├── docker-compose.local.yml    # локальный режим с самоподписанным сертификатом
└── .env.example                # DOMAIN и LETSENCRYPT_EMAIL
```

## 3. Требования

- Linux-сервер (VPS) с белым IP.
- **Docker** и **Docker Compose v2**, то есть команда `docker compose`, а не `docker-compose`.
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
bash tests/scripts.test.sh     # только на машине без настоящего crontab: тест подменяет crontab заглушкой
```

## 8. Пасхалка

На сайте есть пасхалка.

## 9. Частые проблемы

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
