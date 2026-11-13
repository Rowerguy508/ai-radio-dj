import raw from '../config/storekit.json' with { type: 'json' };
import type { StoreKitConfig } from './storekit-verify.js';

/**
 * The single StoreKit config for the proxy (design §5.1). Product IDs are
 * placeholders until the owner creates them in App Store Connect. Policy values
 * are Orion's interim defaults until the owner answers; each is a one-line edit.
 */
export function parseStoreKitConfig(value: unknown): StoreKitConfig {
  const v = value as Record<string, unknown>;
  const ids = v?.proProductIds;
  const ok =
    typeof v?.bundleId === 'string' &&
    v.bundleId.length > 0 &&
    Array.isArray(ids) &&
    ids.length > 0 &&
    ids.every((id) => typeof id === 'string' && id.length > 0) &&
    Number.isSafeInteger(v.installsPerPurchase) &&
    (v.installsPerPurchase as number) >= 1 &&
    (v.installsPerPurchase as number) <= 10 &&
    typeof v.allowSandboxInProduction === 'boolean' &&
    typeof v.honorGracePeriod === 'boolean' &&
    // Family Sharing moved to the single env setting AERODJ_TTS_PRO_ALLOW_FAMILY_SHARED
    // (src/pro-allowance.ts); a leftover key here would be a second, ignored knob, so refuse it.
    !Object.prototype.hasOwnProperty.call(v, 'allowFamilyShared');
  if (!ok) throw new Error('invalid StoreKit config');
  return Object.freeze({
    bundleId: v.bundleId as string,
    proProductIds: Object.freeze([...(ids as string[])]),
    installsPerPurchase: v.installsPerPurchase as number,
    allowSandboxInProduction: v.allowSandboxInProduction as boolean,
    honorGracePeriod: v.honorGracePeriod as boolean,
  });
}

export const STOREKIT_CONFIG: StoreKitConfig = parseStoreKitConfig(raw);
