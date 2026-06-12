//
//  VideoFormatHelper.swift
//  ChloroFrame
//
//  Created by Aman Bhardwaj on 6/8/26.
//

import Foundation
import CoreMedia
import VideoToolbox

/// Helper for creating CMFormatDescriptions from H.264/H.265 streams
/// This is essential for initializing VideoToolbox decoder
struct VideoFormatHelper {
    
    /// Create a format description from H.264 SPS and PPS NAL units.
    /// Pointers are kept valid by nesting both withUnsafeBytes closures around the API call.
    static func createH264FormatDescription(sps: Data, pps: Data) -> CMFormatDescription? {
        var formatDescription: CMFormatDescription?
        sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard let spsPtr = spsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsPtr = ppsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                let ptrs:  [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                let sizes: [Int]                  = [sps.count, pps.count]
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator:             kCFAllocatorDefault,
                    parameterSetCount:     2,
                    parameterSetPointers:  ptrs,
                    parameterSetSizes:     sizes,
                    nalUnitHeaderLength:   4,
                    formatDescriptionOut:  &formatDescription
                )
                if status != noErr {
                    AppLogger.shared.log(
                        "CMVideoFormatDescriptionCreateFromH264ParameterSets status=\(status) sps=\(sps.count)B pps=\(pps.count)B",
                        "video", "format"
                    )
                }
            }
        }
        return formatDescription
    }
    
    /// Create a format description from HEVC/H.265 VPS, SPS, and PPS NAL units.
    /// Pointers kept valid by nesting all three withUnsafeBytes closures around the API call.
    static func createHEVCFormatDescription(vps: Data, sps: Data, pps: Data) -> CMFormatDescription? {
        var formatDescription: CMFormatDescription?
        vps.withUnsafeBytes { vpsBytes in
            sps.withUnsafeBytes { spsBytes in
                pps.withUnsafeBytes { ppsBytes in
                    guard let vpsPtr = vpsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let spsPtr = spsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let ppsPtr = ppsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    let ptrs:  [UnsafePointer<UInt8>] = [vpsPtr, spsPtr, ppsPtr]
                    let sizes: [Int]                  = [vps.count, sps.count, pps.count]
                    let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator:            kCFAllocatorDefault,
                        parameterSetCount:    3,
                        parameterSetPointers: ptrs,
                        parameterSetSizes:    sizes,
                        nalUnitHeaderLength:  4,
                        extensions:           nil,
                        formatDescriptionOut: &formatDescription
                    )
                    if status != noErr {
                        AppLogger.shared.log(
                            "CMVideoFormatDescriptionCreateFromHEVCParameterSets status=\(status) vps=\(vps.count)B sps=\(sps.count)B pps=\(pps.count)B",
                            "video", "format"
                        )
                    }
                }
            }
        }
        return formatDescription
    }
    
    /// Parse NAL unit type from the first byte
    static func parseH264NALType(_ data: Data) -> H264NALType? {
        guard let firstByte = data.first else { return nil }
        let nalType = firstByte & 0x1F
        return H264NALType(rawValue: nalType)
    }
    
    /// Parse HEVC/H.265 NAL unit type
    static func parseHEVCNALType(_ data: Data) -> HEVCNALType? {
        guard data.count >= 2 else { return nil }
        let nalType = (data[0] >> 1) & 0x3F
        return HEVCNALType(rawValue: nalType)
    }
}

/// H.264 NAL unit types
enum H264NALType: UInt8 {
    case unspecified = 0
    case slice = 1
    case sliceDataPartitionA = 2
    case sliceDataPartitionB = 3
    case sliceDataPartitionC = 4
    case sliceIDR = 5
    case sei = 6
    case sps = 7  // Sequence Parameter Set
    case pps = 8  // Picture Parameter Set
    case accessUnitDelimiter = 9
    case endOfSequence = 10
    case endOfStream = 11
    case fillerData = 12
    case spsExtension = 13
}

/// HEVC/H.265 NAL unit types (subset)
enum HEVCNALType: UInt8 {
    case vps = 32  // Video Parameter Set
    case sps = 33  // Sequence Parameter Set
    case pps = 34  // Picture Parameter Set
    case idrWRadl = 19
    case idrNLp = 20
    case trailN = 0
    case trailR = 1
}

/// Example: Stream parser that extracts NAL units and creates format description
class StreamParser {
    private var spsData: Data?
    private var ppsData: Data?
    private var vpsData: Data?
    private var formatDescription: CMFormatDescription?
    
    var isH265: Bool = false
    
    /// Process incoming stream data and extract NAL units
    /// Returns format description once parameter sets are found
    func processStreamData(_ data: Data) -> CMFormatDescription? {
        // Find NAL unit start codes (0x00 0x00 0x00 0x01)
        let nalUnits = extractNALUnits(from: data)
        
        for nalUnit in nalUnits {
            if isH265 {
                processHEVCNAL(nalUnit)
            } else {
                processH264NAL(nalUnit)
            }
        }
        
        // Try to create format description if we have all parameter sets
        if formatDescription == nil {
            if isH265 {
                if let vps = vpsData, let sps = spsData, let pps = ppsData {
                    formatDescription = VideoFormatHelper.createHEVCFormatDescription(
                        vps: vps, sps: sps, pps: pps
                    )
                }
            } else {
                if let sps = spsData, let pps = ppsData {
                    formatDescription = VideoFormatHelper.createH264FormatDescription(
                        sps: sps, pps: pps
                    )
                }
            }
        }
        
        return formatDescription
    }
    
    private func processH264NAL(_ data: Data) {
        guard let nalType = VideoFormatHelper.parseH264NALType(data) else { return }
        
        switch nalType {
        case .sps:
            spsData = data
        case .pps:
            ppsData = data
        default:
            break
        }
    }
    
    private func processHEVCNAL(_ data: Data) {
        guard let nalType = VideoFormatHelper.parseHEVCNALType(data) else { return }
        
        switch nalType {
        case .vps:
            vpsData = data
        case .sps:
            spsData = data
        case .pps:
            ppsData = data
        default:
            break
        }
    }
    
    /// Extract NAL units from stream data by finding start codes
    private func extractNALUnits(from data: Data) -> [Data] {
        var nalUnits: [Data] = []
        var currentPos = 0
        
        // Start code pattern: 0x00 0x00 0x00 0x01 or 0x00 0x00 0x01
        while currentPos < data.count - 3 {
            // Look for 4-byte start code
            if data[currentPos] == 0x00 &&
               data[currentPos + 1] == 0x00 &&
               data[currentPos + 2] == 0x00 &&
               data[currentPos + 3] == 0x01 {
                
                // Find next start code
                var nextPos = currentPos + 4
                var found = false
                
                while nextPos < data.count - 3 {
                    if data[nextPos] == 0x00 &&
                       data[nextPos + 1] == 0x00 {
                        // Could be start of next NAL
                        if (nextPos + 2 < data.count && data[nextPos + 2] == 0x01) ||
                           (nextPos + 3 < data.count && data[nextPos + 2] == 0x00 && data[nextPos + 3] == 0x01) {
                            found = true
                            break
                        }
                    }
                    nextPos += 1
                }
                
                if !found {
                    nextPos = data.count
                }
                
                // Extract NAL unit (without start code)
                let nalUnit = data.subdata(in: (currentPos + 4)..<nextPos)
                nalUnits.append(nalUnit)
                
                currentPos = nextPos
            } else {
                currentPos += 1
            }
        }
        
        return nalUnits
    }
}
