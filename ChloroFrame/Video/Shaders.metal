//
//  Shaders.metal
//  ChloroFrame
//
//  Created by Aman Bhardwaj on 6/8/26.
//

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Simple vertex shader that creates a full-screen quad
vertex VertexOut vertexShader(uint vertexID [[vertex_id]]) {
    // Generate full-screen quad coordinates
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    
    float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// Fragment shader for BGRA texture (simple passthrough)
fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               texture2d<float> videoTexture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    return videoTexture.sample(textureSampler, in.texCoord);
}

// Fragment shader for NV12 (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) → RGB.
// Y plane: r8Unorm at texture(0). UV plane: rg8Unorm at texture(1), half resolution.
// BT.709 limited-range (studio swing) matrix — correct for VideoRange NV12 from VT.
fragment float4 fragmentShaderYUV(VertexOut in [[stage_in]],
                                  texture2d<float> yTexture  [[texture(0)]],
                                  texture2d<float> uvTexture [[texture(1)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);

    // Y: [16/255, 235/255] → remove bias; UV: [16/255, 240/255] → center at 0
    float  y  = yTexture.sample(s, in.texCoord).r  - 16.0  / 255.0;
    float2 uv = uvTexture.sample(s, in.texCoord).rg - 128.0 / 255.0;
    // uv.r = Cb (U), uv.g = Cr (V)

    // ITU-R BT.709 limited-range coefficients (1.16438 = 255/219 Y scaling)
    float r = clamp(1.16438 * y               + 1.79274 * uv.g, 0.0, 1.0);
    float g = clamp(1.16438 * y - 0.21325 * uv.r - 0.53291 * uv.g, 0.0, 1.0);
    float b = clamp(1.16438 * y + 2.11240 * uv.r,                   0.0, 1.0);

    return float4(r, g, b, 1.0);
}

// PQ (ST.2084) EOTF: nonlinear signal [0,1] → linear scene luminance [0,1] (1.0 = 10 000 nits).
static float pq_eotf(float Ep) {
    const float m1_inv = 16384.0 / 2610.0;   // 1/m1 = 6.2774...
    const float m2_inv =    32.0 / 2523.0;   // 1/m2 = 0.012683...
    const float c1     = 0.8359375;           // 107/128
    const float c2     = 18.8515625;          // 2413/128
    const float c3     = 18.6875;             // 2392/128
    float Em2  = pow(max(Ep, 0.0f), m2_inv);
    return pow(max(Em2 - c1, 0.0f) / (c2 - c3 * Em2), m1_inv);
}

// HDR10 fragment shader: P010 (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) → EDR linear RGB.
//
// P010 stores 10-bit samples MSB-aligned in 16-bit containers (6 LSBs zeroed).
// CVMetalTextureCache vends r16Unorm (Y) and rg16Unorm (UV).
// Metal r16Unorm normalises: float = uint16 / 65535  ≈  10bit_sample / 1023.984 ≈ 10bit / 1024.
//
// Limited-range (studio swing) for 10-bit:
//   Y :  64 = black, 940 = white  → scale = 1023/(940−64)
//   UV:  64 = min,  512 = neutral, 960 = max → subtract 512/1023 to centre at 0
//
// Output is linear-light EDR: 1.0 = SDR reference white (~100 nits).
// MTKView must use .rgba16Float and CAMetalLayer.wantsExtendedDynamicRangeContent = true.
fragment float4 fragmentShaderYUVHDR(VertexOut in [[stage_in]],
                                     texture2d<float> yTexture  [[texture(0)]],
                                     texture2d<float> uvTexture [[texture(1)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);

    float  y_raw  = yTexture.sample(s, in.texCoord).r;
    float2 uv_raw = uvTexture.sample(s, in.texCoord).rg;

    // De-quantise limited range → normalised PQ signal [0, 1]
    const float y_bias   =  64.0 / 1023.0;
    const float y_range  = (940.0 - 64.0) / 1023.0;
    const float uv_bias  =  64.0 / 1023.0;
    const float uv_range = (960.0 - 64.0) / 1023.0;
    const float uv_mid   = 512.0 / 1023.0;

    float  y  = clamp((y_raw  - y_bias)  / y_range,  0.0, 1.0);
    float  u  = clamp((uv_raw.r - uv_bias) / uv_range - 0.5, -0.5, 0.5);
    float  v  = clamp((uv_raw.g - uv_bias) / uv_range - 0.5, -0.5, 0.5);
    (void)uv_mid;   // suppresses unused warning; kept for documentation

    // BT.2020 YCbCr (full-range convention after normalisation) → linear-light RGB in PQ space.
    // Coefficients: kr=0.2627, kg=0.6780, kb=0.0593
    float r_pq = y               + 1.47460 * v;
    float g_pq = y - 0.16455 * u - 0.57135 * v;
    float b_pq = y + 1.88140 * u;

    // Apply PQ EOTF per channel → linear luminance in [0, 1] (1.0 = 10 000 nits).
    float3 linear = float3(pq_eotf(clamp(r_pq, 0.0, 1.0)),
                           pq_eotf(clamp(g_pq, 0.0, 1.0)),
                           pq_eotf(clamp(b_pq, 0.0, 1.0)));

    // Scale to EDR: divide by SDR reference white (100 nits / 10 000 nits = 0.01),
    // so EDR 1.0 = 100 nits, EDR 100.0 = 10 000 nits (display clips at its own peak).
    return float4(linear / 0.01, 1.0);
}
