// ElevenLabs API client for AI voice generation

interface ElevenLabsConfig {
  apiKey: string;
}

interface Voice {
  voice_id: string;
  name: string;
  category: string;
  description?: string;
  labels?: Record<string, string>;
  settings?: {
    stability: number;
    similarity_boost: number;
    style?: number;
    use_speaker_boost?: boolean;
  };
}

interface VoiceGenerationRequest {
  voiceId: string;
  text: string;
  modelId?: string;
  stability?: number;
  similarityBoost?: number;
  style?: number;
}

interface VoiceGenerationResponse {
  audio: ArrayBuffer;
}

interface VoiceSettings {
  stability: number;
  similarity_boost: number;
  style: number;
  use_speaker_boost: boolean;
}

class ElevenLabsClient {
  private config: ElevenLabsConfig;
  private baseUrl = 'https://api.elevenlabs.io/v1';

  constructor(config: ElevenLabsConfig) {
    this.config = config;
  }

  private async request(endpoint: string, options: RequestInit = {}): Promise<any> {
    const response = await fetch(`${this.baseUrl}${endpoint}`, {
      ...options,
      headers: {
        'xi-api-key': this.config.apiKey,
        'Content-Type': 'application/json',
        ...options.headers,
      },
    });

    if (!response.ok) {
      throw new Error(`ElevenLabs API error: ${response.statusText}`);
    }

    return response.json();
  }

  // Get available voices
  async getVoices(): Promise<Voice[]> {
    const response = await this.request('/voices');
    return response.voices;
  }

  // Get a specific voice
  async getVoice(voiceId: string): Promise<Voice> {
    return await this.request(`/voices/${voiceId}`);
  }

  // Generate speech from text
  async generateSpeech(request: VoiceGenerationRequest): Promise<ArrayBuffer> {
    const url = `/text-to-speech/${request.voiceId}`;

    const body = {
      text: request.text,
      model_id: request.modelId || 'eleven_multilingual_v2',
      voice_settings: {
        stability: request.stability ?? 0.5,
        similarity_boost: request.similarityBoost ?? 0.75,
        style: request.style ?? 0,
        use_speaker_boost: true,
      },
    };

    const response = await fetch(`${this.baseUrl}${url}`, {
      method: 'POST',
      headers: {
        'xi-api-key': this.config.apiKey,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
    });

    if (!response.ok) {
      throw new Error(`ElevenLabs TTS error: ${response.statusText}`);
    }

    return response.arrayBuffer();
  }

  // Get voice settings
  async getVoiceSettings(voiceId: string): Promise<VoiceSettings> {
    return await this.request(`/voices/${voiceId}/settings`);
  }

  // Update voice settings
  async updateVoiceSettings(
    voiceId: string,
    settings: Partial<VoiceSettings>
  ): Promise<VoiceSettings> {
    return await this.request(`/voices/${voiceId}/settings`, {
      method: 'POST',
      body: JSON.stringify(settings),
    });
  }

  // Create a new voice (voice cloning - requires paid plan)
  async createVoice(name: string, files: File[]): Promise<Voice> {
    const formData = new FormData();
    formData.append('name', name);
    files.forEach((file) => formData.append('files', file));

    const response = await fetch(`${this.baseUrl}/voices/add`, {
      method: 'POST',
      headers: {
        'xi-api-key': this.config.apiKey,
      },
      body: formData,
    });

    if (!response.ok) {
      throw new Error(`ElevenLabs voice creation error: ${response.statusText}`);
    }

    return response.json();
  }
}

// Factory function
export function createElevenLabsClient(apiKey: string): ElevenLabsClient {
  return new ElevenLabsClient({ apiKey });
}

// Pre-defined voice presets based on energy level
export const VOICE_PRESETS = {
  chill: {
    stability: 0.8,
    similarityBoost: 0.7,
    style: 0,
  },
  balanced: {
    stability: 0.5,
    similarityBoost: 0.75,
    style: 0.2,
  },
  hype: {
    stability: 0.3,
    similarityBoost: 0.85,
    style: 0.5,
  },
};

// Helper to get voice settings based on energy slider (0-1)
export function getVoiceSettingsForEnergy(energy: number): {
  stability: number;
  similarityBoost: number;
  style: number;
} {
  // Energy 0 = chill, Energy 1 = hype
  return {
    stability: 0.8 - energy * 0.5, // Lower stability = more expressive
    similarityBoost: 0.7 + energy * 0.15, // Higher boost = closer to voice sample
    style: energy * 0.5, // Higher style = more emphasis
  };
}
