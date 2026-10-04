#include <metal_stdlib>
using namespace metal;
struct CaptureUniforms {
    float4x4 cameraToWorld;
    float4x4 worldToAcceptedCamera;
    float3x3 displayToImage;
    float4 intrinsics;
    float4 acceptedIntrinsics;
    float4 parameters;
};
kernel void captureFeedback(texture2d<float, access::sample> source [[texture(0)]],
                            texture2d<float, access::write> output [[texture(1)]],
                            texture2d<float, access::sample> depth [[texture(2)]],
                            texture2d<float, access::sample> accepted [[texture(3)]],
                            texture2d<float, access::sample> photographed [[texture(4)]],
                            constant CaptureUniforms &u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    float2 size = float2(output.get_width(), output.get_height());
    float2 uv = (float2(gid) + 0.5) / size;
    float4 color = source.sample(linearSampler, uv);
    if (u.parameters.x <= 0) { output.write(color, gid); return; }
    float2 imageUV = (u.displayToImage * float3(uv, 1)).xy;
    float d = depth.sample(nearestSampler, imageUV).r;
    if (!isfinite(d) || d <= 0.1 || any(imageUV < 0) || any(imageUV > 1)) {
        output.write(color, gid); return;
    }
    float2 pixel = imageUV * u.parameters.zw;
    float3 cameraPoint = float3((pixel.x - u.intrinsics.z) / u.intrinsics.x * d,
        -(pixel.y - u.intrinsics.w) / u.intrinsics.y * d, -d);
    float distance = length(cameraPoint);
    float outside = smoothstep(u.parameters.x, u.parameters.x + 0.045, distance);
    if (outside > 0) {
        float4 blurred = float4(0);
        constexpr float weights[5] = {1, 4, 6, 4, 1};
        for (int y = -2; y <= 2; y++) for (int x = -2; x <= 2; x++) {
            blurred += source.sample(linearSampler, uv + float2(x, y) * 3.0 / size) * weights[x + 2] * weights[y + 2];
        }
        blurred /= 256.0;
        float grey = dot(blurred.rgb, float3(0.2126, 0.7152, 0.0722));
        blurred.rgb = mix(blurred.rgb, float3(grey), 0.45) * 0.78;
        color = mix(color, blurred, outside);
    }
    if (distance <= u.parameters.x && u.parameters.y > 0.5) {
        float4 world = u.cameraToWorld * float4(cameraPoint, 1);
        float3 old = (u.worldToAcceptedCamera * world).xyz;
        float z = -old.z;
        float2 previousUV = float2(old.x, -old.y) / max(z, 0.001) * u.acceptedIntrinsics.xy + u.acceptedIntrinsics.zw;
        if (z > 0 && all(previousUV >= 0) && all(previousUV <= 1)) {
            float committedDepth = accepted.sample(nearestSampler, previousUV).r;
            if (committedDepth > 0 && abs(committedDepth - z) < 0.035 + z * 0.012) {
                float3 grid = abs(fract(world.xyz * 10.0 + 0.5) - 0.5);
                float line = 1.0 - smoothstep(0.012, 0.038, min(grid.x, min(grid.y, grid.z)));
                float edge = smoothstep(0.0, 0.018, u.parameters.x - distance);
                float photoDepth = photographed.sample(nearestSampler, previousUV).r;
                bool needsPhoto = u.parameters.y > 1.5 &&
                    !(photoDepth > 0 && abs(photoDepth - z) < 0.035 + z * 0.012);
                float3 ink = needsPhoto ? mix(float3(0.10, 0.42, 1.0), float3(0.4, 0.7, 1.0), line)
                    : mix(float3(0.04, 0.84, 0.66), float3(0.45, 1.0, 0.86), line);
                color.rgb = mix(color.rgb, ink, (0.40 + line * 0.16) * edge);
            }
        }
    }
    output.write(float4(color.rgb, 1), gid);
}
