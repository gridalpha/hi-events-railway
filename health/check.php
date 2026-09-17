<?php

declare(strict_types=1);

/**
 * Dependency probe, run from the entrypoint's background loop and from its
 * wait-for-dependency loops. Deliberately framework-free: it has to answer
 * before Laravel is usable, and it must not pay Laravel's boot cost every
 * ten seconds.
 *
 *   check.php db          Postgres accepts a connection
 *   check.php migrations  the schema has been migrated at least once
 *   check.php redis       Redis answers PING
 *   check.php ssr         the SSR frontend is listening behind nginx
 *   check.php all         everything this role needs
 */

$what = $argv[1] ?? 'all';
$role = getenv('HIEVENTS_ROLE') ?: 'web';

function fail(string $message): never
{
    fwrite(STDERR, "[check] $message\n");
    exit(1);
}

function pdo(): PDO
{
    $url = (string) getenv('DATABASE_URL');

    if ($url === '') {
        fail('DATABASE_URL is not set');
    }

    $parts = parse_url($url);

    if ($parts === false || !isset($parts['host'])) {
        fail('DATABASE_URL could not be parsed');
    }

    $dsn = sprintf(
        'pgsql:host=%s;port=%d;dbname=%s;sslmode=prefer;connect_timeout=5',
        $parts['host'],
        $parts['port'] ?? 5432,
        ltrim($parts['path'] ?? '', '/')
    );

    return new PDO(
        $dsn,
        rawurldecode($parts['user'] ?? ''),
        rawurldecode($parts['pass'] ?? ''),
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );
}

function checkDb(): void
{
    try {
        pdo()->query('SELECT 1');
    } catch (Throwable $e) {
        fail('postgres: ' . $e->getMessage());
    }
}

function checkMigrations(): void
{
    try {
        $count = (int) pdo()->query('SELECT count(*) FROM migrations')->fetchColumn();
    } catch (Throwable $e) {
        fail('migrations: ' . $e->getMessage());
    }

    if ($count === 0) {
        fail('migrations: the migrations table is empty');
    }
}

function checkRedis(): void
{
    $url = (string) getenv('REDIS_URL');

    if ($url !== '') {
        $parts = parse_url($url);
        $host = $parts['host'] ?? '127.0.0.1';
        $port = (int) ($parts['port'] ?? 6379);
        $user = rawurldecode($parts['user'] ?? '');
        $pass = rawurldecode($parts['pass'] ?? '');
    } else {
        $host = getenv('REDIS_HOST') ?: '127.0.0.1';
        $port = (int) (getenv('REDIS_PORT') ?: 6379);
        $user = (string) getenv('REDIS_USERNAME');
        $pass = (string) getenv('REDIS_PASSWORD');
    }

    $socket = @fsockopen($host, $port, $errno, $errstr, 5);

    if ($socket === false) {
        fail("redis: $host:$port $errstr");
    }

    stream_set_timeout($socket, 5);

    $command = '';
    if ($pass !== '') {
        $command .= $user !== '' ? "AUTH $user $pass\r\n" : "AUTH $pass\r\n";
    }
    $command .= "PING\r\n";

    fwrite($socket, $command);
    $reply = (string) fread($socket, 128);
    fclose($socket);

    if (!str_contains($reply, '+PONG')) {
        fail('redis: unexpected reply ' . trim($reply));
    }
}

function checkSsr(): void
{
    // The published image's nginx proxies everything but /api and /storage to
    // the SSR server on 5678. It is started by supervisord after nginx, so this
    // is what stops a deploy going green on a half-started container.
    $socket = @fsockopen('127.0.0.1', 5678, $errno, $errstr, 5);

    if ($socket === false) {
        fail("ssr: 127.0.0.1:5678 $errstr");
    }

    fclose($socket);
}

switch ($what) {
    case 'db':
        checkDb();
        break;
    case 'migrations':
        checkMigrations();
        break;
    case 'redis':
        checkRedis();
        break;
    case 'ssr':
        checkSsr();
        break;
    case 'all':
        checkDb();
        checkRedis();
        if ($role === 'web') {
            checkSsr();
        }
        break;
    default:
        fail("unknown check: $what");
}

echo "ok\n";
