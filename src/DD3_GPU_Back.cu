#include "utilities.cuh"
#include "DD3_GPU_Back.h"

#define BACK_BLKX 64
#define BACK_BLKY 4
#define BACK_BLKZ 1

enum BackProjectionMethod{ _BRANCHLESS, _PSEUDODD, _ZLINEBRANCHLESS, _VOLUMERENDERING };

#ifndef CALDETPARAS
#define CALDETPARAS
float4 calDetParas(float* xds, float* yds, float* zds, float x0, float y0, float z0, int DNU, int DNV)
{
	float* bxds = new float[DNU + 1];
	float* byds = new float[DNU + 1];
	float* bzds = new float[DNV + 1];
	DD3Boundaries(DNU + 1, xds, bxds);
	DD3Boundaries(DNU + 1, yds, byds);
	DD3Boundaries(DNV + 1, zds, bzds);

	float ddv = (bzds[DNV] - bzds[0]) / DNV;
	float detCtrIdxV = (-(bzds[0] - z0) / ddv) - 0.5;
	float2 dir = normalize(make_float2(-x0, -y0));
	float2 dirL = normalize(make_float2(bxds[0] - x0, byds[0] - y0));
	float2 dirR = normalize(make_float2(bxds[DNU] - x0, byds[DNU] - y0));
	float dbeta = asin(dirL.x * dirR.y - dirL.y * dirR.x) / DNU;
	float minBeta = asin(dir.x * dirL.y - dir.y * dirL.x);
	float detCtrIdxU = -minBeta / dbeta - 0.5;
	delete [] bxds;
	delete [] byds;
	delete [] bzds;
	return make_float4(detCtrIdxU, detCtrIdxV, dbeta, ddv);

}

float4 calDetParas_alreadyinGPU(const thrust::device_vector<float>& dxds, const thrust::device_vector<float>& dyds,
		const thrust::device_vector<float>& dzds, float x0, float y0, float z0, int DNU, int DNV)
{
	float* bxds = new float[DNU + 1];
	float* byds = new float[DNU + 1];
	float* bzds = new float[DNV + 1];
	thrust::host_vector<float> xds = dxds;
	thrust::host_vector<float> yds = dyds;
	thrust::host_vector<float> zds = dzds;
	DD3Boundaries(DNU + 1, &xds[0], bxds);
	DD3Boundaries(DNU + 1, &yds[0], byds);
	DD3Boundaries(DNV + 1, &zds[0], bzds);

	float ddv = (bzds[DNV] - bzds[0]) / DNV;
	float detCtrIdxV = (-(bzds[0] - z0) / ddv) - 0.5;
	float2 dir = normalize(make_float2(-x0, -y0));
	float2 dirL = normalize(make_float2(bxds[0] - x0, byds[0] - y0));
	float2 dirR = normalize(make_float2(bxds[DNU] - x0, byds[DNU] - y0));
	float dbeta = asin(dirL.x * dirR.y - dirL.y * dirR.x) / DNU;
	float minBeta = asin(dir.x * dirL.y - dir.y * dirL.x);
	float detCtrIdxU = -minBeta / dbeta - 0.5;
	delete [] bxds;
	delete [] byds;
	delete [] bzds;
	xds.clear();
	yds.clear();
	zds.clear();

	return make_float4(detCtrIdxU, detCtrIdxV, dbeta, ddv);

}

#endif

__global__ void addTwoSidedZeroBoarder(float* prjIn, float* prjOut,
	const int DNU, const int DNV, const int PN)
{
	int idv = threadIdx.x + blockIdx.x * blockDim.x;
	int idu = threadIdx.y + blockIdx.y * blockDim.y;
	int pn = threadIdx.z + blockIdx.z * blockDim.z;
	if (idu < DNU && idv < DNV && pn < PN)
	{
		int inIdx = (pn * DNU + idu) * DNV + idv;
		int outIdx = (pn * (DNU + 2) + (idu + 1)) * (DNV + 2) + idv + 1;
		prjOut[outIdx] = prjIn[inIdx];
	}
}


__global__ void addOneSidedZeroBoarder(const float* prj_in, float* prj_out, int DNU, int DNV, int PN)
{
	int idv = threadIdx.x + blockIdx.x * blockDim.x;
	int idu = threadIdx.y + blockIdx.y * blockDim.y;
	int pn = threadIdx.z + blockIdx.z * blockDim.z;
	if (idu < DNU && idv < DNV && pn < PN)
	{
		int i = (pn * DNU + idu) * DNV + idv;
		int ni = (pn * (DNU + 1) + (idu + 1)) * (DNV + 1) + idv + 1;
		prj_out[ni] = prj_in[i];
	}
}

__global__ void verticalIntegral2(float* prj, int ZN, int N)
{
	int idx = threadIdx.x + blockIdx.x * blockDim.x;
	if (idx < N)
	{
		int currentHead = idx * ZN;
		for (int ii = 1; ii < ZN; ++ii)
		{
			prj[currentHead + ii] = prj[currentHead + ii] + prj[currentHead + ii - 1];
		}
	}
}



__global__ void heorizontalIntegral2(float* prj, int DNU, int DNV, int PN)
{
	int idv = threadIdx.x + blockIdx.x * blockDim.x;
	int pIdx = threadIdx.y + blockIdx.y * blockDim.y;
	if (idv < DNV && pIdx < PN)
	{
		int headPrt = pIdx * DNU * DNV + idv;
		for (int ii = 1; ii < DNU; ++ii)
		{
			prj[headPrt + ii * DNV] = prj[headPrt + ii * DNV] + prj[headPrt + (ii - 1) * DNV];
		}
	}
}

thrust::device_vector<float> genSAT_of_Projection(
	float* hprj,
	int DNU, int DNV, int PN)
{
	const int siz = DNU * DNV * PN;
	const int nsiz = (DNU + 1) * (DNV + 1) * PN;
	thrust::device_vector<float> prjSAT(nsiz, 0);
	thrust::device_vector<float> prj(hprj, hprj + siz);
	dim3 copyBlk(64, 16, 1);
	dim3 copyGid(
		(DNV + copyBlk.x - 1) / copyBlk.x,
		(DNU + copyBlk.y - 1) / copyBlk.y,
		(PN + copyBlk.z - 1) / copyBlk.z);

	addOneSidedZeroBoarder << <copyGid, copyBlk >> >(
		thrust::raw_pointer_cast(&prj[0]),
		thrust::raw_pointer_cast(&prjSAT[0]),
		DNU, DNV, PN);
	const int nDNU = DNU + 1;
	const int nDNV = DNV + 1;

	copyBlk.x = 512;
	copyBlk.y = 1;
	copyBlk.z = 1;
	copyGid.x = (nDNU * PN + copyBlk.x - 1) / copyBlk.x;
	copyGid.y = 1;
	copyGid.z = 1;
	verticalIntegral2 << <copyGid, copyBlk >> >(
		thrust::raw_pointer_cast(&prjSAT[0]),
		nDNV, nDNU * PN);
	copyBlk.x = 64;
	copyBlk.y = 16;
	copyBlk.z = 1;
	copyGid.x = (nDNV + copyBlk.x - 1) / copyBlk.x;
	copyGid.y = (PN + copyBlk.y - 1) / copyBlk.y;
	copyGid.z = 1;


	heorizontalIntegral2 << <copyGid, copyBlk >> >(
		thrust::raw_pointer_cast(&prjSAT[0]),
		nDNU, nDNV, PN);

	return prjSAT;
}



thrust::device_vector<float> genSAT_of_Projection_alreadyinGPU(
	const thrust::device_vector<float>& prj,
	int DNU, int DNV, int PN)
{
	const int nsiz = (DNU + 1) * (DNV + 1) * PN;
	thrust::device_vector<float> prjSAT(nsiz, 0);
	//thrust::device_vector<float> prj(hprj, hprj + siz);
	dim3 copyBlk(64, 16, 1);
	dim3 copyGid(
		(DNV + copyBlk.x - 1) / copyBlk.x,
		(DNU + copyBlk.y - 1) / copyBlk.y,
		(PN + copyBlk.z - 1) / copyBlk.z);

	addOneSidedZeroBoarder << <copyGid, copyBlk >> >(
		thrust::raw_pointer_cast(&prj[0]),
		thrust::raw_pointer_cast(&prjSAT[0]),
		DNU, DNV, PN);
	const int nDNU = DNU + 1;
	const int nDNV = DNV + 1;

	copyBlk.x = 512;
	copyBlk.y = 1;
	copyBlk.z = 1;
	copyGid.x = (nDNU * PN + copyBlk.x - 1) / copyBlk.x;
	copyGid.y = 1;
	copyGid.z = 1;
	verticalIntegral2 << <copyGid, copyBlk >> >(
		thrust::raw_pointer_cast(&prjSAT[0]),
		nDNV, nDNU * PN);
	copyBlk.x = 64;
	copyBlk.y = 16;
	copyBlk.z = 1;
	copyGid.x = (nDNV + copyBlk.x - 1) / copyBlk.x;
	copyGid.y = (PN + copyBlk.y - 1) / copyBlk.y;
	copyGid.z = 1;


	heorizontalIntegral2 << <copyGid, copyBlk >> >(
		thrust::raw_pointer_cast(&prjSAT[0]),
		nDNU, nDNV, PN);

	return prjSAT;
}

void createTextureObject(
	cudaTextureObject_t& texObj,
	cudaArray* d_prjArray,
	int Width, int Height, int Depth,
	float* sourceData,
	cudaMemcpyKind memcpyKind,
	cudaTextureAddressMode addressMode,
	cudaTextureFilterMode textureFilterMode,
	cudaTextureReadMode textureReadMode,
	bool isNormalized)
{
	cudaExtent prjSize;
	prjSize.width = Width;
	prjSize.height = Height;
	prjSize.depth = Depth;
	cudaChannelFormatDesc channelDesc = cudaCreateChannelDesc<float>();

	cudaMalloc3DArray(&d_prjArray, &channelDesc, prjSize);
	cudaMemcpy3DParms copyParams = { 0 };
	copyParams.srcPtr = make_cudaPitchedPtr(
		(void*) sourceData, prjSize.width * sizeof(float),
		prjSize.width, prjSize.height);
	copyParams.dstArray = d_prjArray;
	copyParams.extent = prjSize;
	copyParams.kind = memcpyKind;
	cudaMemcpy3D(&copyParams);
	cudaResourceDesc resDesc;
	memset(&resDesc, 0, sizeof(resDesc));
	resDesc.resType = cudaResourceTypeArray;
	resDesc.res.array.array = d_prjArray;
	cudaTextureDesc texDesc;
	memset(&texDesc, 0, sizeof(texDesc));
	texDesc.addressMode[0] = addressMode;
	texDesc.addressMode[1] = addressMode;
	texDesc.addressMode[2] = addressMode;
	texDesc.filterMode = textureFilterMode;
	texDesc.readMode = textureReadMode;
	texDesc.normalizedCoords = isNormalized;

	cudaCreateTextureObject(&texObj, &resDesc, &texDesc, nullptr);
}



void destroyTextureObject(cudaTextureObject_t& texObj, cudaArray* d_array)
{
	cudaDestroyTextureObject(texObj);
	cudaFreeArray(d_array);
}




template < BackProjectionMethod METHOD >
__global__ void DD3_gpu_back_ker(
	cudaTextureObject_t prjTexObj,
	float* vol,
	const byte* __restrict__ msk,
	const float3* __restrict__ cossinT,
	float3 s,
	float S2D,
	float3 curvox,
	float dx, float dz,
	float dbeta, float ddv,
	float2 detCntIdx,
	int3 VN,
	int PN, int squared)
{}


template < BackProjectionMethod METHOD >
__global__ void DD3_panel_gpu_back_ker(
	cudaTextureObject_t prjTexObj,
	float* vol,
	const byte* __restrict__ msk,
	const float3* __restrict__ cossinT,
	float3 s,
	float S2D,
	float3 curvox,
	float dx, float dz,
	float dbeta, float ddv,
	float2 detCntIdx,
	int3 VN,
	int PN, int squared)
{}


template<>
__global__ void DD3_panel_gpu_back_ker<_BRANCHLESS>
	(cudaTextureObject_t prjTexObj,
	float* vol,
	const byte* __restrict__ msk,
	const float3* __restrict__ cossinT,
	float3 s,
	float S2D,
	float3 curvox,
	float dx, float dz,
	float dbeta, //Detector size in channel direction
	float ddv, //detector size in Z direction
	float2 detCntIdx,
	int3 VN,
	int PN, int squared)
{
	int3 id;
	id.z = threadIdx.x + __umul24(blockIdx.x, blockDim.x);
	id.x = threadIdx.y + __umul24(blockIdx.y, blockDim.y);
	id.y = threadIdx.z + __umul24(blockIdx.z, blockDim.z);
	if (id.x < VN.x && id.y < VN.y && id.z < VN.z)
	{
		if (msk[id.y * VN.x + id.x] != 1)
			return;
		curvox = (id - curvox) * make_float3(dx, dx, dz);
		float3 cursour;
		float idxL, idxR, idxU, idxD;
		float cosVal;
		float summ = 0;

		float3 cossin;
		float inv_sid = 1.0 / sqrtf(s.x * s.x + s.y * s.y);
		float3 dir;
		float l_square;
		float l;
		float alpha;
		float S2D2 = S2D;
		S2D = S2D / ddv;
		dbeta = 1.0 / dbeta;
		dz = dz * 0.5;
		float2 dirL;
		float2 dirR;
		for (int angIdx = 0; angIdx < PN; ++angIdx)
		{
			cossin = cossinT[angIdx];
			cursour = make_float3(
				s.x * cossin.x - s.y * cossin.y,
				s.x * cossin.y + s.y * cossin.x,
				s.z + cossin.z);

			dir = curvox - cursour;
			l_square = dir.x * dir.x + dir.y * dir.y;
			l = rsqrtf(l_square);
			idxU = (dir.z + dz) * S2D * l + detCntIdx.y + 1;
			idxD = (dir.z - dz) * S2D * l + detCntIdx.y + 1;

			if (fabsf(cursour.x) > fabsf(cursour.y))
			{
				ddv = dir.x;
				dirL = normalize(make_float2(dir.x, dir.y - 0.5 * dx));
				dirR = normalize(make_float2(dir.x, dir.y + 0.5 * dx));
			}
			else
			{
				ddv = dir.y;
				dirL = normalize(make_float2(dir.x + 0.5 * dx, dir.y));
				dirR = normalize(make_float2(dir.x - 0.5 * dx, dir.y));
			}
			cosVal = dx / ddv * sqrtf(l_square + dir.z * dir.z);

			//! TODO: Test the correctness of this method.
			alpha = asinf((cursour.y * dirL.x - cursour.x * dirL.y) * inv_sid);
			idxL = (tanf(alpha) * S2D2 * dbeta) + detCntIdx.x + 1;
			alpha = asinf((cursour.y * dirR.x - cursour.x * dirR.y) * inv_sid);
			idxR = (tanf(alpha) * S2D2 * dbeta) + detCntIdx.x + 1;
			//summ += idxL;

			summ +=
				(-tex3D<float>(prjTexObj, idxD, idxR, angIdx + 0.5)
				- tex3D<float>(prjTexObj, idxU, idxL, angIdx + 0.5)
				+ tex3D<float>(prjTexObj, idxD, idxL, angIdx + 0.5)
				+ tex3D<float>(prjTexObj, idxU, idxR, angIdx + 0.5)) * cosVal;
		}
		__syncthreads();
		vol[__umul24((__umul24(id.y, VN.x) + id.x), VN.z) + id.z] = summ;
	}
}

template<>
__global__ void DD3_gpu_back_ker<_BRANCHLESS>(
	cudaTextureObject_t prjTexObj,
	float* vol,
	const byte* __restrict__ msk,
	const float3* __restrict__ cossinT,
	float3 s,
	float S2D,
	float3 curvox,
	float dx, float dz,
	float dbeta, float ddv,
	float2 detCntIdx,
	int3 VN,
	int PN, int squared)
{
	int3 id;
	id.z = threadIdx.x + __umul24(blockIdx.x, blockDim.x);
	id.x = threadIdx.y + __umul24(blockIdx.y, blockDim.y);
	id.y = threadIdx.z + __umul24(blockIdx.z, blockDim.z);
	if (id.x < VN.x && id.y < VN.y && id.z < VN.z)
	{
		if (msk[id.y * VN.x + id.x] != 1)
			return;
		curvox = (id - curvox) * make_float3(dx, dx, dz);
		float3 cursour;
		float idxL, idxR, idxU, idxD;
		float cosVal;
		float summ = 0;

		float3 cossin;
		float inv_sid = 1.0 / sqrtf(s.x * s.x + s.y * s.y);
		float3 dir;
		float l_square;
		float l;
		float alpha;
		float deltaAlpha;
		S2D = S2D / ddv;
		dbeta = 1.0 / dbeta;
		dz = dz * 0.5;
		for (int angIdx = 0; angIdx < PN; ++angIdx)
		{
			cossin = cossinT[angIdx];
			cursour = make_float3(
				s.x * cossin.x - s.y * cossin.y,
				s.x * cossin.y + s.y * cossin.x,
				s.z + cossin.z);

			dir = curvox - cursour;
			l_square = dir.x * dir.x + dir.y * dir.y;
			l = rsqrtf(l_square);
			idxU = (dir.z + dz) * S2D * l + detCntIdx.y + 1;
			idxD = (dir.z - dz) * S2D * l + detCntIdx.y + 1;

			alpha = asinf((cursour.y * dir.x - cursour.x * dir.y) * inv_sid * l);
			if (fabsf(cursour.x) > fabsf(cursour.y))
			{
				ddv = dir.x;
			}
			else
			{
				ddv = dir.y;
			}
			deltaAlpha = ddv / l_square * dx * 0.5;
			cosVal = dx / ddv * sqrtf(l_square + dir.z * dir.z);
			idxL = (alpha - deltaAlpha) * dbeta + detCntIdx.x + 1;
			idxR = (alpha + deltaAlpha) * dbeta + detCntIdx.x + 1;

			summ +=
				(-tex3D<float>(prjTexObj, idxD, idxR, angIdx + 0.5)
				- tex3D<float>(prjTexObj, idxU, idxL, angIdx + 0.5)
				+ tex3D<float>(prjTexObj, idxD, idxL, angIdx + 0.5)
				+ tex3D<float>(prjTexObj, idxU, idxR, angIdx + 0.5)) * cosVal;
		}
		__syncthreads();
		vol[__umul24((__umul24(id.y, VN.x) + id.x), VN.z) + id.z] = summ;
	}
}







__global__ void DD3_gpu_back_branchless_ker(
	cudaTextureObject_t prjTexObj,
	float* vol,
	const byte* __restrict__ msk,
	const float3* __restrict__ cossinT,
	float3 s,
	float S2D,
	float3 curvox,
	float dx, float dz,
	float dbeta, float ddv,
	float2 detCntIdx,
	int3 VN,
	int PN, int squared)
{
	int3 id;
	id.z = threadIdx.x + __umul24(blockIdx.x, blockDim.x);
	id.x = threadIdx.y + __umul24(blockIdx.y, blockDim.y);
	id.y = threadIdx.z + __umul24(blockIdx.z, blockDim.z);
	if (id.x < VN.x && id.y < VN.y && id.z < VN.z)
	{
		if (msk[id.y * VN.x + id.x] != 1)
			return;
		curvox = (id - curvox) * make_float3(dx, dx, dz);
		float3 cursour;
		float idxL, idxR, idxU, idxD;
		float cosVal;
		float summ = 0;

		float3 cossin;
		float inv_sid = 1.0 / sqrtf(s.x * s.x + s.y * s.y);
		float3 dir;
		float l_square;
		float l;
		float alpha;
		float deltaAlpha;
		S2D = S2D / ddv;
		dbeta = 1.0 / dbeta;
		dz = dz * 0.5;
		for (int angIdx = 0; angIdx < PN; ++angIdx)
		{
			cossin = cossinT[angIdx];
			cursour = make_float3(
				s.x * cossin.x - s.y * cossin.y,
				s.x * cossin.y + s.y * cossin.x,
				s.z + cossin.z);

			dir = curvox - cursour;
			l_square = dir.x * dir.x + dir.y * dir.y;
			l = rsqrtf(l_square);
			idxU = (dir.z + dz) * S2D * l + detCntIdx.y + 1;
			idxD = (dir.z - dz) * S2D * l + detCntIdx.y + 1;

			alpha = asinf((cursour.y * dir.x - cursour.x * dir.y) * inv_sid * l);
			if (fabsf(cursour.x) > fabsf(cursour.y))
			{
				ddv = dir.x;
			}
			else
			{
				ddv = dir.y;
			}
			deltaAlpha = ddv / l_square * dx * 0.5;
			cosVal = dx / ddv * sqrtf(l_square + dir.z * dir.z);
			idxL = (alpha - deltaAlpha) * dbeta + detCntIdx.x + 1;
			idxR = (alpha + deltaAlpha) * dbeta + detCntIdx.x + 1;

			summ +=
				(-tex3D<float>(prjTexObj, idxD, idxR, angIdx + 0.5)
				- tex3D<float>(prjTexObj, idxU, idxL, angIdx + 0.5)
				+ tex3D<float>(prjTexObj, idxD, idxL, angIdx + 0.5)
				+ tex3D<float>(prjTexObj, idxU, idxR, angIdx + 0.5)) * cosVal;
		}
		__syncthreads();
		vol[__umul24((__umul24(id.y, VN.x) + id.x), VN.z) + id.z] = summ;
	}
}


void DD3_gpu_back_branchless_sat2d(
	float x0, float y0, float z0,
	int DNU, int DNV,
	float* xds, float* yds, float* zds,
	float imgXCenter, float imgYCenter, float imgZCenter,
	float* hangs, float* hzPos, int PN,
	int XN, int YN, int ZN,
	float* hvol, float* hprj,
	float dx, float dz,
	byte* mask, int squared, int gpunum)
{
	cudaSetDevice(gpunum);
	cudaDeviceReset();

	const int TOTVON = XN * YN * ZN;
	const float objCntIdxX = (XN - 1.0) * 0.5 - imgXCenter;
	const float objCntIdxY = (YN - 1.0) * 0.5 - imgYCenter;
	const float objCntIdxZ = (ZN - 1.0) * 0.5 - imgZCenter;

	thrust::device_vector<float> prjSAT = genSAT_of_Projection(hprj, DNU, DNV, PN);

	cudaExtent prjSize;
	prjSize.width = DNV + 1;
	prjSize.height = DNU + 1;
	prjSize.depth = PN;

	cudaChannelFormatDesc channelDesc = cudaCreateChannelDesc<float>();
	cudaArray *d_prjSATarray;
	cudaMalloc3DArray(&d_prjSATarray, &channelDesc, prjSize);

	cudaMemcpy3DParms copyParams = { 0 };
	copyParams.srcPtr = make_cudaPitchedPtr(
		(void*) thrust::raw_pointer_cast(&prjSAT[0]),
		prjSize.width * sizeof(float),
		prjSize.width,
		prjSize.height);

	copyParams.dstArray = d_prjSATarray;
	copyParams.extent = prjSize;
	copyParams.kind = cudaMemcpyDeviceToDevice;
	cudaMemcpy3D(&copyParams);

	cudaResourceDesc resDesc;
	memset(&resDesc, 0, sizeof(resDesc));
	resDesc.resType = cudaResourceTypeArray;
	resDesc.res.array.array = d_prjSATarray;
	cudaTextureDesc texDesc;
	memset(&texDesc, 0, sizeof(texDesc));
	texDesc.addressMode[0] = cudaAddressModeClamp;
	texDesc.addressMode[1] = cudaAddressModeClamp;
	texDesc.addressMode[2] = cudaAddressModeClamp;
	texDesc.filterMode = cudaFilterModeLinear;
	texDesc.readMode = cudaReadModeElementType;
	cudaTextureObject_t texObj;
	texDesc.normalizedCoords = false;
	cudaCreateTextureObject(&texObj, &resDesc, &texDesc, nullptr);
	prjSAT.clear();

	thrust::device_vector<float> angs(hangs, hangs + PN);
	thrust::device_vector<float> zPos(hzPos, hzPos + PN);

	thrust::device_vector<float3> cursour(PN);
	thrust::device_vector<float2> dirsour(PN);
	thrust::device_vector<float3> cossinT(PN);

	thrust::transform(
		thrust::make_zip_iterator(thrust::make_tuple(angs.begin(), zPos.begin())),
		thrust::make_zip_iterator(thrust::make_tuple(angs.end(), zPos.end())),
		thrust::make_zip_iterator(thrust::make_tuple(cossinT.begin(), cursour.begin(), dirsour.begin())),
		CTMBIR::ConstantForBackProjection3(x0, y0, z0));

	thrust::device_vector<float> vol(TOTVON, 0);
	thrust::device_vector<byte> msk(mask, mask + XN * YN);
	const float S2D = hypotf(xds[0] - x0, yds[0] - y0);

	float* bxds = new float[DNU + 1];
	float* byds = new float[DNU + 1];
	float* bzds = new float[DNV + 1];

	DD3Boundaries<float>(DNU + 1, xds, bxds);
	DD3Boundaries<float>(DNU + 1, yds, byds);
	DD3Boundaries<float>(DNV + 1, zds, bzds);

	float ddv = (bzds[DNV] - bzds[0]) / DNV;
	float detCtrIdV = (-(bzds[0] - z0) / ddv) - 0.5;
	float2 dir = normalize(make_float2(-x0, -y0));
	float2 dirL = normalize(make_float2(bxds[0] - x0, byds[0] - y0));
	float2 dirR = normalize(make_float2(bxds[DNU] - x0, byds[DNU] - y0));
	float dbeta = asinf(dirL.x * dirR.y - dirL.y * dirR.x) / DNU;
	float minBeta = asinf(dir.x * dirL.y - dir.y * dirL.x);
	float detCtrIdU = -minBeta / dbeta - 0.5;

	dim3 blk(BACK_BLKX, BACK_BLKY, BACK_BLKZ);
	dim3 gid(
		(ZN + blk.x - 1) / blk.x,
		(XN + blk.y - 1) / blk.y,
		(YN + blk.z - 1) / blk.z);

	DD3_gpu_back_branchless_ker << <gid, blk >> >(texObj,
		thrust::raw_pointer_cast(&vol[0]),
		thrust::raw_pointer_cast(&msk[0]),
		thrust::raw_pointer_cast(&cossinT[0]),
		make_float3(x0, y0, z0),
		S2D, make_float3(objCntIdxX, objCntIdxY, objCntIdxZ),
		dx, dz, dbeta, ddv, make_float2(detCtrIdU, detCtrIdV),
		make_int3(XN, YN, ZN), PN, static_cast<int>(squared != 0));
	thrust::copy(vol.begin(), vol.end(), hvol);
	delete [] bxds;
	delete [] byds;
	delete [] bzds;
}




__global__ void DD3_gpu_back_pixel_ker(
		cudaTextureObject_t prjTexObj,
		float* vol,
		const byte* __restrict__ msk,
		const float3* __restrict__ cossinT,
		float3 s,
		float S2D,
		float3 objCtrIdx,
		float dx, float dz,
		float dbeta, float ddv,
		float2 detCntIdx,
		int3 VN,
		int PN, int squared)
{
//	int3 id;
//	id.z = threadIdx.x + __umul24(blockIdx.x, blockDim.x);
//	id.x = threadIdx.y + __umul24(blockIdx.y, blockDim.y);
//	id.y = threadIdx.z + __umul24(blockIdx.z, blockDim.z);
//
//	if (id.x < VN.x && id.y < VN.y && id.z < VN.z)
//	{
//		if (msk[id.y * VN.x + id.x] != 1) //maybe optimize
//			return;
//		//current voxel position
//		float3 currvox = (id - objCtrIdx) * make_float3(dx, dx, dz); //current voxel position
//		float3 initvox;
//		float3 dir;
//		float cosT, sinT, zShift;
//		float summ = 0;
//		for(int angIdx = 0; angIdx != PN; ++angIdx)
//		{
//			cosT = cossinT[angIdx].x;
//			sinT = cossinT[angIdx].y;
//			zShift = cossinT[angIdx].z;
//
//			initvox = make_float3(
//					 currvox.x * cosT + currvox.y * sinT,
//					-currvox.x * sinT + currvox.y * cosT,
//					 currvox.z - zShift);
//			//dir = normalize(initvox - s);
//
//			float betaIdx = atan(-dir.y / dir.x) / dbeta; //may have 0.5 err
//			float zIdx = ()
//			if (intersectBox(float3 ro, float3 rd, float3 boxmin, float3 boxmax, float *tnear, float *tfar))
//			{
//
//			}
//
//
//		}
//
//
//
//
//
//		float3 cursour;
//		float idxL, idxR, idxU, idxD;
//		float cosVal;
//		float summ = 0;
//
//		float3 cossin;
//		float inv_sid = 1.0 / sqrtf(s.x * s.x + s.y * s.y);
//		float3 dir;
//		float l_square;
//		float l;
//		float alpha;
//		float deltaAlpha;
//		S2D = S2D / ddv;
//		dbeta = 1.0 / dbeta;
//		dz = dz * 0.5;
//		for (int angIdx = 0; angIdx < PN; ++angIdx)
//		{
//			cossin = cossinT[angIdx];
//			cursour = make_float3(
//				s.x * cossin.x - s.y * cossin.y,
//				s.x * cossin.y + s.y * cossin.x,
//				s.z + cossin.z);
//
//			dir = curvox - cursour;
//			l_square = dir.x * dir.x + dir.y * dir.y;
//			l = rsqrtf(l_square);
//			idxU = (dir.z + dz) * S2D * l + detCntIdx.y + 1;
//			idxD = (dir.z - dz) * S2D * l + detCntIdx.y + 1;
//
//			alpha = asinf((cursour.y * dir.x - cursour.x * dir.y) * inv_sid * l);
//			if (fabsf(cursour.x) > fabsf(cursour.y))
//			{
//				ddv = dir.x;
//			}
//			else
//			{
//				ddv = dir.y;
//			}
//			deltaAlpha = ddv / l_square * dx * 0.5;
//			cosVal = dx / ddv * sqrtf(l_square + dir.z * dir.z);
//			idxL = (alpha - deltaAlpha) * dbeta + detCntIdx.x + 1;
//			idxR = (alpha + deltaAlpha) * dbeta + detCntIdx.x + 1;
//
//			summ +=
//				(-tex3D<float>(prjTexObj, idxD, idxR, angIdx + 0.5)
//				- tex3D<float>(prjTexObj, idxU, idxL, angIdx + 0.5)
//				+ tex3D<float>(prjTexObj, idxD, idxL, angIdx + 0.5)
//				+ tex3D<float>(prjTexObj, idxU, idxR, angIdx + 0.5)) * cosVal;
//		}
//		__syncthreads();
//		vol[__umul24((__umul24(id.y, VN.x) + id.x), VN.z) + id.z] = summ;
//	}
}




// Pixel Driven backprojection
//extern "C"
//void DD3BackPixel_gpu(
//	float x0, float y0, float z0,
//	int DNU, int DNV,
//	float* xds, float* yds, float* zds,
//	float imgXCenter, float imgYCenter, float imgZCenter,
//	float* hangs, float* hzPos, int PN,
//	int XN, int YN, int ZN,
//	float* hvol, float* hprj,
//	float dx, float dz,
//	byte* mask, int gpunum, int squared)
//{
//	cudaSetDevice(gpunum);
//	cudaDeviceReset();
//
//	const int TOTVON = XN * YN * ZN;
//	const float objCntIdxX = (XN - 1.0) * 0.5 - imgXCenter;
//	const float objCntIdxY = (YN - 1.0) * 0.5 - imgYCenter;
//	const float objCntIdxZ = (ZN - 1.0) * 0.5 - imgZCenter;
//
//	cudaExtent prjSize;
//	prjSize.width = DNV;
//	prjSize.height = DNU;
//	prjSize.depth = PN;
//
//	cudaChannelFormatDesc channelDesc = cudaCreateChannelDesc<float>();
//	cudaArray *d_prjArray;
//	cudaMalloc3DArray(&d_prjArray, &channelDesc, prjSize);
//
//	cudaMemcpy3DParms copyParams = { 0 };
//	copyParams.srcPtr = make_cudaPitchedPtr(
//		(void*) hprj,
//		prjSize.width * sizeof(float),
//		prjSize.width,
//		prjSize.height);
//
//	copyParams.dstArray = d_prjArray;
//	copyParams.extent = prjSize;
//	copyParams.kind = cudaMemcpyHostToDevice;
//	cudaMemcpy3D(&copyParams);
//
//	cudaResourceDesc resDesc;
//	memset(&resDesc, 0, sizeof(resDesc));
//	resDesc.resType = cudaResourceTypeArray;
//	resDesc.res.array.array = d_prjArray;
//	cudaTextureDesc texDesc;
//	memset(&texDesc, 0, sizeof(texDesc));
//	texDesc.addressMode[0] = cudaAddressModeBorder;
//	texDesc.addressMode[1] = cudaAddressModeBorder;
//	texDesc.addressMode[2] = cudaAddressModeBorder;
//	texDesc.filterMode = cudaFilterModeLinear;
//	texDesc.readMode = cudaReadModeElementType;
//	cudaTextureObject_t texObj;
//	texDesc.normalizedCoords = false;
//	cudaCreateTextureObject(&texObj, &resDesc, &texDesc, nullptr);
//
//	thrust::device_vector<float> angs(hangs, hangs + PN);
//	thrust::device_vector<float> zPos(hzPos, hzPos + PN);
//
//	thrust::device_vector<float3> cursour(PN);
//	thrust::device_vector<float2> dirsour(PN);
//	thrust::device_vector<float3> cossinT(PN);
//
//	thrust::transform(
//		thrust::make_zip_iterator(thrust::make_tuple(angs.begin(), zPos.begin())),
//		thrust::make_zip_iterator(thrust::make_tuple(angs.end(), zPos.end())),
//		thrust::make_zip_iterator(thrust::make_tuple(cossinT.begin(), cursour.begin(), dirsour.begin())),
//		CTMBIR::ConstantForBackProjection3(x0, y0, z0));
//
//	thrust::device_vector<float> vol(TOTVON, 0);
//	thrust::device_vector<byte> msk(mask, mask + XN * YN);
//	const float S2D = hypotf(xds[0] - x0, yds[0] - y0);
//
//	float* bxds = new float[DNU + 1];
//	float* byds = new float[DNU + 1];
//	float* bzds = new float[DNV + 1];
//
//	DD3Boundaries<float>(DNU + 1, xds, bxds);
//	DD3Boundaries<float>(DNU + 1, yds, byds);
//	DD3Boundaries<float>(DNV + 1, zds, bzds);
//
//	float ddv = (bzds[DNV] - bzds[0]) / DNV;
//	float detCtrIdV = (-(bzds[0] - z0) / ddv) - 0.5;
//	float2 dir = normalize(make_float2(-x0, -y0));
//	float2 dirL = normalize(make_float2(bxds[0] - x0, byds[0] - y0));
//	float2 dirR = normalize(make_float2(bxds[DNU] - x0, byds[DNU] - y0));
//	float dbeta = asinf(dirL.x * dirR.y - dirL.y * dirR.x) / DNU;
//	float minBeta = asinf(dir.x * dirL.y - dir.y * dirL.x);
//	float detCtrIdU = -minBeta / dbeta - 0.5;
//
//	dim3 blk(BACK_BLKX, BACK_BLKY, BACK_BLKZ);
//	dim3 gid(
//		(ZN + blk.x - 1) / blk.x,
//		(XN + blk.y - 1) / blk.y,
//		(YN + blk.z - 1) / blk.z);
//
	//DD3_gpu_back_branchless_ker << <gid, blk >> >(texObj,
//		thrust::raw_pointer_cast(&vol[0]),
//		thrust::raw_pointer_cast(&msk[0]),
//		thrust::raw_pointer_cast(&cossinT[0]),
//		make_float3(x0, y0, z0),
//		S2D, make_float3(objCntIdxX, objCntIdxY, objCntIdxZ),
//		dx, dz, dbeta, ddv, make_float2(detCtrIdU, detCtrIdV),
//		make_int3(XN, YN, ZN), PN, static_cast<int>(squared != 0));
//	thrust::copy(vol.begin(), vol.end(), hvol);
//	delete [] bxds;
//	delete [] byds;
//	delete [] bzds;
//}









extern "C"
void DD3_panel_gpu_back_branchless_sat2d(
	float x0, float y0, float z0,
	int DNU, int DNV,
	float* xds, float* yds, float* zds,
	float imgXCenter, float imgYCenter, float imgZCenter,
	float* hangs, float* hzPos, int PN,
	int XN, int YN, int ZN,
	float* hvol, float* hprj,
	float dx, float dz,
	byte* mask, int squared, int gpunum)
{
	cudaSetDevice(gpunum);
	cudaDeviceReset();

	const int TOTVON = XN * YN * ZN;
	const float objCntIdxX = (XN - 1.0) * 0.5 - imgXCenter;
	const float objCntIdxY = (YN - 1.0) * 0.5 - imgYCenter;
	const float objCntIdxZ = (ZN - 1.0) * 0.5 - imgZCenter;

	thrust::device_vector<float> prjSAT = genSAT_of_Projection(hprj, DNU, DNV, PN);

	cudaExtent prjSize;
	prjSize.width = DNV + 1;
	prjSize.height = DNU + 1;
	prjSize.depth = PN;

	cudaChannelFormatDesc channelDesc = cudaCreateChannelDesc<float>();
	cudaArray *d_prjSATarray;
	cudaMalloc3DArray(&d_prjSATarray, &channelDesc, prjSize);

	cudaMemcpy3DParms copyParams = { 0 };
	copyParams.srcPtr = make_cudaPitchedPtr(
		(void*)thrust::raw_pointer_cast(&prjSAT[0]),
		prjSize.width * sizeof(float),
		prjSize.width,
		prjSize.height);

	copyParams.dstArray = d_prjSATarray;
	copyParams.extent = prjSize;
	copyParams.kind = cudaMemcpyDeviceToDevice;
	cudaMemcpy3D(&copyParams);

	cudaResourceDesc resDesc;
	memset(&resDesc, 0, sizeof(resDesc));
	resDesc.resType = cudaResourceTypeArray;
	resDesc.res.array.array = d_prjSATarray;
	cudaTextureDesc texDesc;
	memset(&texDesc, 0, sizeof(texDesc));
	texDesc.addressMode[0] = cudaAddressModeClamp;
	texDesc.addressMode[1] = cudaAddressModeClamp;
	texDesc.addressMode[2] = cudaAddressModeClamp;
	texDesc.filterMode = cudaFilterModeLinear;
	texDesc.readMode = cudaReadModeElementType;
	cudaTextureObject_t texObj;
	texDesc.normalizedCoords = false;
	cudaCreateTextureObject(&texObj, &resDesc, &texDesc, nullptr);
	prjSAT.clear();

	thrust::device_vector<float> angs(hangs, hangs + PN);
	thrust::device_vector<float> zPos(hzPos, hzPos + PN);

	thrust::device_vector<float3> cursour(PN);
	thrust::device_vector<float2> dirsour(PN);
	thrust::device_vector<float3> cossinT(PN);

	thrust::transform(
		thrust::make_zip_iterator(thrust::make_tuple(angs.begin(), zPos.begin())),
		thrust::make_zip_iterator(thrust::make_tuple(angs.end(), zPos.end())),
		thrust::make_zip_iterator(thrust::make_tuple(cossinT.begin(), cursour.begin(), dirsour.begin())),
		CTMBIR::ConstantForBackProjection3(x0, y0, z0));

	thrust::device_vector<float> vol(TOTVON, 0);
	thrust::device_vector<byte> msk(mask, mask + XN * YN);
	const float S2D = hypotf(xds[0] - x0, yds[0] - y0);

	float* bxds = new float[DNU + 1];
	float* byds = new float[DNU + 1];
	float* bzds = new float[DNV + 1];

	DD3Boundaries<float>(DNU + 1, xds, bxds);
	DD3Boundaries<float>(DNU + 1, yds, byds);
	DD3Boundaries<float>(DNV + 1, zds, bzds);

	float ddv = (bzds[DNV] - bzds[0]) / DNV;
	float detCtrIdV = (-(bzds[0] - z0) / ddv) - 0.5;

	//Assume all the detector are with the same size;
	float dbeta = sqrtf(powf(bxds[0] - bxds[DNU], 2.0) + powf(byds[0] - byds[DNU], 2.0)) / DNU;
	/*float2 dir = normalize(make_float2(-x0, -y0));
	float2 dirL = normalize(make_float2(bxds[0] - x0, byds[0] - y0));
	float2 dirR = normalize(make_float2(bxds[DNU] - x0, byds[DNU] - y0));*/
	//We assume that initiall the detector is parallel to X axis
	float detCtrIdU = -bxds[0] / dbeta - 0.5;

	dim3 blk(BACK_BLKX, BACK_BLKY, BACK_BLKZ);
	dim3 gid(
		(ZN + blk.x - 1) / blk.x,
		(XN + blk.y - 1) / blk.y,
		(YN + blk.z - 1) / blk.z);

	DD3_panel_gpu_back_ker<_BRANCHLESS> << <gid, blk >> >(texObj,
		thrust::raw_pointer_cast(&vol[0]),
		thrust::raw_pointer_cast(&msk[0]),
		thrust::raw_pointer_cast(&cossinT[0]),
		make_float3(x0, y0, z0),
		S2D, make_float3(objCntIdxX, objCntIdxY, objCntIdxZ),
		dx, dz, dbeta, ddv, make_float2(detCtrIdU, detCtrIdV),
		make_int3(XN, YN, ZN), PN, static_cast<int>(squared != 0));
	thrust::copy(vol.begin(), vol.end(), hvol);
	delete[] bxds;
	delete[] byds;
	delete[] bzds;
}




__global__ void DD3_gpu_back_volumerendering_ker(
	cudaTextureObject_t texObj,
	float* vol,
	const byte* __restrict__ msk,
	const float3* __restrict__ cossinZT,
	float3 s,
	float S2D,
	float3 objCntIdx,
	float dx, float dz, float dbeta, float ddv,
	float2 detCntIdx, int3 VN, int PN, int squared)
{
	int3 id;
	id.z = __mul24(blockDim.x, blockIdx.x) + threadIdx.x;
	id.x = __mul24(blockDim.y, blockIdx.y) + threadIdx.y;
	id.y = __mul24(blockDim.z, blockIdx.z) + threadIdx.z;
	if (id.x < VN.x && id.y < VN.y && id.z < VN.z)
	{
		if (msk[id.y * VN.x + id.x] != 1)
			return;
		float3 curVox = make_float3(
			(id.x - objCntIdx.x) * dx,
			(id.y - objCntIdx.y) * dx,
			(id.z - objCntIdx.z) * dz);
		float3 boxmin = curVox - make_float3(dx, dx, dz) * 0.5;
		float3 boxmax = curVox + make_float3(dx, dx, dz) * 0.5;
		float3 dir;
		float3 cursour;
		float tnear, tfar;
		float intersectLength;
		float summ = 0;
		float sid = sqrtf(s.x * s.x + s.y * s.y);
		float idxZ;
		float idxXY;
		float3 cossinT;
		float2 ds;
		float l;
		float alpha;
		for (int angIdx = 0; angIdx < PN; ++angIdx)
		{
			cossinT = cossinZT[angIdx];
			cursour = make_float3(
				s.x * cossinT.x - s.y * cossinT.y,
				s.x * cossinT.y + s.y * cossinT.x,
				s.z + cossinT.z);
			dir = curVox - cursour;
			ds = make_float2(-cursour.x, -cursour.y);
			l = sqrtf(dir.x * dir.x + dir.y * dir.y);
			idxZ = dir.z * S2D / l / ddv + detCntIdx.y + 0.5;
			alpha = asinf((ds.x * dir.y - ds.y * dir.x) / (l * sid));
			dir = normalize(dir);
			intersectLength = intersectBox(cursour, dir, boxmin, boxmax, &tnear, &tfar);
			intersectLength *= (tfar - tnear);
			idxXY = alpha / dbeta + detCntIdx.x + 0.5;
			summ += tex3D<float>(texObj, idxZ, idxXY, angIdx + 0.5f) * intersectLength;

		}
		vol[(id.y + VN.x + id.x) * VN.z + id.z] = summ;
	}
}




template<>
__global__ void DD3_gpu_back_ker<_VOLUMERENDERING>(
	cudaTextureObject_t texObj,
	float* vol,
	const byte* __restrict__ msk,
	const float3* __restrict__ cossinZT,
	float3 s,
	float S2D,
	float3 objCntIdx,
	float dx, float dz, float dbeta, float ddv,
	float2 detCntIdx, int3 VN, int PN, int squared)
{
	int3 id;
	id.z = __mul24(blockDim.x, blockIdx.x) + threadIdx.x;
	id.x = __mul24(blockDim.y, blockIdx.y) + threadIdx.y;
	id.y = __mul24(blockDim.z, blockIdx.z) + threadIdx.z;
	if (id.x < VN.x && id.y < VN.y && id.z < VN.z)
	{
		if (msk[id.y * VN.x + id.x] != 1)
			return;
		float3 curVox = make_float3(
			(id.x - objCntIdx.x) * dx,
			(id.y - objCntIdx.y) * dx,
			(id.z - objCntIdx.z) * dz);
		float3 boxmin = curVox - make_float3(dx, dx, dz) * 0.5;
		float3 boxmax = curVox + make_float3(dx, dx, dz) * 0.5;
		float3 dir;
		float3 cursour;
		float tnear, tfar;
		float intersectLength;
		float summ = 0;
		float sid = sqrtf(s.x * s.x + s.y * s.y);
		float idxZ;
		float idxXY;
		float3 cossinT;
		float2 ds;
		float l;
		float alpha;
		for (int angIdx = 0; angIdx < PN; ++angIdx)
		{
			cossinT = cossinZT[angIdx];
			cursour = make_float3(
				s.x * cossinT.x - s.y * cossinT.y,
				s.x * cossinT.y + s.y * cossinT.x,
				s.z + cossinT.z);
			dir = curVox - cursour;
			ds = make_float2(-cursour.x, -cursour.y);
			l = sqrtf(dir.x * dir.x + dir.y * dir.y);
			idxZ = dir.z * S2D / l / ddv + detCntIdx.y + 0.5;
			alpha = asinf((ds.x * dir.y - ds.y * dir.x) / (l * sid));
			dir = normalize(dir);
			intersectLength = intersectBox(cursour, dir, boxmin, boxmax, &tnear, &tfar);
			intersectLength *= (tfar - tnear);
			idxXY = alpha / dbeta + detCntIdx.x + 0.5;
			summ += tex3D<float>(texObj, idxZ, idxXY, angIdx + 0.5f) * intersectLength;

		}
		vol[(id.y + VN.x + id.x) * VN.z + id.z] = summ;
	}
}





void DD3_gpu_back_volumerendering(float x0, float y0, float z0,
	int DNU, int DNV, float* xds,
	float* yds, float* zds,
	float imgXCenter, float imgYCenter, float imgZCenter,
	float* hangs, float* hzPos, int PN,
	int XN, int YN, int ZN,
	float* hvol, float* hprj,
	float dx, float dz, byte* mask, int squared, int gpunum)
{
	cudaSetDevice(gpunum);
	cudaDeviceReset();
	const int TOTVON = XN * YN * ZN;
	const float objCntIdxX = (XN - 1.0) * 0.5 - imgXCenter / dx;
	const float objCntIdxY = (YN - 1.0) * 0.5 - imgYCenter / dx;
	const float objCntIdxZ = (ZN - 1.0) * 0.5 - imgZCenter / dz;

	thrust::device_vector<float> vol(TOTVON, 0);
	thrust::device_vector<float3> cursour(PN);
	thrust::device_vector<float3> cossinZT(PN);
	thrust::device_vector<float2> dirsour(PN);

	thrust::device_vector<float> angs(hangs, hangs + PN);
	thrust::device_vector<float> zPos(hzPos, hzPos + PN);
	thrust::device_vector<byte> d_msk(mask, mask + XN * YN);

	thrust::transform(thrust::make_zip_iterator(thrust::make_tuple(angs.begin(), zPos.begin())),
		thrust::make_zip_iterator(thrust::make_tuple(angs.end(), zPos.end())),
		thrust::make_zip_iterator(thrust::make_tuple(
		cossinZT.begin(), cursour.begin(), dirsour.begin())),
		CTMBIR::ConstantForBackProjection3(x0, y0, z0));

	float* bxds = new float[DNU + 1];
	float* byds = new float[DNU + 1];
	float* bzds = new float[DNV + 1];
	DD3Boundaries(DNU + 1, xds, bxds);
	DD3Boundaries(DNU + 1, yds, byds);
	DD3Boundaries(DNV + 1, zds, bzds);

	float ddv = (bzds[DNV] - bzds[0]) / DNV;
	float detCtrIdxV = (-(bzds[0] - z0) / ddv) - 0.5;

	float2 dir = normalize(make_float2(-x0, -y0));
	float2 dirL = normalize(make_float2(bxds[0] - x0, byds[0] - y0));
	float2 dirR = normalize(make_float2(bxds[DNU] - x0, byds[DNU] - y0));
	float dbeta = asin(dirL.x * dirR.y - dirL.y * dirR.x) / DNU;
	float minBeta = asin(dir.x * dirL.y - dir.y * dirL.x);
	float detCtrIdxU = -minBeta / dbeta - 0.5;
	const float S2D = hypotf(xds[0] - x0, yds[0] - y0);

	cudaExtent prjSize;
	prjSize.width = DNV;
	prjSize.height = DNU;
	prjSize.depth = PN;

	cudaChannelFormatDesc channelDesc = cudaCreateChannelDesc<float>();
	cudaArray *d_prjArray;
	cudaMalloc3DArray(&d_prjArray, &channelDesc, prjSize);
	cudaMemcpy3DParms copyParams = {0};
	copyParams.srcPtr = make_cudaPitchedPtr(
		(void*) hprj, prjSize.width * sizeof(float),
		prjSize.width, prjSize.height);
	copyParams.dstArray = d_prjArray;
	copyParams.extent = prjSize;
	copyParams.kind = cudaMemcpyHostToDevice;
	cudaMemcpy3D(&copyParams);
	cudaResourceDesc resDesc;
	memset(&resDesc, 0, sizeof(resDesc));
	resDesc.resType = cudaResourceTypeArray;
	resDesc.res.array.array = d_prjArray;
	cudaTextureDesc texDesc;
	memset(&texDesc, 0, sizeof(texDesc));
	texDesc.addressMode[0] = cudaAddressModeBorder;
	texDesc.addressMode[1] = cudaAddressModeBorder;
	texDesc.addressMode[2] = cudaAddressModeBorder;
	texDesc.filterMode = cudaFilterModeLinear;
	texDesc.readMode = cudaReadModeElementType;
	cudaTextureObject_t texObj;
	texDesc.normalizedCoords = false;
	cudaCreateTextureObject(&texObj, &resDesc, &texDesc, nullptr);

	dim3 blk(BACK_BLKX, BACK_BLKY, BACK_BLKZ);
	dim3 gid(
		(ZN + blk.x - 1) / blk.x,
		(XN + blk.y - 1) / blk.y,
		(ZN + blk.z - 1) / blk.z);

	DD3_gpu_back_volumerendering_ker << <gid, blk >> >
		(texObj,
		thrust::raw_pointer_cast(&vol[0]),
		thrust::raw_pointer_cast(&d_msk[0]),
		thrust::raw_pointer_cast(&cossinZT[0]),
		make_float3(x0, y0, z0),
		S2D,
		make_float3(objCntIdxX, objCntIdxY, objCntIdxZ),
		dx, dz, dbeta, ddv,
		make_float2(detCtrIdxU, detCtrIdxV),
		make_int3(XN, YN, ZN), PN, squared);


	thrust::copy(vol.begin(), vol.end(), hvol);
	delete [] bxds;
	delete [] byds;
	delete [] bzds;
}



__global__ void DD3_gpu_back_pseudodistancedriven_ker(
	cudaTextureObject_t texObj,
	float* vol,
	const byte* __restrict__ msk,
	const float3* __restrict__ cossinZT,
	float3 s,
	float S2D,
	float3 objCntIdx,
	float dx, float dz, float dbeta, float ddv,
	float2 detCntIdx,
	int3 VN, int PN, int squared)
{
	int k = __mul24(blockIdx.x, blockDim.x) + threadIdx.x;
	int i = __mul24(blockIdx.y, blockDim.y) + threadIdx.y;
	int j = __mul24(blockIdx.z, blockDim.z) + threadIdx.z;
	if (i < VN.x && j < VN.y && k < VN.z)
	{
		if (msk[j * VN.x + i] != 1)
			return;
		float3 curVox = make_float3(
			(i - objCntIdx.x) * dx,
			(j - objCntIdx.y) * dx,
			(k - objCntIdx.z) * dz);

		float3 dir;
		float3 cursour;
		float invsid = rsqrtf(s.x * s.x + s.y * s.y);
		float invl;
		float idxZ;
		float idxXY;
		float alpha;
		float cosVal;
		float3 cossinT;
		float summ = 0;
		S2D = S2D / ddv;
		dbeta = 1.0 / dbeta;
		for (int angIdx = 0; angIdx != PN; ++angIdx)
		{
			cossinT = cossinZT[angIdx];
			cursour = make_float3(
				s.x * cossinT.x - s.y * cossinT.y,
				s.x * cossinT.y + s.y * cossinT.x,
				s.z + cossinT.z);

			dir = curVox - cursour;
			ddv = dir.x * dir.x + dir.y * dir.y;
			invl = rsqrtf(ddv);
			idxZ = dir.z * S2D * invl + detCntIdx.y + 0.5;
			alpha = asinf((cursour.y * dir.x - cursour.x * dir.y) * invl * invsid);
			if (fabsf(cursour.x) >= fabsf(cursour.y))
			{
				cosVal = fabsf(1.0 / dir.x);
			}
			else
			{
				cosVal = fabsf(1.0 / dir.y);
			}
			cosVal *= (dx * sqrtf(ddv + dir.z * dir.z));
			idxXY = alpha * dbeta + detCntIdx.x + 0.5;
			summ += tex3D<float>(texObj, idxZ, idxXY, angIdx + 0.5f) * cosVal;
		}
		__syncthreads();
		vol[(j * VN.x + i) * VN.z + k] = summ;
	}
}









template<>
__global__ void DD3_gpu_back_ker<_PSEUDODD>(
	cudaTextureObject_t texObj,
	float* vol,
	const byte* __restrict__ msk,
	const float3* __restrict__ cossinZT,
	float3 s,
	float S2D,
	float3 objCntIdx,
	float dx, float dz, float dbeta, float ddv,
	float2 detCntIdx,
	int3 VN, int PN, int squared)
{
	int k = __mul24(blockIdx.x, blockDim.x) + threadIdx.x;
	int i = __mul24(blockIdx.y, blockDim.y) + threadIdx.y;
	int j = __mul24(blockIdx.z, blockDim.z) + threadIdx.z;
	if (i < VN.x && j < VN.y && k < VN.z)
	{
		if (msk[j * VN.x + i] != 1)
			return;
		float3 curVox = make_float3(
			(i - objCntIdx.x) * dx,
			(j - objCntIdx.y) * dx,
			(k - objCntIdx.z) * dz);

		float3 dir;
		float3 cursour;
		float invsid = rsqrtf(s.x * s.x + s.y * s.y);
		float invl;
		float idxZ;
		float idxXY;
		float alpha;
		float cosVal;
		float3 cossinT;
		float summ = 0;
		S2D = S2D / ddv;
		dbeta = 1.0 / dbeta;
		for (int angIdx = 0; angIdx != PN; ++angIdx)
		{
			cossinT = cossinZT[angIdx];
			cursour = make_float3(
				s.x * cossinT.x - s.y * cossinT.y,
				s.x * cossinT.y + s.y * cossinT.x,
				s.z + cossinT.z);

			dir = curVox - cursour;
			ddv = dir.x * dir.x + dir.y * dir.y;
			invl = rsqrtf(ddv);
			idxZ = dir.z * S2D * invl + detCntIdx.y + 0.5;
			alpha = asinf((cursour.y * dir.x - cursour.x * dir.y) * invl * invsid);
			if (fabsf(cursour.x) >= fabsf(cursour.y))
			{
				cosVal = fabsf(1.0 / dir.x);
			}
			else
			{
				cosVal = fabsf(1.0 / dir.y);
			}
			cosVal *= (dx * sqrtf(ddv + dir.z * dir.z));
			idxXY = alpha * dbeta + detCntIdx.x + 0.5;
			summ += tex3D<float>(texObj, idxZ, idxXY, angIdx + 0.5f) * cosVal;
		}
		__syncthreads();
		vol[(j * VN.x + i) * VN.z + k] = summ;
	}
}





void DD3_gpu_back_pseudodistancedriven(
	float x0, float y0, float z0,
	int DNU, int DNV,
	float* xds, float* yds, float* zds,
	float imgXCenter, float imgYCenter, float imgZCenter,
	float* hangs, float* hzPos, int PN,
	int XN, int YN, int ZN,
	float* hvol, float* hprj,
	float dx, float dz,
	byte* mask, int squared, int gpunum)
{
	cudaSetDevice(gpunum);
	cudaDeviceReset();
	const int TOTVON = XN  * YN * ZN;
	const float objCntIdxX = (XN - 1.0) * 0.5 - imgXCenter / dx;
	const float objCntIdxY = (YN - 1.0) * 0.5 - imgYCenter / dx;
	const float objCntIdxZ = (ZN - 1.0) * 0.5 - imgZCenter / dz;

	thrust::device_vector<byte> d_msk(mask, mask + XN * YN);
	thrust::device_vector<float> vol(TOTVON, 0);
	thrust::device_vector<float3> cursour(PN);
	thrust::device_vector<float2> dirsour(PN);
	thrust::device_vector<float3> cossinZT(PN);

	thrust::device_vector<float> angs(hangs, hangs + PN);
	thrust::device_vector<float> zPos(hzPos, hzPos + PN);

	thrust::transform(thrust::make_zip_iterator(thrust::make_tuple(angs.begin(), zPos.begin())),
		thrust::make_zip_iterator(thrust::make_tuple(angs.end(), zPos.end())),
		thrust::make_zip_iterator(thrust::make_tuple(cossinZT.begin(), cursour.begin(), dirsour.begin())),
		CTMBIR::ConstantForBackProjection3(x0, y0, z0));

	float* bxds = new float[DNU + 1];
	float* byds = new float[DNU + 1];
	float* bzds = new float[DNV + 1];
	DD3Boundaries(DNU + 1, xds, bxds);
	DD3Boundaries(DNU + 1, yds, byds);
	DD3Boundaries(DNV + 1, zds, bzds);

	float ddv = (bzds[DNV] - bzds[0]) / DNV;
	float detCtrIdxV = (-(bzds[0] - z0) / ddv) - 0.5;

	float2 dir = normalize(make_float2(-x0, -y0));
	float2 dirL = normalize(make_float2(bxds[0] - x0, byds[0] - y0));
	float2 dirR = normalize(make_float2(bxds[DNU] - x0, byds[DNU] - y0));
	float dbeta = asin(dirL.x * dirR.y - dirL.y * dirR.x) / DNU;
	float minBeta = asin(dir.x * dirL.y - dir.y * dirL.x);
	float detCtrIdxU = -minBeta / dbeta - 0.5;
	const float S2D = hypotf(xds[0] - x0, yds[0] - y0);

	cudaExtent prjSize;
	prjSize.width = DNV;
	prjSize.height = DNU;
	prjSize.depth = PN;

	cudaChannelFormatDesc channelDesc = cudaCreateChannelDesc<float>();
	cudaArray *d_prjArray;
	cudaMalloc3DArray(&d_prjArray, &channelDesc, prjSize);
	cudaMemcpy3DParms copyParams = { 0 };
	copyParams.srcPtr = make_cudaPitchedPtr(
		(void*) hprj, prjSize.width * sizeof(float),
		prjSize.width, prjSize.height);
	copyParams.dstArray = d_prjArray;
	copyParams.extent = prjSize;
	copyParams.kind = cudaMemcpyHostToDevice;
	cudaMemcpy3D(&copyParams);
	cudaResourceDesc resDesc;
	memset(&resDesc, 0, sizeof(resDesc));
	resDesc.resType = cudaResourceTypeArray;
	resDesc.res.array.array = d_prjArray;
	cudaTextureDesc texDesc;
	memset(&texDesc, 0, sizeof(texDesc));
	texDesc.addressMode[0] = cudaAddressModeBorder;
	texDesc.addressMode[1] = cudaAddressModeBorder;
	texDesc.addressMode[2] = cudaAddressModeBorder;
	texDesc.filterMode = cudaFilterModeLinear;
	texDesc.readMode = cudaReadModeElementType;
	cudaTextureObject_t texObj;
	texDesc.normalizedCoords = false;
	cudaCreateTextureObject(&texObj, &resDesc, &texDesc, nullptr);

	dim3 blk(BACK_BLKX, BACK_BLKY, BACK_BLKZ);
	dim3 gid(
		(ZN + blk.x - 1) / blk.x,
		(XN + blk.y - 1) / blk.y,
		(YN + blk.z - 1) / blk.z);

	DD3_gpu_back_pseudodistancedriven_ker << <gid, blk >> >(texObj,
		thrust::raw_pointer_cast(&vol[0]),
		thrust::raw_pointer_cast(&d_msk[0]),
		thrust::raw_pointer_cast(&cossinZT[0]),
		make_float3(x0, y0, z0),
		S2D,
		make_float3(objCntIdxX, objCntIdxY, objCntIdxZ),
		dx, dz, dbeta, ddv,
		make_float2(detCtrIdxU, detCtrIdxV),
		make_int3(XN, YN, ZN),
		PN, static_cast<int>(squared != 0));
	thrust::copy(vol.begin(), vol.end(), hvol);
	delete [] bxds;
	delete [] byds;
	delete [] bzds;
}



template<int LAYERS>
__global__ void DD3_gpu_back_zlinebasedbranchless_ker(
	cudaTextureObject_t prjTexObj,
	float* vol,
	const byte* __restrict__ msk,
	const float3* __restrict__ cossinZT,
	float3 s,
	float S2D,
	float3 objCntIdx,
	float dx, float dz, float dbeta, float ddv,
	float2 detCntIdx, int3 VN, int PN, int squared)
{
	int idx = threadIdx.x + __umul24(blockIdx.x, blockDim.x);
	int idy = threadIdx.y + __umul24(blockIdx.y, blockDim.y);
	__shared__ float summ[4][8][LAYERS + 1];
#pragma unroll
	for (int i = 0; i <= LAYERS; ++i)
	{
		summ[threadIdx.y][threadIdx.x][i] = 0;
	}
	__syncthreads();
	if (idx < VN.x && idy < VN.y)
	{
		if (msk[idy * VN.x + idx] != 1)
			return;
		float curang(0);
		float2 dirlft, dirrgh;
		float3 cursour;
		float idxL, idxR, idxD;
		float cosVal = 1.0;
		float2 curvox_xy = make_float2((idx - objCntIdx.x) * dx, (idy - objCntIdx.y) * dx);
		float2 dirxy;
		int LPs = VN.z / LAYERS;
		float dirZ;
		float minObj = 0;
		float s2vlength = 0;
		float3 cossinT;
		S2D = S2D / ddv;
		dbeta = 1.0 / dbeta;
		float invSID = rsqrtf(s.x * s.x + s.y * s.y);
		for (int lpIdx = 0; lpIdx != LPs; ++lpIdx)
		{
			minObj = (-objCntIdx.z + lpIdx * LAYERS) * dz;
			for (int angIdx = 0; angIdx < PN; ++angIdx)
			{
				cossinT = cossinZT[angIdx];
				cursour = make_float3(
					s.x * cossinT.x - s.y * cossinT.y,
					s.x * cossinT.y + s.y * cossinT.x,
					s.z + cossinT.z);
				dirxy.x = curvox_xy.x - cursour.x;
				dirxy.y = curvox_xy.y - cursour.y;
				s2vlength = hypotf(dirxy.x, dirxy.y);

				if (fabsf(cossinT.x) <= fabsf(cossinT.y))
				{
					dirlft = normalize(make_float2(dirxy.x, dirxy.y - 0.5 * dx));
					dirrgh = normalize(make_float2(dirxy.x, dirxy.y + 0.5 * dx));
					cosVal = (dx * s2vlength / dirxy.x);
				}
				else
				{
					dirlft = normalize(make_float2(dirxy.x + 0.5f * dx, dirxy.y));
					dirrgh = normalize(make_float2(dirxy.x - 0.5f * dx, dirxy.y));
					cosVal = (dx * s2vlength / dirxy.y);
				}
				idxL = asinf((cursour.y * dirlft.x - cursour.x * dirlft.y) * invSID) * dbeta + detCntIdx.x + 1;
				idxR = asinf((cursour.y * dirrgh.x - cursour.x * dirrgh.y) * invSID) * dbeta + detCntIdx.x + 1;
				curang = S2D / s2vlength;
#pragma unroll
				for (int idz = 0; idz <= LAYERS; ++idz)
				{
					dirZ = minObj + idz * dz - cursour.z;
					ddv = hypotf(dirZ, s2vlength) / s2vlength;
					idxD = (dirZ - 0.5 * dz) * curang + detCntIdx.y + 1;
					summ[threadIdx.y][threadIdx.x][idz] +=
						(tex3D<float>(prjTexObj, idxD, idxR, angIdx + 0.5) -
						tex3D<float>(prjTexObj, idxD, idxL, angIdx + 0.5)) * cosVal * ddv;
				}
			}
			__syncthreads();
			int vIdx = (idy * VN.x + idx) * VN.z + (lpIdx * LAYERS);
#pragma unroll
			for (int idz = 0; idz < LAYERS; ++idz)
			{
				vol[vIdx + idz] = summ[threadIdx.y][threadIdx.x][idz + 1] - summ[threadIdx.y][threadIdx.x][idz];
				summ[threadIdx.y][threadIdx.x][idz] = 0;
			}
			summ[threadIdx.y][threadIdx.x][LAYERS] = 0;
			__syncthreads();
		}
	}
}
















template<>
__global__ void DD3_gpu_back_ker<_ZLINEBRANCHLESS>(
	cudaTextureObject_t prjTexObj,
	float* vol,
	const byte* __restrict__ msk,
	const float3* __restrict__ cossinZT,
	float3 s,
	float S2D,
	float3 objCntIdx,
	float dx, float dz, float dbeta, float ddv,
	float2 detCntIdx, int3 VN, int PN, int squared)
{
	int idx = threadIdx.x + __umul24(blockIdx.x, blockDim.x);
	int idy = threadIdx.y + __umul24(blockIdx.y, blockDim.y);
	__shared__ float summ[4][8][17];
#pragma unroll
	for (int i = 0; i <= 16; ++i)
	{
		summ[threadIdx.y][threadIdx.x][i] = 0;
	}
	__syncthreads();
	if (idx < VN.x && idy < VN.y)
	{
		if (msk[idy * VN.x + idx] != 1)
			return;
		float curang(0);
		float2 dirlft, dirrgh;
		float3 cursour;
		float idxL, idxR, idxD;
		float cosVal = 1.0;
		float2 curvox_xy = make_float2((idx - objCntIdx.x) * dx, (idy - objCntIdx.y) * dx);
		float2 dirxy;
		int LPs = VN.z >> 4;
		float dirZ;
		float minObj = 0;
		float s2vlength = 0;
		float3 cossinT;
		S2D = S2D / ddv;
		dbeta = 1.0 / dbeta;
		float invSID = rsqrtf(s.x * s.x + s.y * s.y);
		for (int lpIdx = 0; lpIdx != LPs; ++lpIdx)
		{
			minObj = (-objCntIdx.z + lpIdx * 16) * dz;
			for (int angIdx = 0; angIdx < PN; ++angIdx)
			{
				cossinT = cossinZT[angIdx];
				cursour = make_float3(
					s.x * cossinT.x - s.y * cossinT.y,
					s.x * cossinT.y + s.y * cossinT.x,
					s.z + cossinT.z);
				dirxy.x = curvox_xy.x - cursour.x;
				dirxy.y = curvox_xy.y - cursour.y;
				s2vlength = hypotf(dirxy.x, dirxy.y);

				if (fabsf(cossinT.x) <= fabsf(cossinT.y))
				{
					dirlft = normalize(make_float2(dirxy.x, dirxy.y - 0.5 * dx));
					dirrgh = normalize(make_float2(dirxy.x, dirxy.y + 0.5 * dx));
					cosVal = (dx * s2vlength / dirxy.x);
				}
				else
				{
					dirlft = normalize(make_float2(dirxy.x + 0.5f * dx, dirxy.y));
					dirrgh = normalize(make_float2(dirxy.x - 0.5f * dx, dirxy.y));
					cosVal = (dx * s2vlength / dirxy.y);
				}
				idxL = asinf((cursour.y * dirlft.x - cursour.x * dirlft.y) * invSID) * dbeta + detCntIdx.x + 1;
				idxR = asinf((cursour.y * dirrgh.x - cursour.x * dirrgh.y) * invSID) * dbeta + detCntIdx.x + 1;
				curang = S2D / s2vlength;
#pragma unroll
				for (int idz = 0; idz <= 16; ++idz)
				{
					dirZ = minObj + idz * dz - cursour.z;
					ddv = hypotf(dirZ, s2vlength) / s2vlength;
					idxD = (dirZ - 0.5 * dz) * curang + detCntIdx.y + 1;
					summ[threadIdx.y][threadIdx.x][idz] +=
						(tex3D<float>(prjTexObj, idxD, idxR, angIdx + 0.5) -
						tex3D<float>(prjTexObj, idxD, idxL, angIdx + 0.5)) * cosVal * ddv;
				}
			}
			__syncthreads();
			int vIdx = (idy * VN.x + idx) * VN.z + (lpIdx << 4);
#pragma unroll
			for (int idz = 0; idz < 16; ++idz)
			{
				vol[vIdx + idz] = summ[threadIdx.y][threadIdx.x][idz + 1] - summ[threadIdx.y][threadIdx.x][idz];
				summ[threadIdx.y][threadIdx.x][idz] = 0;
			}
			summ[threadIdx.y][threadIdx.x][16] = 0;
			__syncthreads();
		}
	}
}

void DD3_gpu_back_zlinebasedbranchless(
	float x0, float y0, float z0,
	int DNU, int DNV,
	float* xds, float* yds, float* zds,
	float imgXCenter, float imgYCenter, float imgZCenter,
	float* hangs, float* hzPos, int PN,
	int XN, int YN, int ZN,
	float* hvol, float* hprj, float dx, float dz,
	byte* mask, int squared, int gpunum)
{
	cudaSetDevice(gpunum);
	cudaDeviceReset();
	const int TOTVON = XN * YN * ZN;
	const float objCntIdxX = (XN - 1.0) * 0.5 - imgXCenter / dx;
	const float objCntIdxY = (YN - 1.0) * 0.5 - imgYCenter / dx;
	const float objCntIdxZ = (ZN - 1.0) * 0.5 - imgZCenter / dz;

	thrust::device_vector<float> prjSAT(genSAT_of_Projection(hprj, DNU, DNV, PN));
	cudaExtent prjSize;
	prjSize.width = DNV + 1;
	prjSize.height = DNU + 1;
	prjSize.depth = PN;

	cudaChannelFormatDesc channelDesc = cudaCreateChannelDesc<float>();
	cudaArray *d_prjSATarray;
	cudaMalloc3DArray(&d_prjSATarray, &channelDesc, prjSize);
	cudaMemcpy3DParms copyParams = { 0 };
	copyParams.srcPtr = make_cudaPitchedPtr(
		(void*) thrust::raw_pointer_cast(&prjSAT[0]), prjSize.width * sizeof(float),
		prjSize.width, prjSize.height);
	copyParams.dstArray = d_prjSATarray;
	copyParams.extent = prjSize;
	copyParams.kind = cudaMemcpyDeviceToDevice;
	cudaMemcpy3D(&copyParams);
	cudaResourceDesc resDesc;
	memset(&resDesc, 0, sizeof(resDesc));
	resDesc.resType = cudaResourceTypeArray;
	resDesc.res.array.array = d_prjSATarray;
	cudaTextureDesc texDesc;
	memset(&texDesc, 0, sizeof(texDesc));
	texDesc.addressMode[0] = cudaAddressModeClamp;
	texDesc.addressMode[1] = cudaAddressModeClamp;
	texDesc.addressMode[2] = cudaAddressModeClamp;
	texDesc.filterMode = cudaFilterModeLinear;
	texDesc.readMode = cudaReadModeElementType;
	cudaTextureObject_t texObj;
	texDesc.normalizedCoords = false;
	cudaCreateTextureObject(&texObj, &resDesc, &texDesc, nullptr);
	prjSAT.clear();

	float* bxds = new float[DNU + 1];
	float* byds = new float[DNU + 1];
	float* bzds = new float[DNV + 1];

	DD3Boundaries(DNU + 1, xds, bxds);
	DD3Boundaries(DNU + 1, yds, byds);
	DD3Boundaries(DNV + 1, zds, bzds);

	float ddv = (bzds[DNV] - bzds[0]) / DNV;
	float detCtrIdxV = (-(bzds[0] - z0) / ddv) - 0.5;

	float2 dir = normalize(make_float2(-x0, -y0));
	float2 dirL = normalize(make_float2(bxds[0] - x0, byds[0] - y0));
	float2 dirR = normalize(make_float2(bxds[DNU] - x0, byds[DNU] - y0));
	float dbeta = asin(dirL.x * dirR.y - dirL.y * dirR.x) / DNU;
	float minBeta = asin(dir.x * dirL.y - dir.y * dirL.x);
	float detCtrIdxU = -minBeta / dbeta - 0.5;
	const float S2D = hypotf(xds[0] - x0, yds[0] - y0);

	thrust::device_vector<float> angs(hangs, hangs + PN);
	thrust::device_vector<float> zPos(hzPos, hzPos + PN);

	float3 sour(make_float3(x0, y0, z0));
	thrust::device_vector<float> vol(TOTVON, 0);
	thrust::device_vector<float3> cursour(PN);
	thrust::device_vector<float2> dirsour(PN);
	thrust::device_vector<float3> cossinZT(PN);


	thrust::transform(
		thrust::make_zip_iterator(thrust::make_tuple(angs.begin(), zPos.begin())),
		thrust::make_zip_iterator(thrust::make_tuple(angs.end(), zPos.end())),
		thrust::make_zip_iterator(thrust::make_tuple(cossinZT.begin(), cursour.begin(), dirsour.begin())),
		CTMBIR::ConstantForBackProjection3(x0, y0, z0));
	thrust::device_vector<byte> msk(mask, mask + XN * YN);
	dim3 blk_(8, 4);
	dim3 gid_(
		(XN + blk_.x - 1) / blk_.x,
		(YN + blk_.y - 1) / blk_.y);

	DD3_gpu_back_zlinebasedbranchless_ker<16> << <gid_, blk_ >> >(texObj,
		thrust::raw_pointer_cast(&vol[0]),
		thrust::raw_pointer_cast(&msk[0]),
		thrust::raw_pointer_cast(&cossinZT[0]),
		make_float3(x0, y0, z0),
		S2D,
		make_float3(objCntIdxX, objCntIdxY, objCntIdxZ),
		dx, dz, dbeta, ddv, make_float2(detCtrIdxU, detCtrIdxV),
		make_int3(XN, YN, ZN), PN, squared);

	thrust::copy(vol.begin(), vol.end(), hvol);


}


template<BackProjectionMethod METHOD>
void DD3_gpu_back(
	float x0, float y0, float z0,
	int DNU, int DNV,
	float* xds, float* yds, float* zds,
	float imgXCenter, float imgYCenter, float imgZCenter,
	float* hangs, float* hzPos, int PN,
	int XN, int YN, int ZN,
	float* hvol, float* hprj, float dx, float dz,
	byte* mask, int squared, int gpunum)
{
	cudaSetDevice(gpunum);
	cudaDeviceReset();
	//std::cout << gpunum << "\n";

	float3 objCntIdx = make_float3(
		(XN - 1.0) * 0.5 - imgXCenter / dx,
		(YN - 1.0) * 0.5 - imgYCenter / dx,
		(ZN - 1.0) * 0.5 - imgZCenter / dz);
	float3 sour = make_float3(x0, y0, z0);
	thrust::device_vector<byte> msk(mask, mask + XN * YN);
	thrust::device_vector<float> vol(XN * YN * ZN, 0);
	const float S2D = hypotf(xds[0] - x0, yds[0] - y0);

	thrust::device_vector<float3> cossinZT(PN);
	thrust::device_vector<float> angs(hangs, hangs + PN);
	thrust::device_vector<float> zPos(hzPos, hzPos + PN);
	thrust::transform(
		thrust::make_zip_iterator(thrust::make_tuple(angs.begin(), zPos.begin())),
		thrust::make_zip_iterator(thrust::make_tuple(angs.end(), zPos.end())),
		cossinZT.begin(),
		CTMBIR::ConstantForBackProjection4(x0, y0, z0));
	float4 detParas = calDetParas(xds, yds, zds, x0, y0, z0, DNU, DNV);
	cudaArray* d_prjArray = nullptr;
	cudaTextureObject_t texObj;
	dim3 blk;
	dim3 gid;
	thrust::device_vector<float> prjSAT;
	switch (METHOD)
	{
	case _PSEUDODD:
	case _VOLUMERENDERING:
		createTextureObject(texObj, d_prjArray, DNV, DNU, PN, hprj, cudaMemcpyHostToDevice,
			cudaAddressModeBorder, cudaFilterModeLinear, cudaReadModeElementType, false);
		blk.x = BACK_BLKX;
		blk.y = BACK_BLKY;
		blk.z = BACK_BLKZ;
		gid.x = (ZN + blk.x - 1) / blk.x;
		gid.y = (XN + blk.y - 1) / blk.y;
		gid.z = (YN + blk.z - 1) / blk.z;
		break;
	case _BRANCHLESS:
		prjSAT = genSAT_of_Projection(hprj, DNU, DNV, PN);
		createTextureObject(texObj, d_prjArray, DNV + 1, DNU + 1, PN,
			thrust::raw_pointer_cast(&prjSAT[0]),
			cudaMemcpyDeviceToDevice,
			cudaAddressModeClamp, cudaFilterModeLinear, cudaReadModeElementType, false);
		prjSAT.clear();
		blk.x = BACK_BLKX;
		blk.y = BACK_BLKY;
		blk.z = BACK_BLKZ;
		gid.x = (ZN + blk.x - 1) / blk.x;
		gid.y = (XN + blk.y - 1) / blk.y;
		gid.z = (YN + blk.z - 1) / blk.z;
		break;
	case _ZLINEBRANCHLESS:
		prjSAT = genSAT_of_Projection(hprj, DNU, DNV, PN);
		createTextureObject(texObj, d_prjArray, DNV + 1, DNU + 1, PN,
			thrust::raw_pointer_cast(&prjSAT[0]),
			cudaMemcpyDeviceToDevice,
			cudaAddressModeClamp, cudaFilterModeLinear, cudaReadModeElementType, false);
		prjSAT.clear();
		blk.x = 8;
		blk.y = 4;
		blk.z = 1;
		gid.x = (XN + blk.x - 1) / blk.x;
		gid.y = (YN + blk.y - 1) / blk.y;
		break;
	default:
		prjSAT = genSAT_of_Projection(hprj, DNU, DNV, PN);
		createTextureObject(texObj, d_prjArray, DNV + 1, DNU + 1, PN,
			thrust::raw_pointer_cast(&prjSAT[0]),
			cudaMemcpyDeviceToDevice,
			cudaAddressModeClamp, cudaFilterModeLinear, cudaReadModeElementType, false);
		prjSAT.clear();
		blk.x = BACK_BLKX;
		blk.y = BACK_BLKY;
		blk.z = BACK_BLKZ;
		gid.x = (ZN + blk.x - 1) / blk.x;
		gid.y = (XN + blk.y - 1) / blk.y;
		gid.z = (YN + blk.z - 1) / blk.z;
		break;
	}


	DD3_gpu_back_ker<METHOD> << <gid, blk >> >(texObj,
		thrust::raw_pointer_cast(&vol[0]),
		thrust::raw_pointer_cast(&msk[0]),
		thrust::raw_pointer_cast(&cossinZT[0]),
		make_float3(x0, y0, z0),
		S2D,
		make_float3(objCntIdx.x, objCntIdx.y, objCntIdx.z),
		dx, dz, detParas.z, detParas.w, make_float2(detParas.x, detParas.y),
		make_int3(XN, YN, ZN), PN, squared);
	copy(vol.begin(), vol.end(), hvol);

	destroyTextureObject(texObj, d_prjArray);

	vol.clear();
	msk.clear();
	angs.clear();
	zPos.clear();
	cossinZT.clear();
}


//
//
//void DD3_gpu_back_BRANCHLESS(
//	float x0, float y0, float z0,
//	int DNU, int DNV,
//	const thrust::device_vector<float>& xds,
//	const thrust::device_vector<float>& yds,
//	const thrust::device_vector<float>& zds,
//	float imgXCenter, float imgYCenter, float imgZCenter,
//	const thrust::device_vector<float>& angs,
//	const thrust::device_vector<float>& zPos, int PN,
//	int XN, int YN, int ZN,
//	thrust::device_vector<float>& vol,
//	const thrust::device_vector<float>& prj, float dx, float dz,
//	const thrust::device_vector<byte>& msk, int squared, int gpunum)
//{
//	//cudaSetDevice(gpunum);//?
//	//cudaDeviceReset();
//
//
//	float3 objCntIdx = make_float3(
//		(XN - 1.0) * 0.5 - imgXCenter / dx,
//		(YN - 1.0) * 0.5 - imgYCenter / dx,
//		(ZN - 1.0) * 0.5 - imgZCenter / dz);
//	float3 sour = make_float3(x0, y0, z0);
//
//	const float S2D = hypotf(xds[0] - x0, yds[0] - y0);
//
//	thrust::device_vector<float3> cossinZT(PN);
//
//	thrust::transform(
//		thrust::make_zip_iterator(thrust::make_tuple(angs.begin(), zPos.begin())),
//		thrust::make_zip_iterator(thrust::make_tuple(angs.end(), zPos.end())),
//		cossinZT.begin(),
//		CTMBIR::ConstantForBackProjection4(x0, y0, z0));
//	float4 detParas = calDetParas_alreadyinGPU(xds, yds, zds, x0, y0, z0, DNU, DNV);
//	cudaArray* d_prjArray = nullptr;
//	cudaTextureObject_t texObj;
//	dim3 blk;
//	dim3 gid;
//	thrust::device_vector<float> prjSAT = genSAT_of_Projection_alreadyinGPU(prj, DNU, DNV, PN);
//	createTextureObject(texObj, d_prjArray, DNV + 1, DNU + 1, PN,
//		thrust::raw_pointer_cast(&prjSAT[0]),
//		cudaMemcpyDeviceToDevice,
//		cudaAddressModeClamp, cudaFilterModeLinear, cudaReadModeElementType, false);
//
//	prjSAT.clear();
//	blk.x = BACK_BLKX;
//	blk.y = BACK_BLKY;
//	blk.z = BACK_BLKZ;
//	gid.x = (ZN + blk.x - 1) / blk.x;
//	gid.y = (XN + blk.y - 1) / blk.y;
//	gid.z = (YN + blk.z - 1) / blk.z;
//
//
//	DD3_gpu_back_ker<_BRANCHLESS> << <gid, blk >> >(texObj,
//		thrust::raw_pointer_cast(&vol[0]),
//		thrust::raw_pointer_cast(&msk[0]),
//		thrust::raw_pointer_cast(&cossinZT[0]),
//		make_float3(x0, y0, z0),
//		S2D,
//		make_float3(objCntIdx.x, objCntIdx.y, objCntIdx.z),
//		dx, dz, detParas.z, detParas.w, make_float2(detParas.x, detParas.y),
//		make_int3(XN, YN, ZN), PN, squared);
//	//copy(vol.begin(), vol.end(), hvol);
//
//	destroyTextureObject(texObj, d_prjArray);
//
//
//	cossinZT.clear();
//}
//


extern "C"
void DD3Back_gpu(
float x0, float y0, float z0,
int DNU, int DNV,
float* xds, float* yds, float* zds,
float imgXCenter, float imgYCenter, float imgZCenter,
float* hangs, float* hzPos, int PN,
int XN, int YN, int ZN,
float* hvol, float* hprj,
float dx, float dz,
byte* mask, int gpunum, int squared, int prjMode)
{
	switch (prjMode)
	{
	case 0:
		DD3_gpu_back<_BRANCHLESS>(x0, y0, z0, DNU, DNV, xds, yds, zds, imgXCenter, imgYCenter, imgZCenter,
			hangs, hzPos, PN, XN, YN, ZN, hvol, hprj, dx, dz, mask, squared, gpunum);
		break;
	case 1:
		DD3_gpu_back<_VOLUMERENDERING>(x0, y0, z0, DNU, DNV, xds, yds, zds, imgXCenter, imgYCenter, imgZCenter,
			hangs, hzPos, PN, XN, YN, ZN, hvol, hprj, dx, dz, mask, squared, gpunum);
		break;
	case 2:
		DD3_gpu_back<_PSEUDODD>(x0, y0, z0, DNU, DNV, xds, yds, zds, imgXCenter, imgYCenter, imgZCenter,
			hangs, hzPos, PN, XN, YN, ZN, hvol, hprj, dx, dz, mask, squared, gpunum);
		break;
	case 3:
		DD3_gpu_back<_ZLINEBRANCHLESS>(x0, y0, z0, DNU, DNV, xds, yds, zds, imgXCenter, imgYCenter, imgZCenter,
			hangs, hzPos, PN, XN, YN, ZN, hvol, hprj, dx, dz, mask, squared, gpunum);
		break;
	default:
		DD3_gpu_back<_BRANCHLESS>(x0, y0, z0, DNU, DNV, xds, yds, zds, imgXCenter, imgYCenter, imgZCenter,
			hangs, hzPos, PN, XN, YN, ZN, hvol, hprj, dx, dz, mask, squared, gpunum);
		break;
	}
}

//
//void DD3Back_gpu_alreadyinGPU(
//float x0, float y0, float z0,
//int DNU, int DNV,
//const thrust::device_vector<float>& xds, const thrust::device_vector<float>& yds, const thrust::device_vector<float>& zds,
//float imgXCenter, float imgYCenter, float imgZCenter,
//const thrust::device_vector<float>& hangs, const thrust::device_vector<float>& hzPos, int PN,
//int XN, int YN, int ZN,
// thrust::device_vector<float>& hvol, const thrust::device_vector<float>& hprj,
//float dx, float dz,
//const thrust::device_vector<byte>& mask, int gpunum, int squared, int prjMode)
//{
//	DD3_gpu_back_BRANCHLESS(x0, y0, z0, DNU, DNV, xds, yds, zds, imgXCenter, imgYCenter, imgZCenter,
//				hangs, hzPos, PN, XN, YN, ZN, hvol, hprj, dx, dz, mask, squared, 0);
//}
//




extern "C"
void DD3BackHelical_3GPU(
	float x0, float y0, float z0,
	int DNU, int DNV,
	float* xds, float* yds, float* zds,
	float imgXCenter, float imgYCenter, float imgZCenter,
	float* hangs, float* hzPos, int PN,
	int XN, int YN, int ZN,
	float* hvol, float* hprj,
	float dx, float dz,
	byte* mask, int methodId, int (&startVOL)[3])
{
	thrust::host_vector<float> h_angs(hangs,hangs+PN);
	thrust::host_vector<float> h_zPos(hzPos,hzPos+PN);

	int ObjZIdx_Start[3] = {startVOL[0], startVOL[1], startVOL[2]};
	int ObjZIdx_End[3] = {startVOL[1], startVOL[2], ZN};

	int prjIdx_Start[3] = {0, 0, 0};
	int prjIdx_End[3] = {0, 0, 0};

	float objCntIdxZ = (ZN - 1.0) / 2.0 - imgZCenter / dz; //object center in Z direction
	float detStpZ = zds[1] - zds[0]; // detector cell height
	float detCntIdxV = -zds[0] / detStpZ; // Detector center along Z direction

	int SZN[3] = {startVOL[1] - startVOL[0], startVOL[2] - startVOL[1], ZN - startVOL[2]};

	float** subVol = new float*[3];
	subVol[0] = new float[XN * YN * SZN[0]];
	subVol[1] = new float[XN * YN * SZN[1]];
	subVol[2] = new float[XN * YN * SZN[2]];

	float subImgZCenter[3];//
	int SPN[3];

	omp_set_num_threads(3);
#pragma omp parallel for
	for(int i = 0; i < 3; ++i)
	{
		getSubVolume<float>(hvol, XN * YN, ZN,
				ObjZIdx_Start[i], ObjZIdx_End[i],
				subVol[i]);
		getPrjIdxPair<float>(h_zPos, ObjZIdx_Start[i], ObjZIdx_End[i],
						objCntIdxZ, dz, ZN, detCntIdxV, detStpZ, DNV, prjIdx_Start[i], prjIdx_End[i]);
		SPN[i] = prjIdx_End[i] - prjIdx_Start[i];
		std::cout<<i<<" "<<prjIdx_Start[i]<<" "<<prjIdx_End[i]<<"\n";

		subImgZCenter[i] = ((ObjZIdx_End[i] + ObjZIdx_Start[i] - (ZN - 1.0)) * dz + imgZCenter * 2.0) / 2.0;

	}
	int prefixSPN[3] = {prjIdx_Start[0], prjIdx_Start[1], prjIdx_Start[2]};

//	//Not implemented yet.o
#pragma omp parallel for
	for(int i = 0; i < 3; ++i)
	{
		DD3Back_gpu(x0, y0, z0, DNU, DNV, xds, yds, zds,
				imgXCenter, imgYCenter, subImgZCenter[i],
				hangs + prefixSPN[i] , hzPos + prefixSPN[i],
				SPN[i],	XN, YN, SZN[i], subVol[i],
				hprj + DNU * DNV * prefixSPN[i],dx,dz,mask,i,0,methodId);
	}

	//Gather the volumes together
	combineVolume<float>(hvol,XN,YN,ZN,subVol,SZN,3);
	delete[] subVol[0];
	delete[] subVol[1];
	delete[] subVol[2];
	delete[] subVol;


}


extern "C"
void DD3BackHelical_4GPU(
	float x0, float y0, float z0,
	int DNU, int DNV,
	float* xds, float* yds, float* zds,
	float imgXCenter, float imgYCenter, float imgZCenter,
	float* hangs, float* hzPos, int PN,
	int XN, int YN, int ZN,
	float* hvol, float* hprj,
	float dx, float dz,
	byte* mask, int methodId, int (&startVOL)[4])
{
	thrust::host_vector<float> h_angs(hangs,hangs+PN);
	thrust::host_vector<float> h_zPos(hzPos,hzPos+PN);

	int ObjZIdx_Start[4] = {startVOL[0], startVOL[1], startVOL[2], startVOL[3]};
	int ObjZIdx_End[4] = {startVOL[1], startVOL[2], startVOL[3], ZN};

	int prjIdx_Start[4] = {0, 0, 0, 0};
	int prjIdx_End[4] = {0, 0, 0, 0};

	float objCntIdxZ = (ZN - 1.0) / 2.0 - imgZCenter / dz; //object center in Z direction
	float detStpZ = zds[1] - zds[0]; // detector cell height
	float detCntIdxV = -zds[0] / detStpZ; // Detector center along Z direction

	int SZN[4] = {startVOL[1] - startVOL[0], startVOL[2] - startVOL[1], startVOL[3] - startVOL[2], ZN - startVOL[3]};

	float** subVol = new float*[4];
	subVol[0] = new float[XN * YN * SZN[0]];
	subVol[1] = new float[XN * YN * SZN[1]];
	subVol[2] = new float[XN * YN * SZN[2]];
	subVol[3] = new float[XN * YN * SZN[3]];

	float subImgZCenter[4];//
	int SPN[4];

	omp_set_num_threads(4);
#pragma omp parallel for
	for(int i = 0; i < 4; ++i)
	{
		getSubVolume<float>(hvol, XN * YN, ZN,
				ObjZIdx_Start[i], ObjZIdx_End[i],
				subVol[i]);
		getPrjIdxPair<float>(h_zPos, ObjZIdx_Start[i], ObjZIdx_End[i],
						objCntIdxZ, dz, ZN, detCntIdxV, detStpZ, DNV, prjIdx_Start[i], prjIdx_End[i]);
		SPN[i] = prjIdx_End[i] - prjIdx_Start[i];
		std::cout<<i<<" "<<prjIdx_Start[i]<<" "<<prjIdx_End[i]<<"\n";

		subImgZCenter[i] = ((ObjZIdx_End[i] + ObjZIdx_Start[i] - (ZN - 1.0)) * dz + imgZCenter * 2.0) / 2.0;

	}
	int prefixSPN[4] = {prjIdx_Start[0], prjIdx_Start[1], prjIdx_Start[2], prjIdx_Start[3]};

//	//Not implemented yet.o
#pragma omp parallel for
	for(int i = 0; i < 4; ++i)
	{
		DD3Back_gpu(x0, y0, z0, DNU, DNV, xds, yds, zds,
				imgXCenter, imgYCenter, subImgZCenter[i],
				hangs + prefixSPN[i] , hzPos + prefixSPN[i],
				SPN[i],	XN, YN, SZN[i], subVol[i],
				hprj + DNU * DNV * prefixSPN[i],dx,dz,mask,i,0,methodId);
	}

	//Gather the volumes together
	combineVolume<float>(hvol,XN,YN,ZN,subVol,SZN,4);
	delete[] subVol[0];
	delete[] subVol[1];
	delete[] subVol[2];
	delete[] subVol[3];
	delete[] subVol;


}


