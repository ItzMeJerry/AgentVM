//
//  TerminalShaders.metal
//  SwiftTerm's Metal shaders, with one change: dark text is blended the way
//  macOS blends it.
//
//  SwiftTerm's Metal renderer keeps every glyph in its atlas as white text and
//  tints it. White text's edges then match what macOS draws exactly; dark
//  text's don't. macOS draws a dark glyph's edges much lighter — measured
//  against CoreText, about the white glyph's coverage squared — so used as is,
//  the atlas made light-mode text heavy and hard-edged. Only
//  `terminal_text_fragment_gray` differs from SwiftTerm's file; everything
//  else is its own, so the renderer's buffers still fit.
//
//  SwiftTerm looks for the app's default Metal library before its own, so
//  Scripts/build-app.sh compiles this into AgentVM.app/Contents/Resources/
//  default.metallib. It also checks that SwiftTerm's Shaders.metal is still
//  the one this was copied from — SwiftTerm 1.20.0 — and stops the build if
//  not: an upgrade means copying its new file and making this change again.
//
//  AgentVM — https://github.com/ItzMeJerry/AgentVM
//  Copyright 2026 Jerry Lan
//  SPDX-License-Identifier: Apache-2.0
//
//  Adapted from SwiftTerm's Sources/SwiftTerm/Apple/Metal/Shaders.metal, under
//  its license:
//
//  Copyright (c) 2019-2026 Miguel de Icaza (https://github.com/migueldeicaza)
//  Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
//  Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
//  Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)
//
//  Permission is hereby granted, free of charge, to any person obtaining
//  a copy of this software and associated documentation files (the
//  "Software"), to deal in the Software without restriction, including
//  without limitation the rights to use, copy, modify, merge, publish,
//  distribute, sublicense, and/or sell copies of the Software, and to
//  permit persons to whom the Software is furnished to do so, subject to
//  the following conditions:
//
//  The above copyright notice and this permission notice shall be
//  included in all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//  MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
//  LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
//  OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
//  WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

#include <metal_stdlib>
using namespace metal;

struct GlyphVertex {
    float2 position;
    float2 texCoord;
    float4 color;
};

struct TextCell {
    float2 position;
    float2 size;
    float2 texOrigin;
    float2 texSize;
    float4 color;
};

struct ColorCell {
    float2 position;
    float2 size;
    float4 color;
};

struct GlyphOut {
    float4 position [[position]];
    float2 texCoord;
    float4 color;
};

constant float2 kQuadCorners[6] = {
    float2(0.0, 0.0),
    float2(1.0, 0.0),
    float2(0.0, 1.0),
    float2(1.0, 0.0),
    float2(1.0, 1.0),
    float2(0.0, 1.0),
};

vertex GlyphOut terminal_text_vertex(uint vid [[vertex_id]],
                                     const device GlyphVertex *vertices [[buffer(0)]],
                                     constant float2 &viewport [[buffer(1)]]) {
    GlyphVertex v = vertices[vid];
    float2 ndc = float2((v.position.x / viewport.x) * 2.0 - 1.0,
                        (v.position.y / viewport.y) * 2.0 - 1.0);
    GlyphOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.texCoord = v.texCoord;
    out.color = v.color;
    return out;
}

vertex GlyphOut terminal_cell_text_vertex(uint vid [[vertex_id]],
                                          const device TextCell *cells [[buffer(0)]],
                                          constant float2 &viewport [[buffer(1)]]) {
    uint cellIndex = vid / 6;
    uint cornerIndex = vid % 6;
    TextCell cell = cells[cellIndex];
    float2 corner = kQuadCorners[cornerIndex];
    float2 position = cell.position + cell.size * corner;
    float2 ndc = float2((position.x / viewport.x) * 2.0 - 1.0,
                        (position.y / viewport.y) * 2.0 - 1.0);
    GlyphOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.texCoord = cell.texOrigin + cell.texSize * corner;
    out.color = cell.color;
    return out;
}

fragment float4 terminal_text_fragment(GlyphOut in [[stage_in]],
                                       texture2d<float> atlas [[texture(0)]],
                                       sampler samp [[sampler(0)]]) {
    float4 tex = atlas.sample(samp, in.texCoord);
    return float4(tex.rgb * in.color.rgb, tex.a * in.color.a);
}

fragment float4 terminal_text_fragment_gray(GlyphOut in [[stage_in]],
                                            texture2d<float> atlas [[texture(0)]],
                                            sampler samp [[sampler(0)]]) {
    float coverage = atlas.sample(samp, in.texCoord).r;
    // AgentVM: dark text's edges as macOS draws them, about the white
    // glyph's coverage squared; light text keeps the atlas as it is, which
    // already matches. Colours in between, in proportion to their luminance.
    float luminance = dot(in.color.rgb, float3(0.2126, 0.7152, 0.0722));
    coverage = mix(coverage * coverage, coverage, luminance);
    return float4(in.color.rgb * coverage, in.color.a * coverage);
}

// AgentVM: present only in this copy, so the app can tell these are the
// shaders SwiftTerm loaded.
kernel void agentvm_terminal_shaders(uint index [[thread_position_in_grid]]) {}

struct ColorVertex {
    float2 position;
    float4 color;
};

struct ColorOut {
    float4 position [[position]];
    float4 color;
};

vertex ColorOut terminal_color_vertex(uint vid [[vertex_id]],
                                      const device ColorVertex *vertices [[buffer(0)]],
                                      constant float2 &viewport [[buffer(1)]]) {
    ColorVertex v = vertices[vid];
    float2 ndc = float2((v.position.x / viewport.x) * 2.0 - 1.0,
                        (v.position.y / viewport.y) * 2.0 - 1.0);
    ColorOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = v.color;
    return out;
}

vertex ColorOut terminal_cell_color_vertex(uint vid [[vertex_id]],
                                           const device ColorCell *cells [[buffer(0)]],
                                           constant float2 &viewport [[buffer(1)]]) {
    uint cellIndex = vid / 6;
    uint cornerIndex = vid % 6;
    ColorCell cell = cells[cellIndex];
    float2 corner = kQuadCorners[cornerIndex];
    float2 position = cell.position + cell.size * corner;
    float2 ndc = float2((position.x / viewport.x) * 2.0 - 1.0,
                        (position.y / viewport.y) * 2.0 - 1.0);
    ColorOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = cell.color;
    return out;
}

fragment float4 terminal_color_fragment(ColorOut in [[stage_in]]) {
    return in.color;
}
