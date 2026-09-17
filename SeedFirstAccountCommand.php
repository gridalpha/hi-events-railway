<?php

declare(strict_types=1);

namespace HiEvents\Console\Commands;

use HiEvents\Repository\Interfaces\AccountRepositoryInterface;
use HiEvents\Services\Application\Handlers\Account\CreateAccountHandler;
use HiEvents\Services\Application\Handlers\Account\DTO\CreateAccountDTO;
use Illuminate\Config\Repository;
use Illuminate\Console\Command;
use Throwable;

/**
 * Create the very first Hi.Events account from environment variables.
 *
 * Hi.Events has no "first admin" env var and no account-creation CLI: the only
 * way in is POST /api/auth/register, which means a freshly deployed instance
 * either leaves registration open to whoever finds the URL first, or has no
 * way in at all. This closes that window by creating the owner account through
 * the app's own handler before anything listens, so the template can ship
 * APP_DISABLE_REGISTRATION=true.
 *
 * Idempotent: it does nothing once any account exists, so an operator who
 * later changes the password or the email keeps their change across redeploys.
 */
class SeedFirstAccountCommand extends Command
{
    protected $signature = 'hievents:seed-first-account';

    protected $description = 'Create the first Hi.Events account from ADMIN_EMAIL / ADMIN_PASSWORD, if no account exists yet.';

    public function __construct(
        private readonly AccountRepositoryInterface $accountRepository,
        private readonly CreateAccountHandler       $createAccountHandler,
        private readonly Repository                 $config,
    )
    {
        parent::__construct();
    }

    public function handle(): int
    {
        $email = trim((string)env('ADMIN_EMAIL', ''));
        $password = (string)env('ADMIN_PASSWORD', '');

        if ($email === '' || $password === '') {
            $this->info('ADMIN_EMAIL / ADMIN_PASSWORD are not both set — skipping first-account seed.');

            return self::SUCCESS;
        }

        if ($this->accountRepository->countWhere([]) > 0) {
            $this->info('An account already exists — skipping first-account seed.');

            return self::SUCCESS;
        }

        // The handler refuses to run while registration is closed, which is
        // exactly how this deployment ships. Open it for this process only.
        $this->config->set('app.disable_registration', false);

        try {
            $account = $this->createAccountHandler->handle(new CreateAccountDTO(
                email: $email,
                password: $password,
                first_name: (string)env('ADMIN_FIRST_NAME', 'Admin'),
                locale: (string)env('ADMIN_LOCALE', 'en'),
                last_name: (string)env('ADMIN_LAST_NAME', 'User'),
                timezone: (string)env('APP_DEFAULT_TIMEZONE', 'UTC'),
                currency_code: (string)env('APP_DEFAULT_CURRENCY_CODE', 'USD'),
            ));
        } catch (Throwable $e) {
            $this->error('Could not seed the first account: ' . $e->getMessage());

            return self::FAILURE;
        }

        $this->info(sprintf(
            'Created the first Hi.Events account (id %d) owned by %s.',
            $account->getId(),
            $email
        ));

        return self::SUCCESS;
    }
}
