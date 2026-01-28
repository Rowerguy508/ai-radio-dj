# RAY.DO Telegram Bot

Control your AI Radio DJ from Telegram!

## Setup

1. **Create a Telegram bot:**
   - Open Telegram and search for @BotFather
   - Send `/newbot` to create a new bot
   - Copy your bot token

2. **Set up ngrok for local testing:**
   ```bash
   npx ngrok http 3000
   ```
   Copy the HTTPS URL (e.g., `https://abc123.ngrok.io`)

3. **Configure webhook:**
   ```bash
   curl -X POST http://localhost:3000/api/telegram/set-webhook \
     -H "Content-Type: application/json" \
     -d '{"webhookUrl":"https://YOUR-NGROK-URL", "botToken":"YOUR_BOT_TOKEN"}'
   ```

4. **Start RAY.DO locally:**
   ```bash
   cd /Users/angelestrada/clawd/ai-radio-dj
   npm run dev
   ```

5. **Message your bot on Telegram and try commands:**
   - `/start` - Get started
   - `/play` - Start playing
   - `/pause` - Pause playback
   - `/next` - Skip track
   - `/stations` - List stations

## Production Deployment

For Vercel deployment:
1. Add `TELEGRAM_BOT_TOKEN` to Vercel environment variables
2. Set webhook to: `https://your-vercel-url.com/api/telegram`
