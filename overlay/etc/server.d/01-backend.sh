#!/usr/bin/env bash

function generate_laravel_env_file() {

cat<<EOF > /app/.env
APP_NAME=${FORMALZ_APP_NAME}
APP_ENV=${FORMALZ_APP_ENV}
APP_KEY=${FORMALZ_APP_KEY}
APP_DEBUG=${FORMALZ_APP_DEBUG}
APP_LOG_LEVEL=${FORMALZ_APP_LOG_LEVEL}
APP_URL=${FORMALZ_APP_URL}

DB_CONNECTION=mysql
DB_HOST=${FORMALZ_DB_HOST}
DB_PORT=${FORMALZ_DB_PORT}
DB_DATABASE=${FORMALZ_DB_DATABASE}
DB_USERNAME=${FORMALZ_DB_USERNAME}
DB_PASSWORD=${FORMALZ_DB_PASSWORD}

BROADCAST_DRIVER=log
CACHE_DRIVER=file
SESSION_DRIVER=file
SESSION_LIFETIME=120
QUEUE_DRIVER=sync

REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379

MAIL_DRIVER=${FORMALZ_MAIL_DRIVER}
MAIL_HOST=${FORMALZ_MAIL_HOST}
MAIL_PORT=${FORMALZ_MAIL_PORT}
MAIL_USERNAME=${FORMALZ_MAIL_USERNAME}
MAIL_PASSWORD=${FORMALZ_MAIL_PASSWORD}
MAIL_ENCRYPTION=${FORMALZ_MAIL_ENCRYPTION}

PUSHER_APP_ID=
PUSHER_APP_KEY=
PUSHER_APP_SECRET=
PUSHER_APP_CLUSTER=mt1

APP_ANALYTICS_ENABLED=${FORMALZ_ANALYTICS_ENABLED}
ANALYTICS_BASE_URL=${FORMALZ_ANALYTICS_BASE_URL}
ANALYTICS_API_BASE_URL=${FORMALZ_ANALYTICS_API_BASE_URL}
ANALYTICS_ADMIN_USERNAME=${FORMALZ_ANALYTICS_ADMIN_USERNAME}
ANALYTICS_ADMIN_PASSWORD=${FORMALZ_ANALYTICS_ADMIN_PASSWORD}
EOF

}

function generate_game_config() {

cat<<EOF > /app/public/js/formalz-config.js
FORMALZ_GAMESERVER_PROTOCOL = "${FORMALZ_GAMESERVER_PROTOCOL}";
FORMALZ_GAMESERVER_HOST = "${FORMALZ_GAMESERVER_HOST}"
FORMALZ_GAMESERVER_PORT = ${FORMALZ_GAMESERVER_PORT};
FORMALZ_GAMESERVER_PATH = "${FORMALZ_GAMESERVER_PATH}";
EOF

}

function configure_internal_proxies() {

    if [[ ! -z ${INTERNAL_PROXY_HOSTNAME} ]]; then
    INTERNAL_PROXY_IP=$(set +o pipefail && getent hosts ${INTERNAL_PROXY_HOSTNAME} | awk '{ print $1 }' && set -o pipefail)
    fi

    if [[ ! -z ${INTERNAL_PROXY_IP} ]]; then
    sed -i 's/LogFormat.*/LogFormat "%{X-Real-IP}i %l %u %t \\\"%r\\\" %>s %O \\\"%{Referer}i\\\" \\\"%{User-Agent}i\\\"" custom-combined/' /etc/apache2/sites-available/000-default.conf
    sed -i "s/protected \$proxies.*/protected \$proxies = ['${INTERNAL_PROXY_IP}'];/" /app/app/Http/Middleware/TrustProxies.php
    else
    sed -i 's/LogFormat.*/LogFormat "%h %l %u %t \\\"%r\\\" %>s %O \\\"%{Referer}i\\\" \\\"%{User-Agent}i\\\"" custom-combined/' /etc/apache2/sites-available/000-default.conf
    fi
}

function wait_for_db()
{

    DBSTATUS=$(TERM=dumb php -- "$FORMALZ_DB_HOST" "$FORMALZ_DB_PORT" "$FORMALZ_DB_USERNAME" "$FORMALZ_DB_PASSWORD" <<'EOPHP'
<?php
    error_reporting(E_ERROR | E_PARSE);

    $stderr = fopen('php://stderr', 'w');

    $dbHost = $argv[1];
    $dbPort = $argv[2];
    $dbUsername = $argv[3];
    $dbPassword = $argv[4];

    $maxTries = 10;
    do {
        $con = new mysqli($dbHost, $dbUsername, $dbPassword, '', $dbPort);
        if ($con->connect_error) {
            fwrite($stderr, "\n" . 'MySQL Connection Error: (' . $con->connect_errno . ') ' . $con  ->connect_error . "\n");
            --$maxTries;
            if ($maxTries <= 0) {
                    exit(1);
            }
            sleep(3);
        }
    } while (!$con);

    $con->close();

    exit(0);
EOPHP
)

}

function setup_admin_user()
{

    DBSTATUS=$(TERM=dumb php -- "$FORMALZ_DB_HOST" "$FORMALZ_DB_PORT" "$FORMALZ_DB_USERNAME" "$FORMALZ_DB_PASSWORD" "$FORMALZ_DB_DATABASE" "$FORMALZ_ADMIN_USERNAME" "$FORMALZ_ADMIN_PASSWORD" "$FORMALZ_ADMIN_EMAIL" "$FORMALZ_ADMIN_JOB_TITLE" <<'EOPHP'
<?php
    error_reporting(E_ERROR | E_PARSE);

    $stderr = fopen('php://stderr', 'w');

    $dbHost = $argv[1];
    $dbPort = $argv[2];
    $dbUsername = $argv[3];
    $dbPassword = $argv[4];
    $dbName = $argv[5];

    $adminUserName = $argv[6];
    // The backend uses Laravel's bcrypt()
    $adminPassword = password_hash($argv[7], PASSWORD_BCRYPT);
    $adminEmail = $argv[8];
    $adminJobTitle = $argv[9];

    $con = new mysqli($dbHost, $dbUsername, $dbPassword, '', $dbPort);
    if ($con->connect_error) {
        fwrite($stderr, "\n" . 'MySQL Connection Error: (' . $con->connect_errno . ') ' . $con->connect_error . "\n");
        exit(1);
    }

    $con->select_db($con->real_escape_string($dbName));

    $query = sprintf("SELECT * FROM `admins` WHERE `name` = '%s'",  $con->real_escape_string(adminUserName));
    $res = $con->query($query);
    if ($res !== false && $res->num_rows > 1) {
        fwrite($stderr, "\n" . 'Formalz backend admin user already configured'. "\n");
        $res->free();
        $con->close();
        exit(0);
    }
    $res->free();

    $query = sprintf("INSERT INTO `admins` (`name`, `email`, `job_title`, `password`, `created_at`, `updated_at`) VALUES ('%s', '%s', '%s', '%s', NOW(), NOW())", 
        $con->real_escape_string($adminUserName),
        $con->real_escape_string($adminEmail),
        $con->real_escape_string($adminJobTitle),
        $con->real_escape_string($adminPassword)
    );
    $res = $con->query($query);

    if ($res !== true) {
        fwrite($stderr, "\n" . 'Formalz backend admin can not be configured. Error: (' . $con->errno . ') ' . $con->error ."\n");
        $con->close();
        exit(1);
    }
    $con->close();

    exit(0);
EOPHP
)

}

generate_laravel_env_file
generate_game_config
configure_internal_proxies
wait_for_db

pushd /app
php artisan migrate 2>&1
popd

setup_admin_user

chown -R www-data:www-data /app