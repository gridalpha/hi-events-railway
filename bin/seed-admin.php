<?php

declare(strict_types=1);

/**
 * Creates the first hi.events account through the application's own
 * CreateAccountHandler, so the account, the owner user, the default account
 * configuration and the messaging tier are wired exactly as a real signup wires
 * them. Restating that as SQL would drift from upstream on the next migration.
 */

require '/app/backend/vendor/autoload.php';

$app = require '/app/backend/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

$email = strtolower(trim((string) getenv('HIEVENTS_ADMIN_EMAIL')));
$password = (string) getenv('HIEVENTS_ADMIN_PASSWORD');

if ($email === '' || $password === '') {
    fwrite(STDOUT, "[seed-admin] no credentials supplied, skipping\n");
    exit(0);
}

if (strlen($password) < 8) {
    fwrite(STDERR, "[seed-admin] HIEVENTS_ADMIN_PASSWORD must be at least 8 characters\n");
    exit(1);
}

if (Illuminate\Support\Facades\DB::table('users')->exists()) {
    fwrite(STDOUT, "[seed-admin] an account already exists, nothing to do\n");
    exit(0);
}

// The handler sends a confirmation e-mail inside its own transaction and honours
// the registration switch. A mail service that has not started yet would roll
// the whole account back, and registration is closed by default here.
config([
    'mail.default' => 'log',
    'app.disable_registration' => false,
]);

$handler = $app->make(HiEvents\Services\Application\Handlers\Account\CreateAccountHandler::class);

$account = $handler->handle(
    HiEvents\Services\Application\Handlers\Account\DTO\CreateAccountDTO::fromArray([
        'email' => $email,
        'password' => $password,
        'first_name' => getenv('HIEVENTS_ADMIN_FIRST_NAME') ?: 'Admin',
        'last_name' => getenv('HIEVENTS_ADMIN_LAST_NAME') ?: null,
        'locale' => getenv('HIEVENTS_ADMIN_LOCALE') ?: 'en',
        'timezone' => getenv('HIEVENTS_ADMIN_TIMEZONE') ?: null,
        'currency_code' => getenv('HIEVENTS_ADMIN_CURRENCY') ?: null,
    ])
);

fwrite(STDOUT, sprintf("[seed-admin] created account %d owned by %s\n", $account->getId(), $email));
