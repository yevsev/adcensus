extern "C" {
	#include "lua.h"
	#include "lualib.h"
	#include "lauxlib.h"
}

#include "luaT.h"
#include "THC.h"

#include <stdio.h>
#include <assert.h>
#include "cublas_v2.h"
#include <math_constants.h>

#define TB 128

void checkCudaError(lua_State *L) {
	cudaError_t status = cudaPeekAtLastError();
	if (status != cudaSuccess) {
		luaL_error(L, cudaGetErrorString(status));
	}
}

__global__ void ad(float *x0, float *x1, float *output, int size, int size3, int size23)
{
	int id = blockIdx.x * blockDim.x + threadIdx.x;

	if (id < size) {
		int d = id;
		int x = d % size3;
		int xy = d % size23;
		d /= size23;

		float dist = 0;
		if (x - d < 0) {
			dist = CUDART_INF;
		} else {
			for (int i = 0; i < 3; i++) {
				int ind = i * size23 + xy;
				dist += fabsf(x0[ind] - x1[ind - d]);
			}
		}
		output[id] = dist / 3;
	}
}

int ad(lua_State *L)
{
	THCudaTensor *x0 = (THCudaTensor*)luaT_checkudata(L, 1, "torch.CudaTensor");
	THCudaTensor *x1 = (THCudaTensor*)luaT_checkudata(L, 2, "torch.CudaTensor");
	THCudaTensor *output = (THCudaTensor*)luaT_checkudata(L, 3, "torch.CudaTensor");

	ad<<<(THCudaTensor_nElement(output) - 1) / TB + 1, TB>>>(
		THCudaTensor_data(x0),
		THCudaTensor_data(x1),
		THCudaTensor_data(output),
		THCudaTensor_nElement(output),
		THCudaTensor_size(output, 3),
		THCudaTensor_size(output, 2) * THCudaTensor_size(output, 3));
	checkCudaError(L);
	return 0;
}


__global__ void census(float *x0, float *x1, float *output, int size, int size2, int size3)
{
	int id = blockIdx.x * blockDim.x + threadIdx.x;

	if (id < size) {
		int d = id;
		int x = d % size3;
		d /= size3;
		int y = d % size2;
		d /= size2;

		float dist;
		if (x - d < 0) {
			dist = CUDART_INF;
		} else {
			dist = 0;
			for (int i = 0; i < 3; i++) {
				int ind_p = (i * size2 + y) * size3 + x;
				for (int yy = y - 3; yy <= y + 3; yy++) {
					for (int xx = x - 4; xx <= x + 4; xx++) {
						if (0 <= xx - d && xx < size3 && 0 <= yy && yy < size2) {
							int ind_q = (i * size2 + yy) * size3 + xx;
							if ((x0[ind_q] < x0[ind_p]) != (x1[ind_q - d] < x1[ind_p - d])) {
								dist++;
							}
						} else {
							dist++;
						}
					}
				}
			}
		}
		output[id] = dist / 3;
	}
}


int census(lua_State *L)
{
	THCudaTensor *x0 = (THCudaTensor*)luaT_checkudata(L, 1, "torch.CudaTensor");
	THCudaTensor *x1 = (THCudaTensor*)luaT_checkudata(L, 2, "torch.CudaTensor");
	THCudaTensor *output = (THCudaTensor*)luaT_checkudata(L, 3, "torch.CudaTensor");

	census<<<(THCudaTensor_nElement(output) - 1) / TB + 1, TB>>>(
		THCudaTensor_data(x0),
		THCudaTensor_data(x1),
		THCudaTensor_data(output),
		THCudaTensor_nElement(output),
		THCudaTensor_size(output, 2),
		THCudaTensor_size(output, 3));
	checkCudaError(L);
	return 0;
}

__global__ void spatial_argmin(float *input, float *output, int size, int size1, int size23)
{
	int id = blockIdx.x * blockDim.x + threadIdx.x;
	if (id < size) {
		int dim23 = id % size23;
		int dim0 = id / size23;

		int argmin = 0;
		float min = 2e38;
		for (int i = 0; i < size1; i++) {
			float val = input[(dim0 * size1 + i) * size23 + dim23];
			if (val < min) {
				min = val;
				argmin = i;
			}
		}
		output[id] = argmin + 1;
	}
}

int spatial_argmin(lua_State *L)
{
	THCudaTensor *input = (THCudaTensor*)luaT_checkudata(L, 1, "torch.CudaTensor");
	THCudaTensor *output = (THCudaTensor*)luaT_checkudata(L, 2, "torch.CudaTensor");

	spatial_argmin<<<(THCudaTensor_nElement(output) - 1) / TB + 1, TB>>>(
		THCudaTensor_data(input),
		THCudaTensor_data(output),
		THCudaTensor_nElement(output),
		THCudaTensor_size(input, 1),
		THCudaTensor_size(input, 2) * THCudaTensor_size(output, 3));
	checkCudaError(L);
	return 0;
}

/* median 3x3 filter */
__global__ void median3(float *img, float *out, int size, int height, int width)
{
	int id = blockIdx.x * blockDim.x + threadIdx.x;
	if (id < size) {
		const int x = id % width;
		const int y = id / width;

		float w[9] = {
			y == 0          || x == 0         ? 0 : img[id - width - 1],
			y == 0                            ? 0 : img[id - width],
			y == 0          || x == width - 1 ? 0 : img[id - width + 1],
			                   x == 0         ? 0 : img[id         - 1],
			                                        img[id],
			                   x == width - 1 ? 0 : img[id         + 1],
			y == height - 1 || x == 0         ? 0 : img[id + width - 1],
			y == height - 1                   ? 0 : img[id + width],
			y == height - 1 || x == width - 1 ? 0 : img[id + width + 1]
		};

		for (int i = 0; i < 5; i++) {
			float tmp = w[i];
			int idx = i;
			for (int j = i + 1; j < 9; j++) {
				if (w[j] < tmp) {
					idx = j;
					tmp = w[j];
				}
			}
			w[idx] = w[i];
			w[i] = tmp;
		}

		out[id] = w[4];
	}
}

int median3(lua_State *L)
{
	THCudaTensor *img = (THCudaTensor*)luaT_checkudata(L, 1, "torch.CudaTensor");
	THCudaTensor *out = (THCudaTensor*)luaT_checkudata(L, 2, "torch.CudaTensor");

	median3<<<(THCudaTensor_nElement(img) - 1) / TB + 1, TB>>>(
		THCudaTensor_data(img),
		THCudaTensor_data(out),
		THCudaTensor_nElement(img),
		THCudaTensor_size(img, 2),
		THCudaTensor_size(img, 3));
	checkCudaError(L);
	return 0;
}

__global__ void cross(float *x0, float *vol, float *out, int size, int dim2, int dim3, int L1, int L2, float tau1, float tau2)
{
	int id = blockIdx.x * blockDim.x + threadIdx.x;
	if (id < size) {
		int dir = id;
		int x = dir % dim3;
		dir /= dim3;
		int y = dir % dim2;
		dir /= dim2;

		int dx = 0;
		int dy = 0;
		if (dir == 0) {
			dx = -1;
		} else if (dir == 1) {
			dx = 1;
		} else if (dir == 2) {
			dy = -1;
		} else if (dir == 3) {
			dy = 1;
		} else {
			assert(0);
		}

		int xx, yy, ind1, ind2, ind3, dist;
		int dim23 = dim2 * dim3;
		ind1 = y * dim3 + x;
		for (xx = x + dx, yy = y + dy;;xx += dx, yy += dy) {
			if (xx < 0 || xx >= dim3 || yy < 0 || yy >= dim2) break;

			dist = max(abs(xx - x), abs(yy - y));
			if (dist == 1) continue;

			/* rule 1 */
			ind2 = yy * dim3 + xx;
			ind3 = (yy - dy) * dim3 + (xx - dx);

			if (abs(x0[0 * dim23 + ind1] - x0[0 * dim23 + ind2]) >= tau1) break;
			if (abs(x0[1 * dim23 + ind1] - x0[1 * dim23 + ind2]) >= tau1) break;
			if (abs(x0[2 * dim23 + ind1] - x0[2 * dim23 + ind2]) >= tau1) break;

			if (abs(x0[0 * dim23 + ind2] - x0[0 * dim23 + ind3]) >= tau1) break;
			if (abs(x0[1 * dim23 + ind2] - x0[1 * dim23 + ind3]) >= tau1) break;
			if (abs(x0[2 * dim23 + ind2] - x0[2 * dim23 + ind3]) >= tau1) break;

			/* rule 2 */
			if (dist >= L1) break;

			/* rule 3 */
			if (dist >= L2) {
				if (abs(x0[0 * dim23 + ind1] - x0[0 * dim23 + ind2]) >= tau2) break;
				if (abs(x0[1 * dim23 + ind1] - x0[1 * dim23 + ind2]) >= tau2) break;
				if (abs(x0[2 * dim23 + ind1] - x0[2 * dim23 + ind2]) >= tau2) break;
			}
		}
		out[id] = dir <= 1 ? xx : yy;
	}
}

int cross(lua_State *L)
{
	THCudaTensor *x0 = (THCudaTensor*)luaT_checkudata(L, 1, "torch.CudaTensor");
	THCudaTensor *vol = (THCudaTensor*)luaT_checkudata(L, 2, "torch.CudaTensor");
	THCudaTensor *out = (THCudaTensor*)luaT_checkudata(L, 3, "torch.CudaTensor");
	int L1 = luaL_checkinteger(L, 4);
	int L2 = luaL_checkinteger(L, 5);
	float tau1 = luaL_checknumber(L, 6);
	float tau2 = luaL_checknumber(L, 7);

	cross<<<(THCudaTensor_nElement(out) - 1) / TB + 1, TB>>>(
		THCudaTensor_data(x0),
		THCudaTensor_data(vol),
		THCudaTensor_data(out),
		THCudaTensor_nElement(out),
		THCudaTensor_size(out, 2),
		THCudaTensor_size(out, 3),
		L1, L2, tau1, tau2);

	checkCudaError(L);
	return 0;
}


__global__ void cbca(float *x0c, float *x1c, float *vol, float *out, int size)
{
	int id = blockIdx.x * blockDim.x + threadIdx.x;
	if (id < size) {
		
	}
}


int cbca(lua_State *L)
{
	THCudaTensor *x0c = (THCudaTensor*)luaT_checkudata(L, 1, "torch.CudaTensor");
	THCudaTensor *x1c = (THCudaTensor*)luaT_checkudata(L, 2, "torch.CudaTensor");
	THCudaTensor *vol = (THCudaTensor*)luaT_checkudata(L, 3, "torch.CudaTensor");
	THCudaTensor *out = (THCudaTensor*)luaT_checkudata(L, 4, "torch.CudaTensor");

	checkCudaError(L)
	return 0;
}

static const struct luaL_Reg funcs[] = {
	{"ad", ad},
	{"median3", median3},
	{"cross", cross},
	{"census", census},
	{"spatial_argmin", spatial_argmin},
	{NULL, NULL}
};

extern "C" int luaopen_libadcensus(lua_State *L) {
	luaL_openlib(L, "adcensus", funcs, 0);
	return 1;
}
