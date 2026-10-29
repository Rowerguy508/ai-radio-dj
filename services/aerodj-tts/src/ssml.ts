const ENTITIES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };

/** ElevenLabs does not accept SSML: strip tags, decode basic entities, collapse whitespace. */
export function ssmlToPlainText(ssml: string): string {
  return ssml
    .replace(/<[^>]*>/g, ' ')
    .replace(/&(amp|lt|gt|quot|apos);/g, (_, name: string) => ENTITIES[name])
    .replace(/\s+/g, ' ')
    .trim();
}
