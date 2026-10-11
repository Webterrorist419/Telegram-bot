# Simple Telegram Bot

A small, brand-neutral Telegram bot written in Rust, with an SQLite database. The public keyboard has three configurable URL buttons and a language switch. Only the configured administrator can see the admin-menu button.

## Requirements

- Ubuntu or Debian server
- Root access, or a user who can run commands with `sudo`
- A Telegram bot token from [@BotFather](https://t.me/BotFather)
- The administrator's numeric Telegram user ID

The installer installs the required system packages and Rust toolchain, builds the bot, creates a systemd service, and opens the administration menu.

## Install from a cloned repository

Clone the repository, then run the installer from the project directory:

```bash
git clone https://github.com/OWNER/REPOSITORY.git
cd REPOSITORY
sudo bash install.sh
```

Replace `OWNER/REPOSITORY` with the repository path. If the project is already on the server, run `sudo bash install.sh` from its directory instead.

Choose Russian or English when prompted. Enter the bot token and administrator Telegram ID when requested. Token input is deliberately visible while typing. At the end, the installer starts the bot and opens `bot-admin`.

## Install using the remote installer

The installer can also be downloaded and run directly. It asks for the GitHub repository URL if one was not provided:

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPOSITORY/main/install.sh -o /tmp/bot-admin
sudo bash /tmp/bot-admin
```

## Administration

Open the server-side administration menu at any time with:

```bash
sudo bot-admin
```

The menu lets you:

1. Install the bot.
2. Set or replace the bot token and administrator ID. The service restarts to apply the new credentials.
3. Clear the token and administrator ID. The service stops until credentials are set again.
4. Update the bot from the Git repository and restart its service.
5. Export a database backup.
6. Import a SQLite database backup.
7. Completely uninstall the bot, including its service, application files, database, and backups.

The uninstall action requires typing `DELETE` to confirm.

## Service and data locations

- Application: `/opt/simple-telegram-bot`
- SQLite database: `/var/lib/simple-telegram-bot/bot.sqlite3`
- Database backups: `/var/backups/simple-telegram-bot`
- systemd service: `simple-telegram-bot.service`
- Admin command: `/usr/local/bin/bot-admin`

Useful service commands:

```bash
sudo systemctl status simple-telegram-bot
sudo systemctl restart simple-telegram-bot
sudo journalctl -u simple-telegram-bot -f
```

## Configuration and statistics

`config.env.example` contains the empty configuration template. The installer creates `config.env` with `BOT_TOKEN`, `ADMIN_ID`, and `DATABASE_PATH`; do not publish a populated configuration file.

Button labels and URLs, enabled/disabled states, bot description, and language-specific text are managed in the bot's admin menu and stored in SQLite. User statistics count unique Telegram IDs that have sent `/start`. Resetting statistics clears the recorded user IDs; a user is counted again after their next `/start`.

When building from a project checkout, Cargo uses that checkout's `target/` directory and reuses its build cache. The installer copies the compiled executable to the service directory.
