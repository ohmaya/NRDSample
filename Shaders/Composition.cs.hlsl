/*
Copyright (c) 2022, NVIDIA CORPORATION. All rights reserved.

NVIDIA CORPORATION and its licensors retain all intellectual property
and proprietary rights in and to this software, related documentation
and any modifications thereto. Any use, reproduction, disclosure or
distribution of this software and related documentation without an express
license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "Include/Shared.hlsli"

// Inputs
NRI_RESOURCE( Texture2D<float>, gIn_ViewZ, t, 0, 1 );
NRI_RESOURCE( Texture2D<float4>, gIn_Normal_Roughness, t, 1, 1 );
NRI_RESOURCE( Texture2D<float4>, gIn_BaseColor_Metalness, t, 2, 1 );
NRI_RESOURCE( Texture2D<float3>, gIn_DirectLighting, t, 3, 1 );
NRI_RESOURCE( Texture2D<float3>, gIn_Ambient, t, 4, 1 );
NRI_RESOURCE( Texture2D<float4>, gIn_Diff, t, 5, 1 );
NRI_RESOURCE( Texture2D<float4>, gIn_Spec, t, 6, 1 );
#if( NRD_MODE == SH )
    NRI_RESOURCE( Texture2D<float4>, gIn_DiffSh, t, 7, 1 );
    NRI_RESOURCE( Texture2D<float4>, gIn_SpecSh, t, 8, 1 );
#endif

// Outputs
NRI_RESOURCE( RWTexture2D<float4>, gOut_ComposedDiff, u, 0, 1 );
NRI_RESOURCE( RWTexture2D<float4>, gOut_ComposedSpec, u, 1, 1 );

[numthreads( 16, 16, 1)]
void main( int2 pixelPos : SV_DispatchThreadId )
{
    // Do not generate NANs for unused threads
    if( pixelPos.x >= gRectSize.x || pixelPos.y >= gRectSize.y )
        return;

    float2 pixelUv = float2( pixelPos + 0.5 ) * gInvRectSize;
    float2 sampleUv = pixelUv + gJitter;

    // ViewZ
    float viewZ = gIn_ViewZ[ pixelPos ];

    // Direct lighting with emission
    float3 Ldirect = gIn_DirectLighting[ pixelPos ];

    // Early out - sky
    float4 normalAndRoughness = NRD_FrontEnd_UnpackNormalAndRoughness( gIn_Normal_Roughness[ pixelPos ] );
    float3 N = normalAndRoughness.xyz;
    float roughness = normalAndRoughness.w;

    float z = abs( viewZ ) * NRD_FP16_VIEWZ_SCALE;
    z *= STL::Math::Sign( dot( N, gSunDirection ) );

    if( abs( viewZ ) == INF )
    {
        gOut_ComposedDiff[ pixelPos ] = float4( Ldirect * float( gOnScreen == SHOW_FINAL ), z );
        gOut_ComposedSpec[ pixelPos ] = float4( 0, 0, 0, z );

        return;
    }

    // G-buffer
    float3 albedo, Rf0;
    float4 baseColorMetalness = gIn_BaseColor_Metalness[ pixelPos ];
    STL::BRDF::ConvertBaseColorMetalnessToAlbedoRf0( baseColorMetalness.xyz, baseColorMetalness.w, albedo, Rf0 );

    float3 Xv = STL::Geometry::ReconstructViewPosition( sampleUv, gCameraFrustum, viewZ, gOrthoMode );
    float3 X = STL::Geometry::AffineTransform( gViewToWorld, Xv );
    float3 V = gOrthoMode == 0 ? normalize( gCameraOrigin - X ) : gViewDirection;

    // Sample NRD outputs
    float2 upsampleUv = pixelUv * gRectSize / gRenderSize;

    float4 diff = gIn_Diff.SampleLevel( gLinearSampler, upsampleUv, 0 );
    float4 spec = gIn_Spec.SampleLevel( gLinearSampler, upsampleUv, 0 );

    #if( NRD_MODE == SH )
        float4 diff1 = gIn_DiffSh.SampleLevel( gLinearSampler, upsampleUv, 0 );
        float4 spec1 = gIn_SpecSh.SampleLevel( gLinearSampler, upsampleUv, 0 );
    #endif

    // Decode SH mode outputs
    #if( NRD_MODE == SH )
        NRD_SG diffSg = REBLUR_BackEnd_UnpackSh( diff, diff1 );
        NRD_SG specSg = REBLUR_BackEnd_UnpackSh( spec, spec1 );

        if( gDenoiserType == RELAX )
        {
            diffSg = RELAX_BackEnd_UnpackSh( diff, diff1 );
            specSg = RELAX_BackEnd_UnpackSh( spec, spec1 );
        }

        if( gResolve )
        {
            // ( Optional ) replace "roughness" with "roughnessAA"
            roughness = NRD_SG_ExtractRoughnessAA( specSg );

            // Regain macro-details
            diff.xyz = NRD_SG_ResolveDiffuse( diffSg, N ) ; // or NRD_SH_ResolveDiffuse( sg, N )
            spec.xyz = NRD_SG_ResolveSpecular( specSg, N, V, roughness );

            // Regain micro-details & jittering // TODO: preload N and Z into SMEM
            float3 Ne = NRD_FrontEnd_UnpackNormalAndRoughness( gIn_Normal_Roughness[ pixelPos + int2(  1,  0 ) ] ).xyz;
            float3 Nw = NRD_FrontEnd_UnpackNormalAndRoughness( gIn_Normal_Roughness[ pixelPos + int2( -1,  0 ) ] ).xyz;
            float3 Nn = NRD_FrontEnd_UnpackNormalAndRoughness( gIn_Normal_Roughness[ pixelPos + int2(  0,  1 ) ] ).xyz;
            float3 Ns = NRD_FrontEnd_UnpackNormalAndRoughness( gIn_Normal_Roughness[ pixelPos + int2(  0, -1 ) ] ).xyz;

            float Ze = gIn_ViewZ[ pixelPos + int2(  1,  0 ) ];
            float Zw = gIn_ViewZ[ pixelPos + int2( -1,  0 ) ];
            float Zn = gIn_ViewZ[ pixelPos + int2(  0,  1 ) ];
            float Zs = gIn_ViewZ[ pixelPos + int2(  0, -1 ) ];

            float2 scale = NRD_SG_ReJitter( diffSg, specSg, Rf0, V, roughness, viewZ, Ze, Zw, Zn, Zs, N, Ne, Nw, Nn, Ns );

            diff.xyz *= scale.x;
            spec.xyz *= scale.y;
        }
        else
        {
            diff.xyz = NRD_SG_ExtractColor( diffSg );
            spec.xyz = NRD_SG_ExtractColor( specSg );
        }

        // ( Optional ) AO / SO
        diff.w = diffSg.normHitDist;
        spec.w = specSg.normHitDist;
    // Decode OCCLUSION mode outputs
    #elif( NRD_MODE == OCCLUSION )
        diff.w = diff.x;
        spec.w = spec.x;
    // Decode DIRECTIONAL_OCCLUSION mode outputs
    #elif( NRD_MODE == DIRECTIONAL_OCCLUSION )
        NRD_SG sg = REBLUR_BackEnd_UnpackDirectionalOcclusion( diff );

        if( gResolve )
        {
            // Regain macro-details
            diff.w = NRD_SG_ResolveDiffuse( sg, N ).x; // or NRD_SH_ResolveDiffuse( sg, N ).x

            // Regain micro-details // TODO: preload N and Z into SMEM
            float3 Ne = NRD_FrontEnd_UnpackNormalAndRoughness( gIn_Normal_Roughness[ pixelPos + int2( 1, 0 ) ] ).xyz;
            float3 Nw = NRD_FrontEnd_UnpackNormalAndRoughness( gIn_Normal_Roughness[ pixelPos + int2( -1, 0 ) ] ).xyz;
            float3 Nn = NRD_FrontEnd_UnpackNormalAndRoughness( gIn_Normal_Roughness[ pixelPos + int2( 0, 1 ) ] ).xyz;
            float3 Ns = NRD_FrontEnd_UnpackNormalAndRoughness( gIn_Normal_Roughness[ pixelPos + int2( 0, -1 ) ] ).xyz;

            float Ze = gIn_ViewZ[ pixelPos + int2( 1, 0 ) ];
            float Zw = gIn_ViewZ[ pixelPos + int2( -1, 0 ) ];
            float Zn = gIn_ViewZ[ pixelPos + int2( 0, 1 ) ];
            float Zs = gIn_ViewZ[ pixelPos + int2( 0, -1 ) ];

            float scale = NRD_SG_ReJitter( sg, sg, 0.0, V, 0.0, viewZ, Ze, Zw, Zn, Zs, N, Ne, Nw, Nn, Ns ).x;

            diff.w *= scale;
        }
        else
            diff.w = NRD_SG_ExtractColor( sg ).x;
    // Decode NORMAL mode outputs
    #else
        if( gDenoiserType == RELAX )
        {
            diff = RELAX_BackEnd_UnpackRadiance( diff );
            spec = RELAX_BackEnd_UnpackRadiance( spec );
        }
        else
        {
            diff = REBLUR_BackEnd_UnpackRadianceAndNormHitDist( diff );
            spec = REBLUR_BackEnd_UnpackRadianceAndNormHitDist( spec );
        }
    #endif

    // ( Optional ) RELAX doesn't support AO / SO
    if( gDenoiserType == RELAX )
    {
        diff.w = 1.0 / STL::Math::Pi( 1.0 );
        spec.w = 1.0 / STL::Math::Pi( 1.0 );
    }

    diff.xyz *= gIndirectDiffuse;
    spec.xyz *= gIndirectSpecular;

    // Environment ( pre-integrated ) specular term
    float NoV = abs( dot( N, V ) );
    float3 Fenv = STL::BRDF::EnvironmentTerm_Rtg( Rf0, NoV, roughness );

    // Composition
    float3 diffDemod = ( 1.0 - Fenv ) * albedo * 0.99 + 0.01;
    float3 specDemod = Fenv * 0.99 + 0.01;

    float3 Ldiff = diff.xyz * ( gReference ? 1.0 : diffDemod );
    float3 Lspec = spec.xyz * ( gReference ? 1.0 : specDemod );

    // Ambient
    float3 ambient = gIn_Ambient.SampleLevel( gLinearSampler, float2( 0.5, 0.5 ), 0 );
    ambient *= exp2( AMBIENT_FADE * STL::Math::LengthSquared( Xv ) );
    ambient *= gAmbient;

    float specAmbientAmount = gDenoiserType == RELAX ? roughness : GetSpecMagicCurve( roughness );

    Ldiff += ambient * diff.w * ( 1.0 - Fenv ) * albedo;
    Lspec += ambient * spec.w * Fenv * specAmbientAmount;

    // IMPORTANT: we store diffuse and specular separately to be able to use reprojection trick.
    // Let's assume that direct lighting can always be reprojected as diffuse
    Ldiff += Ldirect;

    // Debug
    if( gOnScreen == SHOW_DENOISED_DIFFUSE )
        Ldiff = diff.xyz;
    else if( gOnScreen == SHOW_DENOISED_SPECULAR )
        Ldiff = spec.xyz;
    else if( gOnScreen == SHOW_AMBIENT_OCCLUSION )
        Ldiff = diff.w;
    else if( gOnScreen == SHOW_SPECULAR_OCCLUSION )
        Ldiff = spec.w;
    else if( gOnScreen == SHOW_BASE_COLOR )
        Ldiff = baseColorMetalness.xyz;
    else if( gOnScreen == SHOW_NORMAL )
        Ldiff = N * 0.5 + 0.5;
    else if( gOnScreen == SHOW_ROUGHNESS )
        Ldiff = roughness;
    else if( gOnScreen == SHOW_METALNESS )
        Ldiff = baseColorMetalness.w;
    else if( gOnScreen == SHOW_WORLD_UNITS )
        Ldiff = frac( X * gUnitToMetersMultiplier );
    else if( gOnScreen != SHOW_FINAL )
        Ldiff = gOnScreen == SHOW_MIP_SPECULAR ? spec.xyz : Ldirect.xyz;

    // Output
    gOut_ComposedDiff[ pixelPos ] = float4( Ldiff, z );
    gOut_ComposedSpec[ pixelPos ] = float4( Lspec, z );
}
