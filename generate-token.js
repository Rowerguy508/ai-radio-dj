#!/usr/bin/env node
/**
 * Apple Music Developer Token Generator (ES256)
 */

const fs = require('fs');
const crypto = require('crypto');
const path = require('path');

const TEAM_ID = 'S85APB73YV';
const KEY_ID = 'NJU7G24AGM';
const PRIVATE_KEY_PATH = path.join(__dirname, 'private-key.txt');

function base64UrlEncode(str) {
  return Buffer.from(str)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=/g, '');
}

function generateToken() {
  const privateKey = fs.readFileSync(PRIVATE_KEY_PATH, 'utf8');
  console.log('✓ Private key loaded');

  const header = {
    alg: 'ES256',
    kid: KEY_ID,
    typ: 'JWT'
  };

  const now = Math.floor(Date.now() / 1000);
  const exp = now + (180 * 24 * 60 * 60);

  const payload = {
    iss: TEAM_ID,
    iat: now,
    exp: exp
  };

  console.log('Token valid from:', new Date(now * 1000).toISOString());
  console.log('Token expires:', new Date(exp * 1000).toISOString());

  const encodedHeader = base64UrlEncode(JSON.stringify(header));
  const encodedPayload = base64UrlEncode(JSON.stringify(payload));
  const signatureInput = `${encodedHeader}.${encodedPayload}`;

  // Sign with ECDSA-SHA256
  const sign = crypto.createSign('sha256WithRSAEncryption');
  sign.update(signatureInput);
  const signature = sign.sign(privateKey, 'base64');
  const encodedSignature = base64UrlEncode(Buffer.from(signature, 'base64'));

  const token = `${signatureInput}.${encodedSignature}`;

  console.log('\n✓ Token generated!');
  console.log('\nAdd to .env.local:');
  console.log('='.repeat(60));
  console.log(`NEXT_PUBLIC_APPLE_MUSIC_KEY_ID=${KEY_ID}`);
  console.log(`NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN=${token}`);
  console.log('='.repeat(60));

  // Update .env.local
  const envPath = path.join(__dirname, '.env.local');
  let envContent = fs.readFileSync(envPath, 'utf8');
  
  // Update KEY_ID and TOKEN
  envContent = envContent.replace(
    /NEXT_PUBLIC_APPLE_MUSIC_KEY_ID=.*/,
    `NEXT_PUBLIC_APPLE_MUSIC_KEY_ID=${KEY_ID}`
  );
  envContent = envContent.replace(
    /NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN=.*/,
    `NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN=${token}`
  );
  
  fs.writeFileSync(envPath, envContent);
  console.log('\n✓ Updated .env.local');

  return token;
}

generateToken();
