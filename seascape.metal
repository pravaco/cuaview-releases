/*
 * "Seascape" by Alexander Alekseev aka TDM - 2014
 * Ported to Metal by Claude
 * License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License.
 */

#include <metal_stdlib>
using namespace metal;

// Vertex output structure
struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Uniforms passed from CPU
struct Uniforms {
    float time;
    float2 resolution;
    float2 mouse;
};

// Constants
constant int NUM_STEPS = 32;
constant float PI = 3.141592;
constant float EPSILON = 1e-3;

// Sea parameters
constant int ITER_GEOMETRY = 3;
constant int ITER_FRAGMENT = 5;
constant float SEA_HEIGHT = 0.6;
constant float SEA_CHOPPY = 4.0;
constant float SEA_SPEED = 0.8;
constant float SEA_FREQ = 0.16;
constant float3 SEA_BASE = float3(0.0, 0.09, 0.18);
constant float3 SEA_WATER_COLOR = float3(0.8, 0.9, 0.6) * 0.6;

// Math functions
float3x3 fromEuler(float3 ang) {
    float2 a1 = float2(sin(ang.x), cos(ang.x));
    float2 a2 = float2(sin(ang.y), cos(ang.y));
    float2 a3 = float2(sin(ang.z), cos(ang.z));
    float3x3 m;
    m[0] = float3(a1.y*a3.y + a1.x*a2.x*a3.x, a1.y*a2.x*a3.x + a3.y*a1.x, -a2.y*a3.x);
    m[1] = float3(-a2.y*a1.x, a1.y*a2.y, a2.x);
    m[2] = float3(a3.y*a1.x*a2.x + a1.y*a3.x, a1.x*a3.x - a1.y*a3.y*a2.x, a2.y*a3.y);
    return m;
}

float hash(float2 p) {
    float h = dot(p, float2(127.1, 311.7));
    return fract(sin(h) * 43758.5453123);
}

float noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return -1.0 + 2.0 * mix(
        mix(hash(i + float2(0.0, 0.0)), hash(i + float2(1.0, 0.0)), u.x),
        mix(hash(i + float2(0.0, 1.0)), hash(i + float2(1.0, 1.0)), u.x),
        u.y
    );
}

// Lighting
float diffuse(float3 n, float3 l, float p) {
    return pow(dot(n, l) * 0.4 + 0.6, p);
}

float specular(float3 n, float3 l, float3 e, float s) {
    float nrm = (s + 8.0) / (PI * 8.0);
    return pow(max(dot(reflect(e, n), l), 0.0), s) * nrm;
}

// Sky
float3 getSkyColor(float3 e) {
    float ey = (max(e.y, 0.0) * 0.8 + 0.2) * 0.8;
    return float3(pow(1.0 - ey, 2.0), 1.0 - ey, 0.6 + (1.0 - ey) * 0.4) * 1.1;
}

// Sea octave
float sea_octave(float2 uv, float choppy) {
    uv += noise(uv);
    float2 wv = 1.0 - abs(sin(uv));
    float2 swv = abs(cos(uv));
    wv = mix(wv, swv, wv);
    return pow(1.0 - pow(wv.x * wv.y, 0.65), choppy);
}

// Sea height map (low detail for raymarching)
float map(float3 p, float SEA_TIME) {
    float freq = SEA_FREQ;
    float amp = SEA_HEIGHT;
    float choppy = SEA_CHOPPY;
    float2 uv = p.xz;
    uv.x *= 0.75;

    // Octave matrix
    float2x2 octave_m = float2x2(1.6, 1.2, -1.2, 1.6);

    float d, h = 0.0;
    for (int i = 0; i < ITER_GEOMETRY; i++) {
        d = sea_octave((uv + SEA_TIME) * freq, choppy);
        d += sea_octave((uv - SEA_TIME) * freq, choppy);
        h += d * amp;
        uv = octave_m * uv;
        freq *= 1.9;
        amp *= 0.22;
        choppy = mix(choppy, 1.0, 0.2);
    }
    return p.y - h;
}

// Sea height map (high detail for normals)
float map_detailed(float3 p, float SEA_TIME) {
    float freq = SEA_FREQ;
    float amp = SEA_HEIGHT;
    float choppy = SEA_CHOPPY;
    float2 uv = p.xz;
    uv.x *= 0.75;

    float2x2 octave_m = float2x2(1.6, 1.2, -1.2, 1.6);

    float d, h = 0.0;
    for (int i = 0; i < ITER_FRAGMENT; i++) {
        d = sea_octave((uv + SEA_TIME) * freq, choppy);
        d += sea_octave((uv - SEA_TIME) * freq, choppy);
        h += d * amp;
        uv = octave_m * uv;
        freq *= 1.9;
        amp *= 0.22;
        choppy = mix(choppy, 1.0, 0.2);
    }
    return p.y - h;
}

// Sea color
float3 getSeaColor(float3 p, float3 n, float3 l, float3 eye, float3 dist) {
    float fresnel = clamp(1.0 - dot(n, -eye), 0.0, 1.0);
    fresnel = min(fresnel * fresnel * fresnel, 0.5);

    float3 reflected = getSkyColor(reflect(eye, n));
    float3 refracted = SEA_BASE + diffuse(n, l, 80.0) * SEA_WATER_COLOR * 0.12;

    float3 color = mix(refracted, reflected, fresnel);

    float atten = max(1.0 - dot(dist, dist) * 0.001, 0.0);
    color += SEA_WATER_COLOR * (p.y - SEA_HEIGHT) * 0.18 * atten;

    color += specular(n, l, eye, 600.0 * rsqrt(dot(dist, dist)));

    return color;
}

// Normal calculation
float3 getNormal(float3 p, float eps, float SEA_TIME) {
    float3 n;
    n.y = map_detailed(p, SEA_TIME);
    n.x = map_detailed(float3(p.x + eps, p.y, p.z), SEA_TIME) - n.y;
    n.z = map_detailed(float3(p.x, p.y, p.z + eps), SEA_TIME) - n.y;
    n.y = eps;
    return normalize(n);
}

// Height map tracing
float heightMapTracing(float3 ori, float3 dir, thread float3 &p, float SEA_TIME) {
    float tm = 0.0;
    float tx = 1000.0;
    float hx = map(ori + dir * tx, SEA_TIME);
    if (hx > 0.0) {
        p = ori + dir * tx;
        return tx;
    }
    float hm = map(ori, SEA_TIME);
    for (int i = 0; i < NUM_STEPS; i++) {
        float tmid = mix(tm, tx, hm / (hm - hx));
        p = ori + dir * tmid;
        float hmid = map(p, SEA_TIME);
        if (hmid < 0.0) {
            tx = tmid;
            hx = hmid;
        } else {
            tm = tmid;
            hm = hmid;
        }
        if (abs(hmid) < EPSILON) break;
    }
    return mix(tm, tx, hm / (hm - hx));
}

// Get pixel color
float3 getPixel(float2 coord, float2 resolution, float time) {
    float2 uv = coord / resolution;
    uv = uv * 2.0 - 1.0;
    uv.x *= resolution.x / resolution.y;

    float SEA_TIME = 1.0 + time * SEA_SPEED;
    float EPSILON_NRM = 0.1 / resolution.x;

    // Ray
    float3 ang = float3(sin(time * 3.0) * 0.1, sin(time) * 0.2 + 0.3, time);
    float3 ori = float3(0.0, 3.5, time * 5.0);
    float3 dir = normalize(float3(uv.xy, -2.0));
    dir.z += length(uv) * 0.14;
    dir = normalize(dir) * fromEuler(ang);

    // Tracing
    float3 p;
    heightMapTracing(ori, dir, p, SEA_TIME);
    float3 dist = p - ori;
    float3 n = getNormal(p, dot(dist, dist) * EPSILON_NRM, SEA_TIME);
    float3 light = normalize(float3(0.0, 1.0, 0.8));

    // Color
    return mix(
        getSkyColor(dir),
        getSeaColor(p, n, light, dir, dist),
        pow(smoothstep(0.0, -0.02, dir.y), 0.2)
    );
}

// Vertex shader - fullscreen quad
vertex VertexOut vertexShader(uint vertexID [[vertex_id]]) {
    VertexOut out;

    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };

    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = positions[vertexID] * 0.5 + 0.5;
    // Don't flip Y - Metal's coordinate system works correctly for this shader

    return out;
}

// Fragment shader
fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               constant Uniforms& uniforms [[buffer(0)]]) {
    float2 fragCoord = in.uv * uniforms.resolution;
    float time = uniforms.time * 0.3 + uniforms.mouse.x * 0.01;

    float3 color = getPixel(fragCoord, uniforms.resolution, time);

    // Gamma correction
    return float4(pow(color, float3(0.65)), 1.0);
}
