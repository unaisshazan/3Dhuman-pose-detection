#include <math.h>
#include <stdio.h>
#include <cuda_runtime.h>
#include <device_launch_parameters.h>

#include "safecall.hpp"

#define X 0
#define Y 1
#define Z 2

#define CROSS(dest,v1,v2) \
          dest[0]=v1[1]*v2[2]-v1[2]*v2[1]; \
          dest[1]=v1[2]*v2[0]-v1[0]*v2[2]; \
          dest[2]=v1[0]*v2[1]-v1[1]*v2[0]; 

#define DOT(v1,v2) (v1[0]*v2[0]+v1[1]*v2[1]+v1[2]*v2[2])

#define SUB(dest,v1,v2) \
          dest[0]=v1[0]-v2[0]; \
          dest[1]=v1[1]-v2[1]; \
          dest[2]=v1[2]-v2[2]; 

#define MAX(x, y) x > y? x:y
#define MIN(x, y) x < y? x:y

#define FINDMINMAX(x0,x1,x2,min,max) \
  min = max = x0;   \
  if(x1<min) min=x1;\
  if(x1>max) max=x1;\
  if(x2<min) min=x2;\
  if(x2>max) max=x2;

__device__ __forceinline__
int planeBoxOverlap(float normal[3], float vert[3], float maxbox[3])	// -NJMP-
{
    int q;
    float vmin[3], vmax[3], v;
    for (q = X; q <= Z; q++)
    {
        v = vert[q];					// -NJMP-
        if (normal[q] > 0.0f)
        {
            vmin[q] = -maxbox[q] - v;	// -NJMP-
            vmax[q] = maxbox[q] - v;	// -NJMP-
        }
        else
        {
            vmin[q] = maxbox[q] - v;	// -NJMP-
            vmax[q] = -maxbox[q] - v;	// -NJMP-
        }
    }
    if (DOT(normal, vmin) > 0.0f) return 0;	// -NJMP-
    if (DOT(normal, vmax) >= 0.0f) return 1;	// -NJMP-

    return 0;
}


/*======================== X-tests ========================*/
#define AXISTEST_X01(a, b, fa, fb)			   \
	p0 = a*v0[Y] - b*v0[Z];			       	   \
	p2 = a*v2[Y] - b*v2[Z];			       	   \
        if(p0<p2) {min=p0; max=p2;} else {min=p2; max=p0;} \
	rad = fa * boxhalfsize[Y] + fb * boxhalfsize[Z];   \
	if(min>rad || max<-rad) return 0;

#define AXISTEST_X2(a, b, fa, fb)			   \
	p0 = a*v0[Y] - b*v0[Z];			           \
	p1 = a*v1[Y] - b*v1[Z];			       	   \
        if(p0<p1) {min=p0; max=p1;} else {min=p1; max=p0;} \
	rad = fa * boxhalfsize[Y] + fb * boxhalfsize[Z];   \
	if(min>rad || max<-rad) return 0;

/*======================== Y-tests ========================*/
#define AXISTEST_Y02(a, b, fa, fb)			   \
	p0 = -a*v0[X] + b*v0[Z];		      	   \
	p2 = -a*v2[X] + b*v2[Z];	       	       	   \
        if(p0<p2) {min=p0; max=p2;} else {min=p2; max=p0;} \
	rad = fa * boxhalfsize[X] + fb * boxhalfsize[Z];   \
	if(min>rad || max<-rad) return 0;

#define AXISTEST_Y1(a, b, fa, fb)			   \
	p0 = -a*v0[X] + b*v0[Z];		      	   \
	p1 = -a*v1[X] + b*v1[Z];	     	       	   \
        if(p0<p1) {min=p0; max=p1;} else {min=p1; max=p0;} \
	rad = fa * boxhalfsize[X] + fb * boxhalfsize[Z];   \
	if(min>rad || max<-rad) return 0;

/*======================== Z-tests ========================*/

#define AXISTEST_Z12(a, b, fa, fb)			   \
	p1 = a*v1[X] - b*v1[Y];			           \
	p2 = a*v2[X] - b*v2[Y];			       	   \
        if(p2<p1) {min=p2; max=p1;} else {min=p1; max=p2;} \
	rad = fa * boxhalfsize[X] + fb * boxhalfsize[Y];   \
	if(min>rad || max<-rad) return 0;

#define AXISTEST_Z0(a, b, fa, fb)			   \
	p0 = a*v0[X] - b*v0[Y];				   \
	p1 = a*v1[X] - b*v1[Y];			           \
        if(p0<p1) {min=p0; max=p1;} else {min=p1; max=p0;} \
	rad = fa * boxhalfsize[X] + fb * boxhalfsize[Y];   \
	if(min>rad || max<-rad) return 0;

__device__ __forceinline__
int triBoxOverlap(float boxcenter[3], float boxhalfsize[3], float triverts[3][3])
{

    /*    use separating axis theorem to test overlap between triangle and box */
    /*    need to test for overlap in these directions: */
    /*    1) the {x,y,z}-directions (actually, since we use the AABB of the triangle */
    /*       we do not even need to test these) */
    /*    2) normal of the triangle */
    /*    3) crossproduct(edge from tri, {x,y,z}-directin) */
    /*       this gives 3x3=9 more tests */
    float v0[3], v1[3], v2[3];
    //   float axis[3];
    float min, max, p0, p1, p2, rad, fex, fey, fez;		// -NJMP- "d" local variable removed
    float normal[3], e0[3], e1[3], e2[3];

    /* This is the fastest branch on Sun */
    /* move everything so that the boxcenter is in (0,0,0) */
    SUB(v0, triverts[0], boxcenter);
    SUB(v1, triverts[1], boxcenter);
    SUB(v2, triverts[2], boxcenter);

    /* compute triangle edges */
    SUB(e0, v1, v0);      /* tri edge 0 */
    SUB(e1, v2, v1);      /* tri edge 1 */
    SUB(e2, v0, v2);      /* tri edge 2 */

    /* Bullet 3:  */
    /*  test the 9 tests first (this was faster) */
    fex = fabsf(e0[X]);
    fey = fabsf(e0[Y]);
    fez = fabsf(e0[Z]);
    AXISTEST_X01(e0[Z], e0[Y], fez, fey);
    AXISTEST_Y02(e0[Z], e0[X], fez, fex);
    AXISTEST_Z12(e0[Y], e0[X], fey, fex);

    fex = fabsf(e1[X]);
    fey = fabsf(e1[Y]);
    fez = fabsf(e1[Z]);
    AXISTEST_X01(e1[Z], e1[Y], fez, fey);
    AXISTEST_Y02(e1[Z], e1[X], fez, fex);
    AXISTEST_Z0(e1[Y], e1[X], fey, fex);

    fex = fabsf(e2[X]);
    fey = fabsf(e2[Y]);
    fez = fabsf(e2[Z]);
    AXISTEST_X2(e2[Z], e2[Y], fez, fey);
    AXISTEST_Y1(e2[Z], e2[X], fez, fex);
    AXISTEST_Z12(e2[Y], e2[X], fey, fex);

    /* Bullet 1: */
     /*  first test overlap in the {x,y,z}-directions */
     /*  find min, max of the triangle each direction, and test for overlap in */
     /*  that direction -- this is equivalent to testing a minimal AABB around */
     /*  the triangle against the AABB */

     /* test in X-direction */
    FINDMINMAX(v0[X], v1[X], v2[X], min, max);
    if (min > boxhalfsize[X] || max < -boxhalfsize[X]) return 0;

    /* test in Y-direction */
    FINDMINMAX(v0[Y], v1[Y], v2[Y], min, max);
    if (min > boxhalfsize[Y] || max < -boxhalfsize[Y]) return 0;

    /* test in Z-direction */
    FINDMINMAX(v0[Z], v1[Z], v2[Z], min, max);
    if (min > boxhalfsize[Z] || max < -boxhalfsize[Z]) return 0;

    /* Bullet 2: */
    /*  test if the box intersects the plane of the triangle */
    /*  compute plane equation of triangle: normal*x+d=0 */
    CROSS(normal, e0, e1);
    // -NJMP- (line removed here)
    if (!planeBoxOverlap(normal, v0, boxhalfsize)) return 0;	// -NJMP-

    return 1;   /* box and triangle overlaps */
}

__global__ void setIntersectVoxels_kernel(float3 *_vertices_ptr, int3* _faces_ptr, int* _volume, int3 _vol_res, float3 _vol_min_corner, float3 _vol_max_corner, int _vertices_num, int _face_num)
{
    float3 step;
    step.x = (_vol_max_corner.x - _vol_min_corner.x) / _vol_res.x;
    step.y = (_vol_max_corner.y - _vol_min_corner.y) / _vol_res.y;
    step.z = (_vol_max_corner.z - _vol_min_corner.z) / _vol_res.z;
    float boxhalfsize[3] = { step.x / 2.f, step.y / 2.f, step.z / 2.f };

    int idx = blockDim.x*blockIdx.x + threadIdx.x;
    if (idx < _face_num)
    {
        int3 face = _faces_ptr[idx];
        float3 v0 = _vertices_ptr[face.x];
        float3 v1 = _vertices_ptr[face.y];
        float3 v2 = _vertices_ptr[face.z];

        float triverts[3][3] = { {v0.x, v0.y, v0.z}, {v1.x, v1.y, v1.z}, {v2.x, v2.y, v2.z} };

        float x_min, x_max, y_min, y_max, z_min, z_max;
        FINDMINMAX(v0.x, v1.x, v2.x, x_min, x_max);
        FINDMINMAX(v0.y, v1.y, v2.y, y_min, y_max);
        FINDMINMAX(v0.z, v1.z, v2.z, z_min, z_max);

        int3 bb_min_corner, bb_max_corner;
        bb_min_corner.x = MAX(int(floor((x_min - _vol_min_corner.x) / step.x)), 0);
        bb_min_corner.y = MAX(int(floor((y_min - _vol_min_corner.y) / step.y)), 0);
        bb_min_corner.z = MAX(int(floor((z_min - _vol_min_corner.z) / step.z)), 0);

        bb_max_corner.x = MIN(int(ceil((x_max - _vol_min_corner.x) / step.x)), _vol_res.x);
        bb_max_corner.y = MIN(int(ceil((y_max - _vol_min_corner.y) / step.y)), _vol_res.y);
        bb_max_corner.z = MIN(int(ceil((z_max - _vol_min_corner.z) / step.z)), _vol_res.z);

        for (int xx = bb_min_corner.x; xx < bb_max_corner.x; xx++)
        {
            for (int yy = bb_min_corner.y; yy < bb_max_corner.y; yy++)
            {
                for (int zz = bb_min_corner.z; zz < bb_max_corner.z; zz++)
                {
                    float boxcenter_x = xx*step.x + boxhalfsize[0]+ _vol_min_corner.x;
                    float boxcenter_y = yy*step.y + boxhalfsize[1]+ _vol_min_corner.y;
                    float boxcenter_z = zz*step.z + boxhalfsize[2]+ _vol_min_corner.z;

                    float boxcenter[3] = { boxcenter_x, boxcenter_y, boxcenter_z };
                    if (triBoxOverlap(boxcenter, boxhalfsize, triverts))
                    {
                        int id = zz*_vol_res.y*_vol_res.x + yy*_vol_res.x + xx;
                        atomicMax(_volume + id, 1);
                    }
                }
            }
        }
    }
}

void setIntersectVoxels(float3 *_vertices_ptr, int3* _faces_ptr, int* _volume, int3 _vol_res, float3 _vol_min_corner, float3 _vol_max_corner, int _vertices_num, int _face_num)
{
    dim3 block(64);
    dim3 grid((_face_num + 63) / 64);
    setIntersectVoxels_kernel << <grid, block >> > (_vertices_ptr, _faces_ptr, _volume, _vol_res, _vol_min_corner, _vol_max_corner, _vertices_num, _face_num);
    cudaSafeCall(cudaGetLastError());
    cudaSafeCall(cudaDeviceSynchronize());
}