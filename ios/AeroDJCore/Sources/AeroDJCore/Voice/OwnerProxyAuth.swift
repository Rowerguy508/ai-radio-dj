#if AERODJ_OWNER_AB
import Foundation

/// Owner A/B only (Sentinel gate 1): where the owner's proxy token lives on the owner's
/// device. The whole file compiles only with `AERODJ_OWNER_AB`; the Keychain service name is a
/// Release-binary needle in `check-release-disables-paid-voice.sh` and the ios.yml Release grep,
/// with the owner A/B build as positive control. No token value is ever in source.
public enum OwnerProxyAuth {
    public static let keychainService = "com.aerodj.owner-ab.tts-proxy"
}
#endif
