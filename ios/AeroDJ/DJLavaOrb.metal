//
//  DJLavaOrb.metal
//  AeroDJ
//
//  The on-air lava-lamp orb's metaball mask. Adapted from SWMetaballs.metal
//  (ShipSwift, signerlabs/shipswift-skills, "cluster" style) by Nova for AeroDJ:
//  the palette, background and fountain style are removed; the shader returns a
//  premultiplied white mask so the orb is filled with the album art's own colours,
//  and drift time is integrated on the Swift side (`DJOrbMotion.phase`).
//
//  MIT License
//
//  Copyright (c) signerlabs / ShipSwift (https://github.com/signerlabs/shipswift-skills)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//
//  Entry point: `aeroDJOrbMetaballs`, used through SwiftUI `.colorEffect(...)`.
//  iOS 18+ in the app (the Swift side gates it and checks the function exists).
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float aeroOrbHash1(float x) {
    return fract(sin(x * 12.9898) * 43758.5453);
}

static float aeroOrbNoise1(float x) {
    float i = floor(x);
    float f = fract(x);
    float u = f * f * (3.0 - 2.0 * f);
    return mix(aeroOrbHash1(i), aeroOrbHash1(i + 1.0), u);
}

// Radial power-of-distance shape, 0..1, kept round on non-square frames.
// `zoom` > 1 makes each ball larger than in SWMetaballs (a full-screen background there,
// one orb in a card here).
static float aeroOrbBallShape(float2 uv, float2 c, float p, float2 aspectScale, float zoom) {
    float2 diff = (uv - c) * aspectScale / zoom;
    float s = 0.5 * length(diff);
    s = 1.0 - saturate(s);
    return pow(s, p);
}

[[ stitchable ]] half4 aeroDJOrbMetaballs(float2 position,
                                          half4  inColor,
                                          float4 boundingRect,
                                          float  phase,
                                          float  count,
                                          float  size) {
    float2 sz = boundingRect.zw;
    float2 uv = position / max(sz, float2(1.0));
    float minDim = max(min(sz.x, sz.y), 1.0);
    float2 aspectScale = sz / minDim;

    // Offset so the first frame is not a uniform start (as in SWMetaballs).
    float t = 0.2 * (phase + 2503.4);

    float countClamped = min(max(count, 1.0), 8.0);
    int countCeil = int(ceil(countClamped));
    float totalShape = 0.0;

    for (int i = 0; i < 8; i++) {
        if (i >= countCeil) break;
        float idxFract = float(i) / 20.0;
        float angle = 6.2831853 * idxFract;
        float spd = 1.0 - 0.2 * idxFract;
        float nx = aeroOrbNoise1(angle * 10.0 + float(i) + t * spd);
        float ny = aeroOrbNoise1(angle * 20.0 + float(i) - t * spd);
        // Kept nearer the centre than SWMetaballs (0.4 vs 0.9) so the blobs stay one orb
        // inside the frame rather than filling it.
        float2 pos = float2(0.5) + 1e-4 + 0.4 * (float2(nx, ny) - 0.5);

        float sizeFrac = 1.0;
        if (float(i) > floor(countClamped - 1.0)) {
            sizeFrac *= fract(countClamped);
        }
        float p = 45.0 - 30.0 * size * sizeFrac;
        float shape = aeroOrbBallShape(uv, pos, p, aspectScale, 3.2);
        shape *= pow(max(size, 1e-3), 0.2);
        totalShape += smoothstep(0.0, 1.0, shape);
    }

    float edge = max(fwidth(totalShape), 1e-3);
    float a = smoothstep(0.4, 0.4 + edge, totalShape);
    // Premultiplied white: the Swift side uses this as a mask over the art.
    return half4(half(a), half(a), half(a), half(a));
}
