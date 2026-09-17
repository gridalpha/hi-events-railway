<?php

/**
 * Railway health check for the Hi.Events web service.
 *
 * Deliberately does not boot Laravel: the prober runs every few seconds and a
 * full framework boot is both slow and noisy. It opens the two dependencies
 * the app cannot work without — the Postgres database and the Redis queue —
 * using exactly the variables the app itself is configured with, so a broken
 * dependency fails the deployment instead of rolling out green.
 *
 * Anonymous by design: Railway's prober sends no credentials and a 401 fails a
 * deploy exactly like a 503.
 */

declare(strict_types=1);

header('Content-Type: text/plain; charset=utf-8');
header('Cache-Control: no-store');

function fail(string $why): never
{
    http_response_code(503);
    echo "unhealthy: $why\n";
    exit;
}

// --- Postgres --------------------------------------------------------------
$databaseUrl = getenv('DATABASE_URL') ?: '';

if ($databaseUrl === '') {
    fail('DATABASE_URL is not set');
}

$parts = parse_url($databaseUrl);

if ($parts === false || !isset($parts['host'])) {
    fail('DATABASE_URL could not be parsed');
}

$dsn = sprintf(
    'pgsql:host=%s;port=%d;dbname=%s',
    $parts['host'],
    $parts['port'] ?? 5432,
    ltrim($parts['path'] ?? '/postgres', '/')
);

try {
    $pdo = new PDO(
        $dsn,
        urldecode($parts['user'] ?? ''),
        urldecode($parts['pass'] ?? ''),
        [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_TIMEOUT => 5,
        ]
    );
    $pdo->query('SELECT 1')->fetchColumn();
} catch (Throwable $e) {
    fail('postgres: ' . $e->getMessage());
}

// --- Redis -----------------------------------------------------------------
$redisUrl = getenv('REDIS_URL') ?: '';

if ($redisUrl !== '') {
    $redisParts = parse_url($redisUrl);

    if ($redisParts === false || !isset($redisParts['host'])) {
        fail('REDIS_URL could not be parsed');
    }

    try {
        $redis = new Redis();
        $redis->connect($redisParts['host'], (int)($redisParts['port'] ?? 6379), 5.0);

        if (isset($redisParts['pass'])) {
            $redis->auth([
                urldecode($redisParts['user'] ?? 'default'),
                urldecode($redisParts['pass']),
            ]);
        }

        $redis->ping();
        $redis->close();
    } catch (Throwable $e) {
        fail('redis: ' . $e->getMessage());
    }
}

echo "ok\n";
