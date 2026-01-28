#!/usr/bin/env node

/**
 * Apple Music Developer Token Generator
 * 
 * Usage:
 *   node generate-apple-token.js
 * 
 * Requires environment variables:
 *   APPLE_TEAM_ID - Your Apple Developer Team ID
 *   APPLE_KEY_ID - Your MusicKit Key ID  
 *   APPLE_PRIVATE_KEY - Your private key (or path to .p8 file)
 * 
 * Or place your AuthKey_XXXXX.p8 file in this directory
 */

const fs = require('fs');
const path = require('path');
const jwt = require('jsonwebtoken');

// Configuration - Get from environment or files
const TEAM_ID = process.env.APPLE_TEAM_ID || process.env.TEAM_ID;
const KEY_ID = process.env.APPLE_KEY_ID || process.env.KEY_ID;

let PRIVATE_KEY = process.env.APPLE_PRIVATE_KEY || process.env.PRIVATE_KEY;

// Try to read from .p8 file if no inline key
if (!PRIVATE_KEY) {
  // Look for AuthKey_*.p8 files
  const files = fs.readdirSync(__dirname).filter(f => f.startsWith('AuthKey_') && f.endsWith('.p8'));
  if (files.length > 0) {
    const p8File = path.join(__dirname, files[0]);
    PRIVATE_KEY = fs.readFileSync(p8File, 'utf8');
    // Extract key ID from filename
    const match = files[0].match(/AuthKey_(\w+)\.p8/);
    if (match && !KEY_ID) {
      console.log(`Found key file: ${files[0]}`);
    }
  }
}

async function generateToken() {
  if (!TEAM_ID) {
    console.error('❌ Error: APPLE_TEAM_ID is required');
    console.log('\nTo set up:');
    console.log('1. Go to https://developer.apple.com/account');
    console.log('2. Create a MusicKit key in Certificates, Identifiers & Profiles');
    console.log('3. Download the .p8 file');
    console.log('4. Run: APPLE_TEAM_ID=XXXXXXXXXX APPLE_KEY_ID=XXXXXXXXXX node generate-apple-token.js');
    process.exit(1);
  }

  if (!KEY_ID) {
    console.error('❌ Error: APPLE_KEY_ID is required');
    console.log('\nTo set up:');
    console.log('1. Go to https://developer.apple.com/account');
    console.log('2. Find your MusicKit Key ID');
    console.log('3. Run: APPLE_KEY_ID=XXXXXXXXXX node generate-apple-token.js');
    process.exit(1);
  }

  if (!PRIVATE_KEY) {
    console.error('❌ Error: Apple Music private key is required');
    console.log('\nTo set up:');
    console.log('1. Download your AuthKey_XXXXX.p8 file from Apple Developer Portal');
    console.log('2. Place it in this directory OR set APPLE_PRIVATE_KEY environment variable');
    console.log('\nThen run this script again.');
    process.exit(1);
  }

  try {
    // Generate the token
    const now = Math.floor(Date.now() / 1000);
    const exp = now + (24 * 60 * 60 * 180); // 180 days (Apple's max)

    const token = jwt.sign(
      {
        iss: TEAM_ID,
        iat: now,
        exp: exp,
      },
      PRIVATE_KEY,
      {
        algorithm: 'ES256',
        keyid: KEY_ID,
      }
    );

    console.log('\n✅ Apple Music Developer Token generated successfully!\n');
    console.log('Add this to your Vercel environment variables:\n');
    console.log('NEXT_PUBLIC_APPLE_MUSIC_KEY_ID=' + KEY_ID);
    console.log('NEXT_PUBLIC_APPLE_MUSIC_TEAM_ID=' + TEAM_ID);
    console.log('NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN=' + token);
    console.log('\nDone! Redeploy RAY.DO and Apple Music will work.\n');

    // Also save to .env file for local development
    const envContent = `
# Apple Music Developer Token (auto-generated)
# Generated at: ${new Date().toISOString()}
NEXT_PUBLIC_APPLE_MUSIC_KEY_ID=${KEY_ID}
NEXT_PUBLIC_APPLE_MUSIC_TEAM_ID=${TEAM_ID}
NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN=${token}
`;
    fs.writeFileSync('.env.local', envContent);
    console.log('Saved to .env.local for local development.\n');

  } catch (error) {
    console.error('❌ Error generating token:', error.message);
    process.exit(1);
  }
}

// Check if jsonwebtoken is installed
try {
  require.resolve('jsonwebtoken');
} catch (e) {
  console.log('Installing jsonwebtoken...');
  require('child_process').execSync('npm install jsonwebtoken', { stdio: 'inherit' });
  console.log('');
}

generateToken();
