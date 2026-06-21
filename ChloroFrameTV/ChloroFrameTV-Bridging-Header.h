/*
 * ChloroFrameTV-Bridging-Header.h
 *
 * tvOS bridging header. Exposes only the portable FEC C code to Swift.
 *
 * Unlike the macOS bridging header, this intentionally does NOT import
 * <opus/opus.h>: the vendored libopus.a is a macOS arm64 static library and
 * does not link against tvOS. Opus audio decode is deferred to a later phase,
 * where tvOS will either link a tvOS-built libopus or use the AudioToolbox
 * (AppleOpusDecoder) path, which needs no external library. See
 * design/tvos-port-plan.md section 7.4.
 *
 * Set in the ChloroFrameTV target Build Settings:
 *   Objective-C Bridging Header = ChloroFrameTV/ChloroFrameTV-Bridging-Header.h
 *   Header Search Paths        += $(PROJECT_DIR)/ChloroFrame/Network/FEC
 */

#import "nanors_impl.h"
