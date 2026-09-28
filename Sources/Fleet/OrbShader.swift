import Metal
import MetalKit
import SwiftUI

/// Jarvis's orb: VoiceOrbs' "Siri Sheet" (github.com/amunozdev/voiceorbs, MIT, Alexis Munoz),
/// ported from WebGL to Metal. A glass ball with light sheets inside; while Jarvis speaks, his
/// level drives the sheets, the rim and halo, and the ball's size.
enum OrbShader {
    /// One row of the original's state table; the live values glide between rows.
    struct Params {
        var speed, warp, ridge, sharp, zoom, exposure, mute, glow, rim, hear, voice, fade: Float

        static let idle = Params(speed: 0.3, warp: 0.52, ridge: 0.48, sharp: 0.9, zoom: 0.94, exposure: 0.68, mute: 0.4,
                                 glow: 0.12, rim: 0.55, hear: 0, voice: 0, fade: 1)
        static let connecting = Params(speed: 0.5, warp: 0.78, ridge: 0.72, sharp: 0.95, zoom: 0.97, exposure: 0.84, mute: 0.16,
                                       glow: 0.22, rim: 0.7, hear: 0, voice: 0, fade: 1)
        /// The original's "speaking" row, with its "listening" reaction on: Marius wanted the
        /// rim and halo to follow the voice too.
        static let speaking = Params(speed: 0.78, warp: 0.72, ridge: 0.9, sharp: 1, zoom: 1, exposure: 0.96, mute: 0,
                                     glow: 0.34, rim: 0.8, hear: 1, voice: 1, fade: 1)
        static let disabled = Params(speed: 0, warp: 0.42, ridge: 0.36, sharp: 0.88, zoom: 0.93, exposure: 0.42, mute: 0.92,
                                     glow: 0, rim: 0.35, hear: 0, voice: 0, fade: 0.62)

        func approach(_ t: Params, _ k: Float) -> Params {
            func m(_ a: Float, _ b: Float) -> Float { a + (b - a) * k }
            return Params(speed: m(speed, t.speed), warp: m(warp, t.warp), ridge: m(ridge, t.ridge), sharp: m(sharp, t.sharp),
                          zoom: m(zoom, t.zoom), exposure: m(exposure, t.exposure), mute: m(mute, t.mute), glow: m(glow, t.glow),
                          rim: m(rim, t.rim), hear: m(hear, t.hear), voice: m(voice, t.voice), fade: m(fade, t.fade))
        }
    }

    private typealias RGB = SIMD3<Float>
    private static let from = RGB(0x82, 0xf4, 0xff), to = RGB(0x8e, 0x6c, 0xff)

    /// The fragment shader's `U`, flattened: twelve floats, then eight colours as float4.
    static func uniforms(_ p: Params, level: Float, phase: Float, pixels: Float) -> [Float] {
        func mix(_ a: RGB, _ b: RGB, _ t: Float) -> RGB { a + (b - a) * t }
        func mute(_ c: RGB) -> RGB { let l = c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722; return mix(c, RGB(l, l, l), p.mute) }
        func hue(_ c: RGB, _ deg: Float) -> RGB {
            let a = deg * .pi / 180, co = cos(a), si = sin(a), k: Float = 1 / 3, q = sqrt(k)
            let m0 = co + (1 - co) * k, m1 = k * (1 - co) - q * si, m2 = k * (1 - co) + q * si
            let r = RGB(c.x * m0 + c.y * m1 + c.z * m2, c.x * m2 + c.y * m0 + c.z * m1, c.x * m1 + c.y * m2 + c.z * m0)
            return simd_clamp(r, RGB(repeating: 0), RGB(repeating: 255))
        }
        let a = mute(from), b = mute(to)
        let c = mute(hue(mix(from, to, 0.35), -38)), d = mute(hue(mix(from, to, 0.65), 42))
        let mid = mix(a, b, 0.5), white = RGB(repeating: 255)
        let palette = [a, b, c, d, mix(mid, white, 0.82), mix(a, white, 0.15), mix(d, white, 0.1), mid]
        let voice = p.voice * level
        let warp: Float = p.warp * 3.2 + 0.85 * voice
        let ridge: Float = p.ridge + 0.35 * voice + 0.25 * p.hear * level
        let exposure: Float = p.exposure * 1.9 * (1 + 0.12 * voice + 0.1 * p.hear * level)
        let head: [Float] = [pixels, phase, level, warp, ridge, p.sharp * 2.2, p.zoom, exposure, p.glow * 0.45, p.rim, p.hear, p.fade]
        return head + palette.flatMap { (v: RGB) -> [Float] in [v.x / 255, v.y / 255, v.z / 255, 0] }
    }

    static let device = MTLCreateSystemDefaultDevice()
    private static let queue = device?.makeCommandQueue()
    private static let pipeline: MTLRenderPipelineState? = {
        guard let device, let lib = try? device.makeLibrary(source: source, options: nil) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "vmain")
        d.fragmentFunction = lib.makeFunction(name: "fmain")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: d)
    }()

    static func encode(_ uniforms: [Float], into pass: MTLRenderPassDescriptor, buffer: MTLCommandBuffer) {
        guard let pipeline, let enc = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = uniforms
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: u.count * MemoryLayout<Float>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private static func pass(_ texture: MTLTexture) -> MTLRenderPassDescriptor {
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = texture
        p.colorAttachments[0].loadAction = .clear
        p.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        p.colorAttachments[0].storeAction = .store
        return p
    }

    /// One frame on a texture read back, for the offscreen renders: a Metal layer is not
    /// captured by `cacheDisplay`.
    static func image(_ uniforms: [Float], pixels: Int) -> CGImage? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: pixels, height: pixels, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let texture = device?.makeTexture(descriptor: td), let buffer = queue?.makeCommandBuffer() else { return nil }
        encode(uniforms, into: pass(texture), buffer: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
        texture.getBytes(&bytes, bytesPerRow: pixels * 4, from: MTLRegionMake2D(0, 0, pixels, pixels), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    static let source = """
#include <metal_stdlib>
using namespace metal;

struct U { float size, phase, level, warp, ridge, sharp, zoom, exposure, glow, rim, hear, fade;
           float4 colA, colB, colC, colD, hi, cool, warm, glowCol; };

vertex float4 vmain(uint id [[vertex_id]]) {
    float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    return float4(p[id], 0, 1);
}

constant float SOFT = 0.005;

float hash(float2 p) { p = fract(p * float2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), f.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), f.x), f.y);
}
float fbm(float2 p) {
    float s = 0, a = 0.5;
    for (int i = 0; i < 4; i++) { s += a * noise(p); p = float2x2(float2(0.8, 0.6), float2(-0.6, 0.8)) * p * 2.03; a *= 0.5; }
    return s / 0.9375;
}
float2 band(float2 q, float drift, float offset, float amp, float mainY, float env, float soft) {
    float y = amp * env * sin(q.x + drift + offset);
    float d = abs(q.y - y);
    float line = 0.018 / (sqrt(d * d + soft * soft) + 0.026);
    float bd = max(0.0, max(q.y - max(mainY, y), min(mainY, y) - q.y));
    return float2(line, 0.014 / (bd * bd * 5.0 + 0.06));
}
float3 sheet(float2 p, float t, constant U &u) {
    float2 q = p / (0.74 + u.zoom * 0.34);
    float2 w = float2(fbm(q * 1.1 + float2(0, t * 0.09)), fbm(q * 1.1 + float2(7.7, -t * 0.07))) - 0.5;
    q += u.warp * 0.075 * w;
    float envB = cos(1.57079633 * min(abs(0.9 * q.x), 1.0));
    float env = envB * envB;
    float low = 0.5 + 0.5 * cos(t * 0.37), mid = 0.5 + 0.5 * sin(t * 0.51 + 1.2), high = 0.5 + 0.5 * cos(t * 0.73 + 2.1);
    float drift = t * 2.4;
    float mainAmp = 0.1 + u.ridge * 0.17 + low * 0.018;
    float bandAmp = mainAmp + mid * 0.025 + high * 0.018;
    float mainY = mainAmp * env * sin(q.x * 1.1 + drift);
    float sep = 1.85 + u.warp * 0.12 + mid * 0.28;
    float soft = 0.03 / max(u.sharp, 0.2) + mid * 0.006;
    float2 b0 = band(q, drift, -sep, bandAmp, mainY, env, soft), b1 = band(q, drift, -sep * 0.34, bandAmp, mainY, env, soft);
    float2 b2 = band(q, drift, sep * 0.34, bandAmp, mainY, env, soft), b3 = band(q, drift, sep, bandAmp, mainY, env, soft);
    float w0 = b0.x + b0.y, w1 = b1.x + b1.y, w2 = b2.x + b2.y, w3 = b3.x + b3.y;
    float total = w0 + w1 + w2 + w3;
    float d0 = w0 * w0, d1 = w1 * w1, d2 = w2 * w2, d3 = w3 * w3;
    float3 spectral = (u.colA.rgb * d0 + u.colC.rgb * d1 + u.colB.rgb * d2 + u.colD.rgb * d3) / max(d0 + d1 + d2 + d3, 0.0001);
    float energy = (1.0 - exp(-max(total - 0.12, 0.0) * 0.75)) * env;
    float md = abs(q.y - mainY);
    float core = exp(-md * md / (0.0028 / max(u.sharp, 0.2))) * env;
    float haze = fbm(q * 1.6 + float2(t * 0.05, -t * 0.03));
    float3 atmos = mix(u.colD.rgb, u.colB.rgb, smoothstep(-0.7, 0.7, q.y)) * (0.012 + 0.022 * haze);
    atmos += mix(u.colA.rgb, u.colC.rgb, haze) * 0.035 * exp(-q.y * q.y * 7.0) * haze;
    float3 col = atmos + spectral * energy * 1.14;
    col += u.hi.rgb * core * (0.2 + 0.1 * low);
    col = col / (1.0 + col * 0.18);
    col = mix(col, u.hi.rgb, 0.06 * smoothstep(0.15, 1.15, dot(p, float2(-0.32, 0.78))));
    col *= 1.0 - 0.3 * smoothstep(-0.1, 1.2, dot(p, float2(0.45, -0.62)));
    return col;
}
float profile(float t) { float d = clamp(t, 0.0, 1.0); return 1.0 - sqrt(max(1.0 - (1.0 - d) * (1.0 - d), 0.0)); }
float lobe(float2 n, float2 dir, float cut, float power) { return pow(clamp((dot(n, dir) - cut) / max(1.0 - cut, 0.001), 0.0, 1.0), power); }
float3 over(float3 dst, float3 src, float a) { float k = clamp(a, 0.0, 1.0); return src * k + dst * (1.0 - k); }

fragment float4 fmain(float4 pos [[position]], constant U &u [[buffer(0)]]) {
    float2 frag = float2(pos.x, u.size - pos.y);
    float2 uv = (frag * 2.0 - u.size) / u.size;
    float r = length(uv);
    float ang = atan2(uv.y, uv.x);
    float t = u.phase;
    float contour = u.hear * u.level * (0.011 * sin(ang * 3.0 + t * 1.9) + 0.006 * sin(ang * 5.0 - t * 1.3 + 1.7));
    float rad = 0.8 * (1.0 + 0.1 * u.hear * u.level) * (1.0 + contour);
    float3 glowCol = u.glowCol.rgb * (0.6 + 0.4 * u.hear * u.level);
    float glowAmt = u.glow * (1.0 + 0.9 * u.hear * u.level);
    if (r > rad * (1.01 + SOFT)) {
        float3 halo = clamp(glowCol * glowAmt * exp(-(r - rad) * 11.0) * (1.0 - smoothstep(rad, 0.995, r)), 0.0, 1.0);
        return float4(halo, max(halo.r, max(halo.g, halo.b))) * u.fade;
    }
    float2 p = uv / rad;
    float pd = length(p);
    float2 n = pd > 0.0001 ? p / pd : float2(0);
    float edge = max(1.0 - pd, 0.0);
    float prof = pow(profile(edge / 0.3), 0.68);
    float2 rp = p - n * prof * 0.5;
    float3 fcol;
    if (prof > 0.002) {
        float split = 0.12 * prof;
        fcol = float3(sheet(rp - n * split, t, u).r, sheet(rp, t, u).g, sheet(rp + n * split, t, u).b);
    } else {
        fcol = sheet(p, t, u);
    }
    float lum = dot(fcol, float3(0.213, 0.715, 0.072));
    float3 col = clamp(float3(lum) + (fcol - float3(lum)) * 1.18, 0.0, 1.0);
    float rimReact = u.rim * (1.0 + 0.45 * u.hear * u.level);
    float surfW = 0.035 + 0.03 * u.hear * u.level;
    float optical = pow(1.0 - smoothstep(0.0, surfW, edge), 1.8);
    col = over(col, mix(u.colA.rgb, u.hi.rgb, 0.5) * 0.35, optical * 0.1 * rimReact);
    float coolS = lobe(n, normalize(float2(0.84, 0.54)), 0.05, 1.6);
    float warmS = lobe(n, normalize(float2(-0.62, -0.78)), 0.05, 1.8);
    float disp = optical * 0.5 * rimReact;
    col = over(col, u.cool.rgb, disp * coolS);
    col = over(col, u.warm.rgb, disp * warmS);
    col *= 1.0 - optical * 0.12 * (0.15 + 0.85 * max(dot(n, float2(0.45, -0.89)), 0.0));
    float key = optical * lobe(n, normalize(float2(-0.68, 0.73)), 0.2, 2.8) * 0.6 * rimReact;
    float fillL = optical * lobe(n, normalize(float2(0.74, -0.67)), 0.4, 3.6) * 0.4 * rimReact;
    col = over(col, mix(u.hi.rgb, float3(1.0), 0.35), key);
    col = over(col, mix(u.colC.rgb, u.hi.rgb, 0.55), fillL);
    col *= 1.0 - 0.4 * smoothstep(0.95, 1.0, pd);
    col += mix(u.colA.rgb, u.colB.rgb, 0.3 + 0.3 * sin(ang + t * 0.6)) * optical * 0.3 * u.hear * u.level;
    float2 sp = p - float2(-0.38, 0.46);
    col += u.hi.rgb * exp(-dot(sp, sp) * 22.0) * 0.07 * u.rim;
    float ballA = 1.0 - smoothstep(0.99 - SOFT, 1.01 + SOFT, pd);
    col = clamp(col * max(u.exposure, 0.0), 0.0, 1.0) * ballA;
    float outside = smoothstep(rad - SOFT, rad + SOFT, r);
    col += glowCol * glowAmt * exp(-max(r - rad, 0.0) * 11.0) * (1.0 - smoothstep(rad, 0.995, r)) * outside;
    col = clamp(col, 0.0, 1.0);
    float a = clamp(max(ballA, max(col.r, max(col.g, col.b))), 0.0, 1.0);
    return float4(col, a) * u.fade;
}
"""
}
