#include <metal_stdlib>
using namespace metal;

// downscale screenshot for the model
kernel void downscale(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    float4 color = src.read(gid * 2);
    dst.write(color, gid);
}
