# AI Radio DJ 🎵

Your personal AI-hosted radio station with customized commentary and music.

**100% Cloud-Native** - Nothing runs locally. Everything happens in the cloud.

## Features

- 🎧 **Apple Music Integration** - Stream your vibe with Apple Music API
- 🤖 **AI Commentary** - Serverless LLM-generated track descriptions
- 🎭 **Multiple AI Personalities** - Cloud TTS for different voices
- 📊 **Energy Slider** - From chill vibes to hype mode
- 📱 **Message Injection** - Read Telegram messages, calendar events on air
- 🌐 **Works Everywhere** - Web app runs in browser, all processing in cloud

## Cloud Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        AI RADIO DJ CLOUD                            │
├─────────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────────┐  │
│  │   Vercel    │    │   Vercel    │    │      Railway/Render     │  │
│  │  Frontend   │    │ API Routes  │    │   Background Workers    │  │
│  │  (Next.js)  │    │  (Serverless)│    │   (Commentary Queue)   │  │
│  └─────────────┘    └─────────────┘    └─────────────────────────┘  │
│         │                  │                        │                │
│         └──────────────────┼────────────────────────┘                │
│                            │                                        │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │                     Supabase (PostgreSQL)                        │ │
│  │  • User Profiles  • Stations  • Voices  • Message Queue         │ │
│  │  • Listening History  • Preferences  • Calendar Events           │ │
│  └─────────────────────────────────────────────────────────────────┘ │
│                            │                                        │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │                        External Services                         │ │
│  │  • Apple Music API  • ElevenLabs API  • Clawdbot Gateway        │ │
│  └─────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

## Deployment (5 Minutes)

### 1. Supabase (Database)
```bash
# Create project at https://supabase.com
# Run migrations in Supabase SQL editor using prisma/schema.prisma
```

### 2. Vercel (Frontend + API)
```bash
# Connect your GitHub repo to Vercel
# Add environment variables in Vercel dashboard
# Deploy - automatic!
```

### 3. ElevenLabs + Apple Music
- Get API keys from their dashboards
- Add to Vercel environment variables

## Environment Variables (Vercel)

```
# Supabase
NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=your-anon-key
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key

# Apple Music
NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN=your-token

# ElevenLabs
ELEVENLABS_API_KEY=your-api-key

# Clawdbot Gateway
CLAWDBOT_GATEWAY_URL=https://your-gateway.com  # or keep local
```

## How It Works

1. **User visits app** → Loads in browser (Vercel CDN)
2. **Selects station** → Fetches config from Supabase
3. **Streams music** → Apple Music API directly to browser
4. **Needs commentary** → API route calls LLM (cloud), generates TTS (cloud)
5. **Audio plays** → Browser receives audio URLs, plays seamlessly
6. **Messages come in** → Telegram webhook → Supabase message queue
7. **DJ reads messages** → Background worker injects into commentary stream

## Zero Local Dev

```bash
# No local installation needed!
# Everything happens in the cloud.

# Just:
# 1. Push code to GitHub
# 2. Connect to Vercel
# 3. Add API keys
# 4. Done
```

## API Keys Required

### Apple Music Developer
1. [Apple Developer Portal](https://developer.apple.com/account/)
2. Create MusicKit identifier
3. Generate token
4. Add to Vercel

### ElevenLabs
1. [elevenlabs.io](https://elevenlabs.io/) - Sign up
2. Get API key from dashboard
3. Add to Vercel

### Supabase
1. [supabase.com](https://supabase.com/) - Create project
2. Copy URL + keys
3. Add to Vercel

## Message Injection API

```typescript
// Telegram webhook calls this:
POST https://your-app.vercel.app/api/messages
{
  "userId": "user-123",
  "source": "telegram",
  "content": "Hey, don't forget your meeting at 3pm!",
  "priority": 5
}
```

## Tech Stack

- **Frontend:** Next.js 15 (Vercel serverless)
- **Database:** Supabase (PostgreSQL)
- **LLM:** MiniMax-M2.1 (Clawdbot Gateway)
- **TTS:** ElevenLabs API
- **Music:** Apple Music API
- **Deployment:** Vercel (free tier works!)

## License

MIT
