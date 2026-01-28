// Spotify Web API client
// Documentation: https://developer.spotify.com/documentation/web-api

interface SpotifyConfig {
  clientId: string;
  clientSecret: string;
  redirectUri: string;
}

export interface SpotifyTrack {
  id: string;
  name: string;
  artists: { id: string; name: string }[];
  album: {
    id: string;
    name: string;
    images: { url: string; width: number; height: number }[];
  };
  duration_ms: number;
  preview_url: string | null;
  uri: string;
  external_urls: { spotify: string };
}

export interface SpotifyPlaylist {
  id: string;
  name: string;
  description: string | null;
  images: { url: string }[];
  tracks: { total: number };
  owner: { display_name: string };
  uri: string;
}

export interface SpotifyUser {
  id: string;
  display_name: string;
  email: string;
  images: { url: string }[];
  product: string; // 'premium' | 'free'
}

export interface SpotifySearchResult {
  tracks?: { items: SpotifyTrack[] };
  artists?: { items: any[] };
  albums?: { items: any[] };
  playlists?: { items: SpotifyPlaylist[] };
}

export interface SpotifyRecommendations {
  tracks: SpotifyTrack[];
  seeds: any[];
}

// Spotify OAuth scopes required for the app
export const SPOTIFY_SCOPES = [
  'user-read-private',
  'user-read-email',
  'user-library-read',
  'playlist-read-private',
  'playlist-read-collaborative',
  'streaming',
  'user-read-playback-state',
  'user-modify-playback-state',
  'user-read-currently-playing',
].join(' ');

export class SpotifyClient {
  private accessToken: string | null = null;
  private refreshToken: string | null = null;
  private tokenExpiry: number = 0;
  private config: SpotifyConfig;

  constructor(config: SpotifyConfig) {
    this.config = config;
  }

  // Generate authorization URL for OAuth flow
  getAuthorizationUrl(state?: string): string {
    const params = new URLSearchParams({
      client_id: this.config.clientId,
      response_type: 'code',
      redirect_uri: this.config.redirectUri,
      scope: SPOTIFY_SCOPES,
      show_dialog: 'true',
    });

    if (state) {
      params.append('state', state);
    }

    return `https://accounts.spotify.com/authorize?${params.toString()}`;
  }

  // Exchange authorization code for tokens
  async exchangeCodeForTokens(code: string): Promise<{
    access_token: string;
    refresh_token: string;
    expires_in: number;
  }> {
    const response = await fetch('https://accounts.spotify.com/api/token', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Authorization: `Basic ${Buffer.from(`${this.config.clientId}:${this.config.clientSecret}`).toString('base64')}`,
      },
      body: new URLSearchParams({
        grant_type: 'authorization_code',
        code,
        redirect_uri: this.config.redirectUri,
      }),
    });

    if (!response.ok) {
      const error = await response.json();
      throw new Error(`Token exchange failed: ${error.error_description || error.error}`);
    }

    const data = await response.json();
    this.accessToken = data.access_token;
    this.refreshToken = data.refresh_token;
    this.tokenExpiry = Date.now() + data.expires_in * 1000;

    return data;
  }

  // Refresh access token
  async refreshAccessToken(): Promise<string> {
    if (!this.refreshToken) {
      throw new Error('No refresh token available');
    }

    const response = await fetch('https://accounts.spotify.com/api/token', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Authorization: `Basic ${Buffer.from(`${this.config.clientId}:${this.config.clientSecret}`).toString('base64')}`,
      },
      body: new URLSearchParams({
        grant_type: 'refresh_token',
        refresh_token: this.refreshToken,
      }),
    });

    if (!response.ok) {
      throw new Error('Failed to refresh token');
    }

    const data = await response.json();
    this.accessToken = data.access_token;
    this.tokenExpiry = Date.now() + data.expires_in * 1000;

    if (data.refresh_token) {
      this.refreshToken = data.refresh_token;
    }

    return this.accessToken;
  }

  // Set access token (for client-side use)
  setAccessToken(token: string, expiresIn?: number): void {
    this.accessToken = token;
    if (expiresIn) {
      this.tokenExpiry = Date.now() + expiresIn * 1000;
    }
  }

  // Check if token needs refresh
  isTokenExpired(): boolean {
    return Date.now() >= this.tokenExpiry - 60000; // 1 minute buffer
  }

  // Make authenticated API request
  private async apiRequest<T>(
    endpoint: string,
    options: RequestInit = {}
  ): Promise<T> {
    if (!this.accessToken) {
      throw new Error('No access token set');
    }

    const response = await fetch(`https://api.spotify.com/v1${endpoint}`, {
      ...options,
      headers: {
        Authorization: `Bearer ${this.accessToken}`,
        'Content-Type': 'application/json',
        ...options.headers,
      },
    });

    if (!response.ok) {
      if (response.status === 401) {
        throw new Error('Unauthorized - token may be expired');
      }
      const error = await response.json().catch(() => ({}));
      throw new Error(`Spotify API error: ${error.error?.message || response.statusText}`);
    }

    return response.json();
  }

  // Get current user profile
  async getCurrentUser(): Promise<SpotifyUser> {
    return this.apiRequest<SpotifyUser>('/me');
  }

  // Search for tracks, artists, albums, playlists
  async search(
    query: string,
    types: ('track' | 'artist' | 'album' | 'playlist')[] = ['track'],
    limit: number = 20
  ): Promise<SpotifySearchResult> {
    const params = new URLSearchParams({
      q: query,
      type: types.join(','),
      limit: limit.toString(),
    });
    return this.apiRequest<SpotifySearchResult>(`/search?${params.toString()}`);
  }

  // Get user's playlists
  async getUserPlaylists(limit: number = 50): Promise<{ items: SpotifyPlaylist[] }> {
    return this.apiRequest(`/me/playlists?limit=${limit}`);
  }

  // Get playlist tracks
  async getPlaylistTracks(playlistId: string, limit: number = 100): Promise<{ items: { track: SpotifyTrack }[] }> {
    return this.apiRequest(`/playlists/${playlistId}/tracks?limit=${limit}`);
  }

  // Get recommendations based on seed tracks/artists/genres
  async getRecommendations(options: {
    seed_tracks?: string[];
    seed_artists?: string[];
    seed_genres?: string[];
    target_energy?: number;
    target_valence?: number;
    limit?: number;
  }): Promise<SpotifyRecommendations> {
    const params = new URLSearchParams();
    
    if (options.seed_tracks?.length) {
      params.append('seed_tracks', options.seed_tracks.slice(0, 5).join(','));
    }
    if (options.seed_artists?.length) {
      params.append('seed_artists', options.seed_artists.slice(0, 5).join(','));
    }
    if (options.seed_genres?.length) {
      params.append('seed_genres', options.seed_genres.slice(0, 5).join(','));
    }
    if (options.target_energy !== undefined) {
      params.append('target_energy', options.target_energy.toString());
    }
    if (options.target_valence !== undefined) {
      params.append('target_valence', options.target_valence.toString());
    }
    params.append('limit', (options.limit || 20).toString());

    return this.apiRequest<SpotifyRecommendations>(`/recommendations?${params.toString()}`);
  }

  // Get available genre seeds
  async getAvailableGenres(): Promise<{ genres: string[] }> {
    return this.apiRequest('/recommendations/available-genre-seeds');
  }

  // Get user's saved tracks
  async getSavedTracks(limit: number = 50): Promise<{ items: { track: SpotifyTrack }[] }> {
    return this.apiRequest(`/me/tracks?limit=${limit}`);
  }

  // Get track details
  async getTrack(trackId: string): Promise<SpotifyTrack> {
    return this.apiRequest(`/tracks/${trackId}`);
  }

  // Get multiple tracks
  async getTracks(trackIds: string[]): Promise<{ tracks: SpotifyTrack[] }> {
    return this.apiRequest(`/tracks?ids=${trackIds.join(',')}`);
  }

  // Get audio features for a track
  async getAudioFeatures(trackId: string): Promise<{
    energy: number;
    valence: number;
    tempo: number;
    danceability: number;
  }> {
    return this.apiRequest(`/audio-features/${trackId}`);
  }
}

// Export singleton instance creator
export function createSpotifyClient(): SpotifyClient {
  const config: SpotifyConfig = {
    clientId: process.env.NEXT_PUBLIC_SPOTIFY_CLIENT_ID || '',
    clientSecret: process.env.SPOTIFY_CLIENT_SECRET || '',
    redirectUri: `${process.env.NEXT_PUBLIC_APP_URL}/api/spotify/callback`,
  };
  return new SpotifyClient(config);
}
