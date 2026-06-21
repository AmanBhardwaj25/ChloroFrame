/*
 * ChloroFrameTV-Bridging-Header.h
 *
 * Exposes C symbols to Swift for the tvOS target:
 *   - the portable nanors FEC C code, and
 *   - Opus (vendored as libopus.xcframework, tvOS device + simulator slices).
 *
 * Set in the ChloroFrameTV target Build Settings:
 *   Objective-C Bridging Header = ChloroFrameTV/ChloroFrameTV-Bridging-Header.h
 *   Header Search Paths        += $(PROJECT_DIR)/ChloroFrame/Network/FEC
 *                                 $(PROJECT_DIR)/ChloroFrame/Vendor/opus/include
 */

#import "nanors_impl.h"
#import <opus/opus.h>
