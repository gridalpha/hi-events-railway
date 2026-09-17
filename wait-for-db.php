<?php

/**
 * Exit 0 once the Hi.Events schema exists in the configured database.
 *
 * Railway has no service dependency ordering, so the worker can boot before
 * the web service has finished migrating. One role runs the migrations (web)
 * and every other role waits here rather than racing it — two `artisan
 * migrate` processes against one database is a coin toss, and the loser
 * usually exits.
 */

declare(strict_types=1);

$deadlineSeconds = (int)(getenv('HIEVENTS_DB_WAIT_SECONDS') ?: 300);
$deadline = time() + $deadlineSeconds;

$databaseUrl = getenv('DATABASE_URL') ?: '';

if ($databaseUrl === '') {
    fwrite(STDERR, "[wait-for-db] DATABASE_URL is not set\n");
    exit(1);
}

$parts = parse_url($databaseUrl);

if ($parts === false || !isset($parts['host'])) {
    fwrite(STDERR, "[wait-for-db] DATABASE_URL could not be parsed\n");
    exit(1);
}

$dsn = sprintf(
    'pgsql:host=%s;port=%d;dbname=%s',
    $parts['host'],
    $parts['port'] ?? 5432,
    ltrim($parts['path'] ?? '/postgres', '/')
);

$lastError = 'never connected';

while (time() < $deadline) {
    try {
        $pdo = new PDO(
            $dsn,
            urldecode($parts['user'] ?? ''),
            urldecode($parts['pass'] ?? ''),
            [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_TIMEOUT => 5]
        );

        $exists = $pdo->query("SELECT to_regclass('public.accounts')")->fetchColumn();

        if ($exists !== null && $exists !== false) {
            echo "[wait-for-db] schema is present\n";
            exit(0);
        }

        $lastError = 'connected, but the accounts table does not exist yet';
    } catch (Throwable $e) {
        $lastError = $e->getMessage();
    }

    echo "[wait-for-db] waiting: $lastError\n";
    sleep(5);
}

fwrite(STDERR, "[wait-for-db] gave up after {$deadlineSeconds}s: $lastError\n");
exit(1);
