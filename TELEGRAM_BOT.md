# RAY.DO Telegram Bot

The app receives Telegram updates at `/api/telegram`. It does not register or move the bot webhook.

## Setup

1. Create a bot with BotFather and store the bot token as `TELEGRAM_BOT_TOKEN` in the server environment. Do not send that token to the app in a request.
2. Set `TELEGRAM_WEBHOOK_SECRET` in the server environment. Both receivers reject every update when this value is missing or does not match the `X-Telegram-Bot-Api-Secret-Token` header.
3. Register the webhook out of band, once, against your own deployment origin. Point it at `https://<your-deployment>/api/telegram` and configure the same webhook secret. Do not use an in-app route to do this.

## Commands

Message the bot:

- `/start` - Get started
- `/play` - Start playing
- `/pause` - Pause playback
- `/next` - Skip track
- `/stations` - List stations

## Production

Add `TELEGRAM_BOT_TOKEN` and `TELEGRAM_WEBHOOK_SECRET` to the hosting provider's environment. Register the webhook yourself for `https://<your-deployment>/api/telegram`. If the bot's current webhook host is unexpected, rotate the bot token and the webhook secret.
