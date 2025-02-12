// Copyright (c) 2023 Dan Fu, Hermann Kumbong

// Simple 1D depthwise convolution implementation with dilation and stride = 1

#include <torch/extension.h>
#include <stdio.h>
#include <cuda.h>
#include <cuda_runtime.h>
#include <algorithm>
#include <vector>
#include <cuda_fp16.h>

//For max perf, tune for your GPU and batch size, and datatype etc
const uint BX = 512;
const uint BY = 1;
const uint BZ = 1;

const uint TILE_SIZE_Y = 4;
const uint TILE_SIZE_X = 2;

__forceinline__ __device__ float2 __hfma2(const float2 a, const float2 b, const float2 c)
{
    return make_float2(a.x * b.x + c.x, a.y * b.y + c.y);
}

// Trick to do padding in place without actually creating a new tensor
__forceinline__ __device__ __half2 get_u(const __half2 *__restrict__ u, uint L_eff, uint l, uint p, uint b, uint k, uint d, uint L, uint D, uint K)
{
    return l + k < p || l + k > L_eff - (p + 1) ? __float2half2_rn(0.0f) : u[b * L * D + (l + k - p) * D + d];
}


__forceinline__ __device__ __nv_bfloat162 get_u(const __nv_bfloat162 *__restrict__ u, uint L_eff, uint l, uint p, uint b, uint k, uint d, uint L, uint D, uint K)
{
    return l + k < p || l + k > L_eff - (p + 1) ? __float2bfloat162_rn(0.0f) : u[b * L * D + (l + k - p) * D + d];
}
 
__forceinline__ __device__ float2 get_u(const float2 *__restrict__ u, uint L_eff, uint l, uint p, uint b, uint k, uint d, uint L, uint D, uint K)
{
    return l + k < p || l + k > L_eff - (p + 1) ? make_float2(0.0f, 0.0f) : u[b * L * D + (l + k - p) * D + d];
}


//manually unrolling loop for k = 3 leads to good perf, can easily extend for other values of k if need be
template<typename T>
__forceinline__ __device__ T _conv1d_k_3(const T* u, const T* weights, const T* bias, T* out, uint padding, uint b, uint l, uint d, uint t, uint L, uint D, uint K, uint L_eff, uint L_out)
{

    T temp_sum = bias[d];

    temp_sum = __hfma2(get_u(u, L_eff, l + t, padding, b, 0, d, L, D, K), weights[0 * D + d], temp_sum);
    temp_sum = __hfma2(get_u(u, L_eff, l + t, padding, b, 1, d, L, D, K), weights[1 * D + d], temp_sum);
    out[b * D * L_out  + (l + t) * D + d] = __hfma2(get_u(u, L_eff, l + t, padding, b, 2, d, L, D, K), weights[2 * D + d], temp_sum);

}

template<typename T>
__global__ void conv1d_kernel_k_3(
    const T *__restrict__ u,
    const T *__restrict__ weights,
    const T *__restrict__ bias,
    T *__restrict__ out,
    uint padding,
    uint B,
    uint L,
    uint L_out,
    uint L_eff,
    uint D,
    uint K)
{
    const int d_block = blockIdx.x * blockDim.x * TILE_SIZE_X;
    const int l = blockIdx.y * blockDim.y * TILE_SIZE_Y + threadIdx.y * TILE_SIZE_Y;
    const int b = blockIdx.z * blockDim.z + threadIdx.z;

    int d;

    #pragma unroll
        for (int i = 0; i < TILE_SIZE_X; i++)
        {   
            d = d_block + threadIdx.x + i * BX;

            if (d < D && b < B){
                #pragma unroll
                for (int t = 0; t < TILE_SIZE_Y; t++){
                    if (l + t < L_eff - K + 1)
                    {
                        _conv1d_k_3(u, weights, bias, out, padding, b, l, d, t, L, D, K, L_eff, L_out);
                    }
                }
            }
        }
}

template<typename T>
__global__ void conv1d_kernel(
    const T *__restrict__ u,
    const T *__restrict__ weights,
    const T *__restrict__ bias,
    T *__restrict__ out,
    uint padding,
    uint B,
    uint L,
    uint L_out,
    uint L_eff,
    uint D,
    uint K)
{
    const int d_block = blockIdx.x * blockDim.x * TILE_SIZE_X;
    const int l = blockIdx.y * blockDim.y * TILE_SIZE_Y + threadIdx.y * TILE_SIZE_Y;
    const int b = blockIdx.z * blockDim.z + threadIdx.z;

    int d;

    #pragma unroll
        for (int i = 0; i < TILE_SIZE_X; i++)
        {   
            d = d_block + threadIdx.x + i * BX;

            if (d < D && b < B){
                #pragma unroll
                for (int t = 0; t < TILE_SIZE_Y; t++){
                    if (l + t < L_eff - K + 1)
                    {
                        T temp_sum = bias[d];
                        for(int k = 0; k < K; k++){
                            temp_sum = __hfma2(get_u(u, L_eff, l + t, padding, b, k, d, L, D, K), weights[k * D + d], temp_sum);
                        }
                            out[b * D * L_out  + (l + t) * D + d] = temp_sum;
                    }
                }
            }
        }
}

torch::Tensor conv1d_cuda_blh(
    torch::Tensor u,
    torch::Tensor weight,
    torch::Tensor bias,
    uint padding)
{
    const uint b = u.size(0);
    const uint l = u.size(1);
    const uint d = u.size(2);

    const uint k = weight.size(0);

    uint l_eff = l + 2 * padding;

    

    dim3 blockDims(BX, BY, BZ);

    dim3 gridDims(ceil(d * 1.0 / (BX * TILE_SIZE_X * 2) ), ceil((l_eff - k + 1) * 1.0 / (BY * TILE_SIZE_Y)), ceil(b * 1.0 / BZ));


    uint l_out = (l + 2 * padding - k + 1);

    torch::Tensor out = torch::empty({b, l_out, d}, u.options());

    //calling seperate kernels for k=3 and k!=3 leads to better perf
    if(k==3){
        if(u.dtype() == torch::kFloat16){
            conv1d_kernel<<<gridDims, blockDims>>>(
                static_cast<__half2 *>(u.data_ptr()),
                static_cast<__half2 *>(weight.data_ptr()),
                static_cast<__half2 *>(bias.data_ptr()),
                static_cast<__half2 *>(out.data_ptr()),
                padding,
                b,
                l,
                l_out,
                l_eff,
                ceil(d/2),
                k);
        }else if(u.dtype() == torch::kBFloat16){
            conv1d_kernel_k_3<<<gridDims, blockDims>>>(
                static_cast<__nv_bfloat162 *>(u.data_ptr()),
                static_cast<__nv_bfloat162 *>(weight.data_ptr()),
                static_cast<__nv_bfloat162 *>(bias.data_ptr()),
                static_cast<__nv_bfloat162 *>(out.data_ptr()),
                padding,
                b,
                l,
                l_out,
                l_eff,
                ceil(d/2),
                k);
        }else if(u.dtype() == torch::kFloat32){
            conv1d_kernel_k_3<<<gridDims, blockDims>>>(
                static_cast<float2 *>(u.data_ptr()),
                static_cast<float2 *>(weight.data_ptr()),
                static_cast<float2 *>(bias.data_ptr()),
                static_cast<float2 *>(out.data_ptr()),
                padding,
                b,
                l,
                l_out,
                l_eff,
                ceil(d/2),
                k);
        }else{
            printf("Unsupported datatype\n");
        }
    }else{
        if(u.dtype() == torch::kFloat16){
            conv1d_kernel<<<gridDims, blockDims>>>(
                static_cast<__half2 *>(u.data_ptr()),
                static_cast<__half2 *>(weight.data_ptr()),
                static_cast<__half2 *>(bias.data_ptr()),
                static_cast<__half2 *>(out.data_ptr()),
                padding,
                b,
                l,
                l_out,
                l_eff,
                ceil(d/2),
                k);
        }else if(u.dtype() == torch::kBFloat16){
            conv1d_kernel<<<gridDims, blockDims>>>(
                static_cast<__nv_bfloat162 *>(u.data_ptr()),
                static_cast<__nv_bfloat162 *>(weight.data_ptr()),
                static_cast<__nv_bfloat162 *>(bias.data_ptr()),
                static_cast<__nv_bfloat162 *>(out.data_ptr()),
                padding,
                b,
                l,
                l_out,
                l_eff,
                ceil(d/2),
                k);
        }else if(u.dtype() == torch::kFloat32){
            conv1d_kernel<<<gridDims, blockDims>>>(
                static_cast<float2 *>(u.data_ptr()),
                static_cast<float2 *>(weight.data_ptr()),
                static_cast<float2 *>(bias.data_ptr()),
                static_cast<float2 *>(out.data_ptr()),
                padding,
                b,
                l,
                l_out,
                l_eff,
                ceil(d/2),
                k);
        }else{
            printf("Unsupported datatype\n");
        }
    }

    return out;
}