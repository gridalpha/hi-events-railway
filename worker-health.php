<?php

/**
 * Railway health check for the Hi.Events worker service.
 *
 * A queue worker serves no HTTP, and without a health check a crash-looping
 * one reports SUCCESS forever. This is served by PHP's built-in server on
 * $PORT (bound [::], which is dual-stack, so Railway's IPv4 prober reaches it)
 * and answers 200 only when supervisord reports the queue worker RUNNING and
 * Redis — the queue transport — answers PING.
 *
 * Used as the router script: `php -S [::]:$PORT /railway/worker-health.php`.
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

// --- supervisord: is the queue worker actually running? ---------------------
$status = [];
$exitCode = 0;
exec(
    'supervisorctl -c /etc/supervisord.conf status laravel-queue-worker 2>&1',
    $status,
    $exitCode
);

$statusLine = implode(' ', $status);

if (!str_contains($statusLine, 'RUNNING')) {
    fail('queue worker not running: ' . trim($statusLine));
}

// --- Redis: the queue transport --------------------------------------------
$redisUrl = getenv('REDIS_URL') ?: '';

if ($redisUrl === '') {
    fail('REDIS_URL is not set');
}

$parts = parse_url($redisUrl);

if ($parts === false || !isset($parts['host'])) {
    fail('REDIS_URL could not be parsed');
}

try {
    $redis = new Redis();
    $redis->connect($parts['host'], (int)($parts['port'] ?? 6379), 5.0);

    if (isset($parts['pass'])) {
        $redis->auth([
            urldecode($parts['user'] ?? 'default'),
            urldecode($parts['pass']),
        ]);
    }

    $redis->ping();
    $redis->close();
} catch (Throwable $e) {
    fail('redis: ' . $e->getMessage());
}

echo "ok\n";
