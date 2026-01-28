// Apple Music API client using MusicKit JS
// Documentation: https://developer.apple.com/documentation/musickitjs

interface AppleMusicConfig {
  developerToken: string;
  privateKey: string;
  keyId: string;
  teamId: string;
}

interface Track {
  id: string;
  title: string;
  artistName: string;
  albumName: string;
  artworkUrl: string;
  duration: number; // milliseconds
  previewUrl?: string;
}

interface Playlist {
  id: string;
  name: string;
  description?: string;
  artworkUrl: string;
  tracks: Track[];
}

interface UserProfile {
  id: string;
  name: string;
  email: string;
}

class AppleMusicClient {
  private config: AppleMusicConfig;
  private musicInstance: any = null;

  constructor(config: AppleMusicConfig) {
    this.config = config;
  }

  // Initialize MusicKit (call this once on app load)
  async initialize(): Promise<void> {
    if (typeof window === 'undefined') return;

    // MusicKit is loaded via script in layout
    if (window.MusicKit) {
      this.musicInstance = window.MusicKit.getInstance();
      await this.musicInstance.configure({
        developerToken: this.config.developerToken,
        app: {
          name: 'AI Radio DJ',
          build: '1.0.0',
        },
      });
    }
  }

  // Authenticate user (musicKit.getInstance().authorize())
  async authorize(): Promise<string> {
    if (!this.musicInstance) {
      throw new Error('MusicKit not initialized');
    }
    return await this.musicInstance.authorize();
  }

  // Get current user profile
  async getUserProfile(): Promise<UserProfile> {
    if (!this.musicInstance) {
      throw new Error('MusicKit not initialized');
    }
    return await this.musicInstance.api.userProfile();
  }

  // Search for tracks, artists, albums
  async search(query: string, types: string[] = ['songs', 'artists']): Promise<any> {
    if (!this.musicInstance) {
      throw new Error('MusicKit not initialized');
    }
    return await this.musicInstance.api.search(query, { types });
  }

  // Get a playlist by ID
  async getPlaylist(playlistId: string): Promise<Playlist> {
    if (!this.musicInstance) {
      throw new Error('MusicKit not initialized');
    }
    const playlist = await this.musicInstance.api.playlist(playlistId);
    return this.mapPlaylist(playlist);
  }

  // Get user's library playlists
  async getLibraryPlaylists(): Promise<Playlist[]> {
    if (!this.musicInstance) {
      throw new Error('MusicKit not initialized');
    }
    const response = await this.musicInstance.api.library.playlists();
    return response.data.map((p: any) => this.mapPlaylist(p));
  }

  // Get recommendations based on seed tracks/artists
  async getRecommendations(seedIds: {
    tracks?: string[];
    artists?: string[];
    genres?: string[];
  }): Promise<Track[]> {
    if (!this.musicInstance) {
      throw new Error('MusicKit not initialized');
    }
    // Use catalog recommendations
    const response = await this.musicInstance.api.recommendations(seedIds);
    return response.map((rec: any) => this.mapTrack(rec));
  }

  // Create a station playlist based on vibe
  async generateVibePlaylist(vibe: {
    energy: number; // 0-1
    genres?: string[];
    artists?: string[];
    recentListens?: string[];
  }): Promise<Track[]> {
    // This would call our backend to generate a smart playlist
    // For now, return some generic recommendations
    const genres = vibe.genres || ['pop', 'electronic'];
    const response = await this.musicInstance.api.search(genres.join(' '), {
      types: ['songs'],
      limit: 50,
    });

    return response.songs?.data?.map((t: any) => this.mapTrack(t)) || [];
  }

  // Map MusicKit response to our Track type
  private mapTrack(item: any): Track {
    return {
      id: item.id,
      title: item.attributes.name,
      artistName: item.attributes.artistName,
      albumName: item.attributes.albumName,
      artworkUrl: item.attributes.artwork?.url?.replace('{w}', '300').replace('{h}', '300'),
      duration: item.attributes.durationInMillis,
      previewUrl: item.attributes.previews?.[0]?.url,
    };
  }

  private mapPlaylist(item: any): Playlist {
    return {
      id: item.id,
      name: item.attributes.name,
      description: item.attributes.description?.standard,
      artworkUrl: item.attributes.artwork?.url?.replace('{w}', '300').replace('{h}', '300'),
      tracks: item.relationships?.tracks?.data?.map((t: any) => this.mapTrack(t)) || [],
    };
  }
}

// Factory function
export function createAppleMusicClient(config: AppleMusicConfig): AppleMusicClient {
  return new AppleMusicClient(config);
}

// React hook for using Apple Music
export function useAppleMusic() {
  // This would be a proper React hook
  // For now, this is a placeholder
  return {
    initialize: () => {},
    authorize: async () => '',
    isAuthorized: false,
  };
}

// Type declaration for MusicKit global
declare global {
  interface Window {
    MusicKit: any;
  }
}
