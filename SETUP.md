# AI Radio DJ - Supabase Setup Guide

## Using Your Existing Supabase Project

You have an existing Supabase project: **Rowerguy508's Project**

### Step 1: Get Your Supabase Credentials

1. Go to: https://supabase.com/dashboard
2. Login with: `angel.estrada@diomsinc.com`
3. Password from your Passwords.csv: `mixjuz-vonkIj-9qyphi`
4. Click on **Rowerguy508's Project** (or create a new project named `ai-radio-dj`)

### Step 2: Get API Keys

In your Supabase dashboard:
1. Go to **Project Settings** (cog icon) → **API**
2. Copy these values:
   - **Project URL** → `NEXT_PUBLIC_SUPABASE_URL`
   - **anon public** key → `NEXT_PUBLIC_SUPABASE_ANON_KEY`
   - **service_role** secret → `SUPABASE_SERVICE_ROLE_KEY` (keep this secret!)

### Step 3: Run Database Migration

1. In Supabase Dashboard → **SQL Editor**
2. Copy the contents of `supabase-migration.sql`
3. Click **Run** to execute

### Step 4: Connect to Vercel

1. Go to: https://vercel.com
2. Login (you may need to create account or use GitHub)
3. Click **Add New Project**
4. Select: **Rowerguy508/ai-radio-dj** (import from GitHub)
5. Click **Deploy**

### Step 5: Add Environment Variables

In Vercel Project Settings → **Environment Variables**, add:

```
NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=your-anon-key
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key
NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN=your-musickit-token
ELEVENLABS_API_KEY=your-elevenlabs-api-key
NEXT_PUBLIC_APP_URL=https://your-app.vercel.app
```

### Step 6: Redeploy

After adding env vars, Vercel will automatically redeploy.

---

## Troubleshooting

### "Project not found" when pushing to GitHub
Make sure you created the repo at https://github.com/new with the name `ai-radio-dj`

### Supabase migration fails
Run the SQL in smaller batches or check for any existing tables.

### Apple Music not working
You need a valid MusicKit JWT token from Apple Developer Portal.

---

## Quick Links

- **Supabase Dashboard**: https://supabase.com/dashboard
- **Vercel Dashboard**: https://vercel.com
- **GitHub Repo**: https://github.com/Rowerguy508/ai-radio-dj
- **Apple Developer**: https://developer.apple.com/account/
- **ElevenLabs**: https://elevenlabs.io
