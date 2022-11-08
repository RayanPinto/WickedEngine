#include "globals.hlsli"

#define ASPM_HLSL
#include "compressonator/bcn_common_kernel.h"

static const uint region_count = 4;

PUSHCONSTANT(push, TerrainVirtualTexturePush);

struct Terrain
{
	ShaderMaterial materials[region_count];
};
ConstantBuffer<Terrain> terrain : register(b0);

#if !defined(UPDATE_NORMALMAP) && !defined(UPDATE_SURFACEMAP)
#define UPDATE_BASECOLORMAP
RWTexture2D<uint2> bindless_rwtextures_uint2[] : register(space19);
#else
RWTexture2D<uint4> bindless_rwtextures_uint4[] : register(space19);
#endif // UPDATE_NORMALMAP

static const uint2 block_offsets[BLOCK_SIZE_4X4] = {
	uint2(0, 0), uint2(1, 0), uint2(2, 0), uint2(3, 0),
	uint2(0, 1), uint2(1, 1), uint2(2, 1), uint2(3, 1),
	uint2(0, 2), uint2(1, 2), uint2(2, 2), uint2(3, 2),
	uint2(0, 3), uint2(1, 3), uint2(2, 3), uint2(3, 3),
};

#undef WICKED_ENGINE_DEFAULT_ROOTSIGNATURE // don't use auto root signature!
[RootSignature(
	"RootConstants(num32BitConstants=8, b999), "
	"CBV(b0), "
	"DescriptorTable( "
		"SRV(t0, space = 2, offset = 0, numDescriptors = unbounded, flags = DESCRIPTORS_VOLATILE | DATA_VOLATILE),"
		"UAV(u0, space = 19, offset = 0, numDescriptors = unbounded, flags = DESCRIPTORS_VOLATILE | DATA_VOLATILE)"
	"), "
	"StaticSampler(s100, addressU = TEXTURE_ADDRESS_CLAMP, addressV = TEXTURE_ADDRESS_CLAMP, addressW = TEXTURE_ADDRESS_CLAMP, filter = FILTER_MIN_MAG_MIP_LINEAR),"
	"StaticSampler(s101, addressU = TEXTURE_ADDRESS_WRAP, addressV = TEXTURE_ADDRESS_WRAP, addressW = TEXTURE_ADDRESS_WRAP, filter = FILTER_MIN_MAG_MIP_LINEAR),"
)]
[numthreads(8, 8, 1)]
void main(uint3 DTid : SV_DispatchThreadID)
{
	if (DTid.x >= push.write_size.x || DTid.y >= push.write_size.y)
		return;

	Texture2D<float4> region_weights_texture = bindless_textures[push.region_weights_textureRO];

#ifdef UPDATE_BASECOLORMAP
	RWTexture2D<uint2> output = bindless_rwtextures_uint2[push.output_textureRW];
	float3 block_rgb[BLOCK_SIZE_4X4];
#endif // UPDATE_BASECOLORMAP

#ifdef UPDATE_NORMALMAP
	RWTexture2D<uint4> output = bindless_rwtextures_uint4[push.output_textureRW];
	float block_x[BLOCK_SIZE_4X4];
	float block_y[BLOCK_SIZE_4X4];
#endif // UPDATE_NORMALMAP

#ifdef UPDATE_SURFACEMAP
	RWTexture2D<uint4> output = bindless_rwtextures_uint4[push.output_textureRW];
	float3 block_rgb[BLOCK_SIZE_4X4];
	float block_a[BLOCK_SIZE_4X4];
#endif // UPDATE_SURFACEMAP

	for(uint o = 0; o < BLOCK_SIZE_4X4; ++o)
	{
		const uint2 block_offset = block_offsets[o];
		const uint2 pixel = push.offset + DTid.xy * 4 + block_offset;
		const float2 uv = (pixel.xy + 0.5f) * push.resolution_rcp;

		float4 region_weights = region_weights_texture.SampleLevel(sampler_linear_clamp, uv, 0);

		float weight_sum = 0;
		float4 total_color = 0;
		for (uint i = 0; i < region_count; ++i)
		{
			float weight = region_weights[i];

			ShaderMaterial material = terrain.materials[i];

#ifdef UPDATE_BASECOLORMAP
			float4 baseColor = material.baseColor;
			[branch]
			if (material.textures[BASECOLORMAP].IsValid())
			{
				Texture2D tex = bindless_textures[material.textures[BASECOLORMAP].texture_descriptor];
				float2 dim = 0;
				tex.GetDimensions(dim.x, dim.y);
				float2 diff = dim * push.resolution_rcp;
				float lod = log2(max(diff.x, diff.y));
				float2 overscale = lod < 0 ? diff : 1;
				float4 baseColorMap = tex.SampleLevel(sampler_linear_wrap, uv / overscale, lod);
				baseColor *= baseColorMap;
			}
			total_color += baseColor * weight;
#endif // UPDATE_BASECOLORMAP

#ifdef UPDATE_NORMALMAP
			float2 normal = float2(0.5, 0.5);
			[branch]
			if (material.textures[NORMALMAP].IsValid())
			{
				Texture2D tex = bindless_textures[material.textures[NORMALMAP].texture_descriptor];
				float2 dim = 0;
				tex.GetDimensions(dim.x, dim.y);
				float2 diff = dim * push.resolution_rcp;
				float lod = log2(max(diff.x, diff.y));
				float2 overscale = lod < 0 ? diff : 1;
				float2 normalMap = tex.SampleLevel(sampler_linear_wrap, uv / overscale, lod).rg;
				normal = normalMap;
			}
			total_color += float4(normal.rg, 1, 1) * weight;
#endif // UPDATE_NORMALMAP

#ifdef UPDATE_SURFACEMAP
			float4 surface = float4(1, material.roughness, material.metalness, material.reflectance);
			[branch]
			if (material.textures[SURFACEMAP].IsValid())
			{
				Texture2D tex = bindless_textures[material.textures[SURFACEMAP].texture_descriptor];
				float2 dim = 0;
				tex.GetDimensions(dim.x, dim.y);
				float2 diff = dim * push.resolution_rcp;
				float lod = log2(max(diff.x, diff.y));
				float2 overscale = lod < 0 ? diff : 1;
				float4 surfaceMap = tex.SampleLevel(sampler_linear_wrap, uv / overscale, lod);
				surface *= surfaceMap;
			}
			total_color += surface * weight;
#endif // UPDATE_SURFACEMAP

			weight_sum += weight;
		}
		total_color /= weight_sum;

		const uint idx = block_offset.x + block_offset.y * 4;

#ifdef UPDATE_BASECOLORMAP
		block_rgb[idx] = total_color.rgb;
#endif // UPDATE_BASECOLORMAP

#ifdef UPDATE_NORMALMAP
		block_x[idx] = total_color.r;
		block_y[idx] = total_color.g;
#endif // UPDATE_NORMALMAP

#ifdef UPDATE_SURFACEMAP
		block_rgb[idx] = total_color.rgb;
		block_a[idx] = total_color.a;
#endif // UPDATE_SURFACEMAP
	}

	const uint2 write_coord = push.offset / 4 + DTid.xy;

#ifdef UPDATE_BASECOLORMAP
	output[write_coord] = CompressBlockBC1_UNORM(block_rgb, CMP_QUALITY0, /*isSRGB =*/ true);
#endif // UPDATE_BASECOLORMAP

#ifdef UPDATE_NORMALMAP
	output[write_coord] = CompressBlockBC5_UNORM(block_x, block_y, CMP_QUALITY0);
#endif // UPDATE_NORMALMAP

#ifdef UPDATE_SURFACEMAP
	output[write_coord] = CompressBlockBC3_UNORM(block_rgb, block_a, CMP_QUALITY2, /*isSRGB =*/ false);
#endif // UPDATE_SURFACEMAP
}
