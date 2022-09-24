// #include <pybind11/pybind11.h>
// #include "include/helpers_cuda.h"

// // Perform fixed-size stepping in unit-cube scenes (like original NeRF) and exponential
// // stepping in larger scenes.
// inline CUDA_HOSTDEV float calc_dt(float t, float cone_angle, float dt_min, float dt_max)
// {
//     return __clamp(t * cone_angle, dt_min, dt_max);
// }

// inline CUDA_HOSTDEV int cascaded_grid_idx_at(
//     const float x, const float y, const float z,
//     const int resx, const int resy, const int resz)
// {
//     // TODO(ruilongli): if the x, y, z is outside the aabb, it will be clipped into aabb!!! We should just return false
//     int ix = (int)(x * resx);
//     int iy = (int)(y * resy);
//     int iz = (int)(z * resz);
//     ix = __clamp(ix, 0, resx - 1);
//     iy = __clamp(iy, 0, resy - 1);
//     iz = __clamp(iz, 0, resz - 1);
//     int idx = ix * resy * resz + iy * resz + iz;
//     return idx;
// }

// inline CUDA_HOSTDEV bool normalize_with_contraction(
//     float x, float y, float z,
//     const float *aabb, 
//     const int contraction_type, 
//     const bool normalize, // If true, it will output normalized coordinates in [0, 1]
//     float *outx, float *outy, float *outz
// ){
//     // normalize and contract to a unit space.
//     switch (contraction_type)
//     {
//     case 0:
//         // no contraction
//         if (normalize) {
//             *outx = (x - aabb[0]) / (aabb[3] - aabb[0]);
//             *outy = (y - aabb[1]) / (aabb[4] - aabb[1]);
//             *outz = (z - aabb[2]) / (aabb[5] - aabb[2]);
//         }
//         else {
//             *outx = x;
//             *outy = y;
//             *outz = z;
//         }
//         break;
//     case 1:
//         // mipnerf360 scene contraction
//         // The aabb defines a sphere in which the samples are not modified. 
//         // The samples outside the sphere are contracted into a 2x radius sphere.
//         x = (x - aabb[0]) / (aabb[3] - aabb[0]) * 2.0f - 1.0f;
//         y = (y - aabb[1]) / (aabb[4] - aabb[1]) * 2.0f - 1.0f;
//         z = (z - aabb[2]) / (aabb[5] - aabb[2]) * 2.0f - 1.0f;
//         float norm = sqrt(x * x + y * y + z * z);
//         if (norm > 1.0f)
//         {
//             x = (2.0f - 1.0f / norm) * (x / norm);
//             y = (2.0f - 1.0f / norm) * (y / norm);
//             z = (2.0f - 1.0f / norm) * (z / norm);
//         }
//         x = (x * 0.5f + 1.0f) * 0.5f; // the first 0.5f is bc of the 2x radius
//         y = (y * 0.5f + 1.0f) * 0.5f;
//         z = (z * 0.5f + 1.0f) * 0.5f;
//         if (normalize) {
//             *outx = x;
//             *outy = y;
//             *outz = z;
//         }
//         else {
//             *outx = 2.0f * (x - 0.25f) * (aabb[3] - aabb[0]) + aabb[0];
//             *outy = 2.0f * (y - 0.25f) * (aabb[4] - aabb[1]) + aabb[1];
//             *outz = 2.0f * (z - 0.25f) * (aabb[5] - aabb[2]) + aabb[2];
//         }
//         break;
//     }
// }

// inline CUDA_HOSTDEV bool grid_occupied_at(
//     float x, float y, float z,
//     const int resx, const int resy, const int resz,
//     const float *aabb, const bool *occ_binary, const int contraction_type)
// {
//     // normalize and maybe contract the coordinates.
//     float _x, _y, _z;
//     normalize_with_contraction(
//         x, y, z, aabb, contraction_type, true, &_x, &_y, &_z);
//     int idx = cascaded_grid_idx_at(_x, _y, _z, resx, resy, resz);
//     return occ_binary[idx];
// }

// inline CUDA_HOSTDEV float distance_to_next_voxel(
//     float x, float y, float z,
//     float dir_x, float dir_y, float dir_z,
//     float idir_x, float idir_y, float idir_z,
//     const int resx, const int resy, const int resz,
//     const float *aabb)
// { // dda like step
//     // TODO: this is ugly -- optimize this.
//     float _x = ((x - aabb[0]) / (aabb[3] - aabb[0])) * resx;
//     float _y = ((y - aabb[1]) / (aabb[4] - aabb[1])) * resy;
//     float _z = ((z - aabb[2]) / (aabb[5] - aabb[2])) * resz;
//     float tx = ((floorf(_x + 0.5f + 0.5f * __sign(dir_x)) - _x) * idir_x) / resx * (aabb[3] - aabb[0]);
//     float ty = ((floorf(_y + 0.5f + 0.5f * __sign(dir_y)) - _y) * idir_y) / resy * (aabb[4] - aabb[1]);
//     float tz = ((floorf(_z + 0.5f + 0.5f * __sign(dir_z)) - _z) * idir_z) / resz * (aabb[5] - aabb[2]);
//     float t = min(min(tx, ty), tz);
//     return fmaxf(t, 0.0f);
// }

// inline CUDA_HOSTDEV float advance_to_next_voxel(
//     float t,
//     float x, float y, float z,
//     float dir_x, float dir_y, float dir_z,
//     float idir_x, float idir_y, float idir_z,
//     const int resx, const int resy, const int resz, const float *aabb,
//     float dt_min)
// {
//     // Regular stepping (may be slower but matches non-empty space)
//     float t_target = t + distance_to_next_voxel(
//                              x, y, z,
//                              dir_x, dir_y, dir_z,
//                              idir_x, idir_y, idir_z,
//                              resx, resy, resz, aabb);
//     do
//     {
//         t += dt_min;
//     } while (t < t_target);
//     return t;
// }

// __global__ void marching_steps_kernel(
//     // rays info
//     const uint32_t n_rays,
//     const float *rays_o, // shape (n_rays, 3)
//     const float *rays_d, // shape (n_rays, 3)
//     const float *t_min,  // shape (n_rays,)
//     const float *t_max,  // shape (n_rays,)
//     // density grid
//     const float *aabb, // [min_x, min_y, min_z, max_x, max_y, max_z]
//     const int resx,
//     const int resy,
//     const int resz,
//     const bool *occ_binary, // shape (reso_x, reso_y, reso_z)
//     // sampling
//     const float step_size,
//     const int contraction_type,
//     const float cone_angle,
//     // outputs
//     int *num_steps)
// {
//     CUDA_GET_THREAD_ID(i, n_rays);

//     // locate
//     rays_o += i * 3;
//     rays_d += i * 3;
//     t_min += i;
//     t_max += i;
//     num_steps += i;

//     const float ox = rays_o[0], oy = rays_o[1], oz = rays_o[2];
//     const float dx = rays_d[0], dy = rays_d[1], dz = rays_d[2];
//     const float rdx = 1 / dx, rdy = 1 / dy, rdz = 1 / dz;
//     const float near = t_min[0], far = t_max[0];

//     float dt_min = step_size;
//     float dt_max = 1e10f; // TODO: if not contraction, calculate from occ res and aabb

//     int j = 0;
//     float t0 = near;
//     float dt = calc_dt(t0, cone_angle, dt_min, dt_max);
//     float t1 = t0 + dt;
//     float t_mid = (t0 + t1) * 0.5f;

//     while (t_mid < far)
//     {
//         // current center
//         const float x = ox + t_mid * dx;
//         const float y = oy + t_mid * dy;
//         const float z = oz + t_mid * dz;

//         if (grid_occupied_at(x, y, z, resx, resy, resz, aabb, occ_binary, contraction_type))
//         {
//             ++j;
//             // march to next sample
//             t0 = t1;
//             t1 = t0 + calc_dt(t0, cone_angle, dt_min, dt_max);
//             t_mid = (t0 + t1) * 0.5f;
//         }
//         else
//         {
//             // march to next sample
//             switch (contraction_type)
//             {
//             case 0:
//                 // no contraction
//                 t_mid = advance_to_next_voxel(
//                     t_mid, x, y, z, dx, dy, dz, rdx, rdy, rdz, resx, resy, resz, aabb, dt_min);
//                 dt = calc_dt(t_mid, cone_angle, dt_min, dt_max);
//                 t0 = t_mid - dt * 0.5f;
//                 t1 = t_mid + dt * 0.5f;
//                 break;
            
//             default:
//                 // any type of scene contraction does not work with DDA.
//                 t0 = t1;
//                 t1 = t0 + calc_dt(t0, cone_angle, dt_min, dt_max);
//                 t_mid = (t0 + t1) * 0.5f;
//                 break;
//             }
//         }
//     }
//     if (j == 0)
//         return;

//     num_steps[0] = j;
//     return;
// }

// __global__ void marching_forward_kernel(
//     // rays info
//     const uint32_t n_rays,
//     const float *rays_o, // shape (n_rays, 3)
//     const float *rays_d, // shape (n_rays, 3)
//     const float *t_min,  // shape (n_rays,)
//     const float *t_max,  // shape (n_rays,)
//     // density grid
//     const float *aabb, // [min_x, min_y, min_z, max_x, max_y, max_y]
//     const int resx,
//     const int resy,
//     const int resz,
//     const bool *occ_binary, // shape (reso_x, reso_y, reso_z)
//     // sampling
//     const float step_size,
//     const int contraction_type,
//     const float cone_angle,
//     const int *packed_info,
//     // frustrum outputs
//     float *frustum_starts,
//     float *frustum_ends)
// {
//     CUDA_GET_THREAD_ID(i, n_rays);

//     // locate
//     rays_o += i * 3;
//     rays_d += i * 3;
//     t_min += i;
//     t_max += i;
//     int base = packed_info[i * 2 + 0];
//     int steps = packed_info[i * 2 + 1];

//     const float ox = rays_o[0], oy = rays_o[1], oz = rays_o[2];
//     const float dx = rays_d[0], dy = rays_d[1], dz = rays_d[2];
//     const float rdx = 1 / dx, rdy = 1 / dy, rdz = 1 / dz;
//     const float near = t_min[0], far = t_max[0];

//     // locate
//     frustum_starts += base;
//     frustum_ends += base;

//     float dt_min = step_size;
//     float dt_max = 1e10f; // TODO: if not contraction, calculate from occ res and aabb

//     int j = 0;
//     float t0 = near;
//     float dt = calc_dt(t0, cone_angle, dt_min, dt_max);
//     float t1 = t0 + dt;
//     float t_mid = (t0 + t1) * 0.5f;

//     while (t_mid < far)
//     {
//         // current center
//         const float x = ox + t_mid * dx;
//         const float y = oy + t_mid * dy;
//         const float z = oz + t_mid * dz;

//         if (grid_occupied_at(x, y, z, resx, resy, resz, aabb, occ_binary, contraction_type))
//         {
//             frustum_starts[j] = t0;
//             frustum_ends[j] = t1;
//             ++j;
//             // march to next sample
//             t0 = t1;
//             t1 = t0 + calc_dt(t0, cone_angle, dt_min, dt_max);
//             t_mid = (t0 + t1) * 0.5f;
//         }
//         else
//         {
//             // march to next sample
//             switch (contraction_type)
//             {
//             case 0:
//                 // no contraction
//                 t_mid = advance_to_next_voxel(
//                     t_mid, x, y, z, dx, dy, dz, rdx, rdy, rdz, resx, resy, resz, aabb, dt_min);
//                 dt = calc_dt(t_mid, cone_angle, dt_min, dt_max);
//                 t0 = t_mid - dt * 0.5f;
//                 t1 = t_mid + dt * 0.5f;
//                 break;
            
//             default:
//                 // any type of scene contraction does not work with DDA.
//                 t0 = t1;
//                 t1 = t0 + calc_dt(t0, cone_angle, dt_min, dt_max);
//                 t_mid = (t0 + t1) * 0.5f;
//                 break;
//             }
//         }
//     }

//     if (j != steps)
//     {
//         printf("WTF %d v.s. %d\n", j, steps);
//     }
//     return;
// }

// __global__ void ray_indices_kernel(
//     // input
//     const int n_rays,
//     const int *packed_info,
//     // output
//     int *ray_indices)
// {
//     CUDA_GET_THREAD_ID(i, n_rays);

//     // locate
//     const int base = packed_info[i * 2 + 0];  // point idx start.
//     const int steps = packed_info[i * 2 + 1]; // point idx shift.
//     if (steps == 0)
//         return;

//     ray_indices += base;

//     for (int j = 0; j < steps; ++j)
//     {
//         ray_indices[j] = i;
//     }
// }

// __global__ void occ_query_kernel(
//     // rays info
//     const uint32_t n_samples,
//     const float *samples, // shape (n_samples, 3)
//     // density grid
//     const float *aabb, // [min_x, min_y, min_z, max_x, max_y, max_y]
//     const int resx,
//     const int resy,
//     const int resz,
//     const bool *occ_binary, // shape (reso_x, reso_y, reso_z)
//     // sampling
//     const int contraction_type,
//     // outputs
//     bool *occs)
// {
//     CUDA_GET_THREAD_ID(i, n_samples);

//     // locate
//     samples += i * 3;
//     occs += i;

//     occs[0] = grid_occupied_at(
//         samples[0], samples[1], samples[2],
//         resx, resy, resz, aabb, occ_binary, contraction_type);
//     return;
// }

// __global__ void contraction_kernel(
//     // rays info
//     const uint32_t n_samples,
//     const float *samples, // shape (n_samples, 3)
//     // contraction
//     const float *aabb, // [min_x, min_y, min_z, max_x, max_y, max_y]
//     const int contraction_type,
//     // outputs
//     float *out_samples)
// {
//     CUDA_GET_THREAD_ID(i, n_samples);

//     // locate
//     samples += i * 3;
//     out_samples += i * 3;

//     normalize_with_contraction(
//         samples[0], samples[1], samples[2],
//         aabb, contraction_type, false, 
//         &out_samples[0], &out_samples[1], &out_samples[2]
//     );
//     return;
// }

// std::vector<torch::Tensor> volumetric_marching(
//     // rays
//     const torch::Tensor rays_o,
//     const torch::Tensor rays_d,
//     const torch::Tensor t_min,
//     const torch::Tensor t_max,
//     // density grid
//     const torch::Tensor aabb,
//     const pybind11::list resolution,
//     const torch::Tensor occ_binary,
//     // sampling
//     const float step_size,
//     const int contraction_type,
//     const float cone_angle)
// {
//     DEVICE_GUARD(rays_o);

//     CHECK_INPUT(rays_o);
//     CHECK_INPUT(rays_d);
//     CHECK_INPUT(t_min);
//     CHECK_INPUT(t_max);
//     CHECK_INPUT(aabb);
//     CHECK_INPUT(occ_binary);

//     const int n_rays = rays_o.size(0);

//     const int threads = 256;
//     const int blocks = CUDA_N_BLOCKS_NEEDED(n_rays, threads);

//     // helper counter
//     torch::Tensor num_steps = torch::zeros(
//         {n_rays}, rays_o.options().dtype(torch::kInt32));

//     // count number of samples per ray
//     marching_steps_kernel<<<blocks, threads, 0, at::cuda::getCurrentCUDAStream()>>>(
//         // rays
//         n_rays,
//         rays_o.data_ptr<float>(),
//         rays_d.data_ptr<float>(),
//         t_min.data_ptr<float>(),
//         t_max.data_ptr<float>(),
//         // density grid
//         aabb.data_ptr<float>(),
//         resolution[0].cast<int>(),
//         resolution[1].cast<int>(),
//         resolution[2].cast<int>(),
//         occ_binary.data_ptr<bool>(),
//         // sampling
//         step_size,
//         contraction_type,
//         cone_angle,
//         // outputs
//         num_steps.data_ptr<int>());

//     torch::Tensor cum_steps = num_steps.cumsum(0, torch::kInt32);
//     torch::Tensor packed_info = torch::stack({cum_steps - num_steps, num_steps}, 1);
//     // std::cout << "num_steps" << num_steps.dtype() << std::endl;
//     // std::cout << "cum_steps" << cum_steps.dtype() << std::endl;
//     // std::cout << "packed_info" << packed_info.dtype() << std::endl;

//     // output frustum samples
//     int total_steps = cum_steps[cum_steps.size(0) - 1].item<int>();
//     torch::Tensor frustum_starts = torch::zeros({total_steps, 1}, rays_o.options());
//     torch::Tensor frustum_ends = torch::zeros({total_steps, 1}, rays_o.options());

//     marching_forward_kernel<<<blocks, threads, 0, at::cuda::getCurrentCUDAStream()>>>(
//         // rays
//         n_rays,
//         rays_o.data_ptr<float>(),
//         rays_d.data_ptr<float>(),
//         t_min.data_ptr<float>(),
//         t_max.data_ptr<float>(),
//         // density grid
//         aabb.data_ptr<float>(),
//         resolution[0].cast<int>(),
//         resolution[1].cast<int>(),
//         resolution[2].cast<int>(),
//         occ_binary.data_ptr<bool>(),
//         // sampling
//         step_size,
//         contraction_type,
//         cone_angle,
//         packed_info.data_ptr<int>(),
//         // outputs
//         frustum_starts.data_ptr<float>(),
//         frustum_ends.data_ptr<float>());

//     return {packed_info, frustum_starts, frustum_ends};
// }

// torch::Tensor unpack_to_ray_indices(const torch::Tensor packed_info)
// {
//     DEVICE_GUARD(packed_info);
//     CHECK_INPUT(packed_info);

//     const int n_rays = packed_info.size(0);
//     const int threads = 256;
//     const int blocks = CUDA_N_BLOCKS_NEEDED(n_rays, threads);

//     int n_samples = packed_info[n_rays - 1].sum(0).item<int>();
//     torch::Tensor ray_indices = torch::zeros(
//         {n_samples}, packed_info.options().dtype(torch::kInt32));

//     ray_indices_kernel<<<blocks, threads, 0, at::cuda::getCurrentCUDAStream()>>>(
//         n_rays,
//         packed_info.data_ptr<int>(),
//         ray_indices.data_ptr<int>());
//     return ray_indices;
// }

// torch::Tensor query_occ(
//     const torch::Tensor samples,
//     // density grid
//     const torch::Tensor aabb,
//     const pybind11::list resolution,
//     const torch::Tensor occ_binary,
//     // sampling
//     const int contraction_type)
// {
//     DEVICE_GUARD(samples);
//     CHECK_INPUT(samples);

//     const int n_samples = samples.size(0);
//     const int threads = 256;
//     const int blocks = CUDA_N_BLOCKS_NEEDED(n_samples, threads);

//     torch::Tensor occs = torch::zeros(
//         {n_samples}, samples.options().dtype(torch::kBool));

//     occ_query_kernel<<<blocks, threads, 0, at::cuda::getCurrentCUDAStream()>>>(
//         n_samples,
//         samples.data_ptr<float>(),
//         // density grid
//         aabb.data_ptr<float>(),
//         resolution[0].cast<int>(),
//         resolution[1].cast<int>(),
//         resolution[2].cast<int>(),
//         occ_binary.data_ptr<bool>(),
//         // sampling
//         contraction_type,
//         // outputs
//         occs.data_ptr<bool>());
//     return occs;
// }

// torch::Tensor contraction(
//     const torch::Tensor samples,
//     // contraction
//     const torch::Tensor aabb,
//     const int contraction_type)
// {
//     DEVICE_GUARD(samples);
//     CHECK_INPUT(samples);

//     const int n_samples = samples.size(0);
//     const int threads = 256;
//     const int blocks = CUDA_N_BLOCKS_NEEDED(n_samples, threads);

//     torch::Tensor out_samples = torch::zeros({n_samples, 3}, samples.options());

//     contraction_kernel<<<blocks, threads, 0, at::cuda::getCurrentCUDAStream()>>>(
//         n_samples,
//         samples.data_ptr<float>(),
//         // density grid
//         aabb.data_ptr<float>(),
//         contraction_type,
//         // outputs
//         out_samples.data_ptr<float>()
//     );
//     return out_samples;
// }
