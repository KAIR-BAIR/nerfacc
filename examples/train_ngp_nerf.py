"""
Copyright (c) 2022 Ruilong Li, UC Berkeley.
"""

import argparse
import math
import os
import time

import imageio
import numpy as np
import torch
import torch.nn.functional as F
import tqdm
from radiance_fields.ngp import NGPradianceField
from utils import render_image, set_random_seed

from nerfacc import ContractionType, OccupancyGrid

import matplotlib.pyplot as plt

if __name__ == "__main__":

    device = "cuda:0"
    set_random_seed(42)

    parser = argparse.ArgumentParser()
    parser.add_argument("--exp_name",type=str,default="exp",help="The name of the folder for saving results")
    parser.add_argument("--scene",type=str,default="lego",help="which scene to use")
    parser.add_argument("--aabb",type=lambda s: [float(item) for item in s.split(",")],default="-1.5,-1.5,-1.5,1.5,1.5,1.5",help="delimited list input")
    parser.add_argument("--test_chunk_size",type=int,default=8192)
    parser.add_argument("--ev_data",action="store_true",help="whether to use EV dataset or not")
    parser.add_argument("--unbounded",action="store_true",help="whether to use unbounded rendering")
    parser.add_argument("--auto_aabb",action="store_true",help="whether to automatically compute the aabb")
    parser.add_argument("--cone_angle", type=float, default=0.0)
    parser.add_argument("--i_test",type=int, default=5000)
    args = parser.parse_args()

    render_n_samples = 1024

    #---------------------------------------------------------------------------------------------------------------------------------------
    if args.ev_data == True:
        from datasets.nerf_synthetic import SubjectLoader
        from datasets.generateTestPoses import SubjectTestPoseLoader
        data_root_fp = "/home/ubuntu/data/"
        target_sample_batch_size = 1 << 20
        grid_resolution = 256

    #---------------------------------------------------------------------------------------------------------------------------------------
    dataset = SubjectLoader(subject_id=args.scene,root_fp=data_root_fp,split="train",num_rays=target_sample_batch_size // render_n_samples)
    dataset.images = dataset.images.to(device)
    dataset.camtoworlds = dataset.camtoworlds.to(device)
    dataset.K = dataset.K.to(device)

    testPoses = SubjectTestPoseLoader(subject_id=args.scene,root_fp=data_root_fp,numberOfFrames=240)
    testPoses.camtoworlds = testPoses.camtoworlds.to(device)
    testPoses.K = testPoses.K.to(device)

    #---------------------------------------------------------------------------------------------------------------------------------------
    savepath = os.path.join(data_root_fp,args.scene+"_"+args.exp_name)
    if not os.path.exists(savepath):
        os.makedirs(savepath)
        print('Test results folder not found, creating new dir: ' + savepath)
    else:
        print('Test images will be saved in ' +savepath)

    #---------------------------------------------------------------------------------------------------------------------------------------
    contraction_type = ContractionType.AABB
    args.aabb = [dataset.aabb[0][0], dataset.aabb[0][1], -50, dataset.aabb[1][0], dataset.aabb[1][1], 100]
    scene_aabb = torch.tensor(args.aabb, dtype=torch.float32, device=device)
    render_aabb = torch.tensor(args.aabb, dtype=torch.float32, device=device)
    render_aabb[5] = 50
    
    near_plane = None
    far_plane = None
    render_step_size = ((scene_aabb[3:] - scene_aabb[:3]).max() * math.sqrt(3) / render_n_samples).item()
    alpha_thre = 0.0
    print("Using aabb", args.aabb, render_step_size)

    #---------------------------------------------------------------------------------------------------------------------------------------
    # setup the radiance field we want to train.
    max_steps = 50000
    grad_scaler = torch.cuda.amp.GradScaler(2**10)
    radiance_field = NGPradianceField(aabb=args.aabb,unbounded=args.unbounded,).to(device)
    optimizer = torch.optim.Adam(radiance_field.parameters(), lr=1e-2, eps=1e-15)
    
    scheduler = torch.optim.lr_scheduler.MultiStepLR(
        optimizer,
        milestones=[max_steps // 2, max_steps * 3 // 4, max_steps * 9 // 10],
        gamma=0.33,
    )

    occupancy_grid = OccupancyGrid(roi_aabb=args.aabb,resolution=grid_resolution,contraction_type=contraction_type).to(device)
    #---------------------------------------------------------------------------------------------------------------------------------------

    # training
    step = 0
    tic = time.time()
    for epoch in range(10000000):
        for i in range(len(dataset)):
            radiance_field.train()
        
            data = dataset[i]

            render_bkgd = data["color_bkgd"]
            rays = data["rays"]
            pixels = data["pixels"]

            def occ_eval_fn(x):
                if args.cone_angle > 0.0:
                    # randomly sample a camera for computing step size.
                    camera_ids = torch.randint(0, len(dataset), (x.shape[0],), device=device)
                    origins = dataset.camtoworlds[camera_ids, :3, -1]
                    t = (origins - x).norm(dim=-1, keepdim=True)

                    # compute actual step size used in marching, based on the distance to the camera.
                    step_size = torch.clamp(t * args.cone_angle, min=render_step_size)
                    
                    # filter out the points that are not in the near far plane.
                    if (near_plane is not None) and (far_plane is not None):
                        step_size = torch.where(
                            (t > near_plane) & (t < far_plane),
                            step_size,
                            torch.zeros_like(step_size),
                        )
                else:
                    step_size = render_step_size
                
                # compute occupancy
                density = radiance_field.query_density(x)
                
                return density * step_size

            # update occupancy grid
            occupancy_grid.every_n_step(step=step, occ_eval_fn=occ_eval_fn)

            # render
            rgb, acc, depth, n_rendering_samples = render_image(
                radiance_field,
                occupancy_grid,
                rays,
                scene_aabb,
                # rendering options
                near_plane=near_plane,
                far_plane=far_plane,
                render_step_size=render_step_size,
                render_bkgd=render_bkgd,
                cone_angle=args.cone_angle,
                alpha_thre=alpha_thre,
            )
            if n_rendering_samples == 0:
                continue

            # dynamic batch size for rays to keep sample batch size constant.
            num_rays = len(pixels)
            num_rays = int(num_rays * (target_sample_batch_size / float(n_rendering_samples)))

            dataset.update_num_rays(num_rays)
            alive_ray_mask = acc.squeeze(-1) > 0

            # compute loss
            loss = F.smooth_l1_loss(rgb[alive_ray_mask], pixels[alive_ray_mask])

            optimizer.zero_grad()
            # do not unscale it because we are using Adam.
            grad_scaler.scale(loss).backward()
            optimizer.step()
            scheduler.step()

            if step % 100 == 0:
                elapsed_time = time.time() - tic
                loss = F.mse_loss(rgb[alive_ray_mask], pixels[alive_ray_mask])
                print(
                    f"elapsed_time={elapsed_time:.2f}s | step={step} | "
                    f"loss={loss:.5f} | "
                    f"alive_ray_mask={alive_ray_mask.long().sum():d} | "
                    f"n_rendering_samples={n_rendering_samples:d} | num_rays={len(pixels):d} |"
                )

            if step >= 0 and step % args.i_test == 0 and step > 0:
                # evaluation
                radiance_field.eval()

                psnrs = []
                with torch.no_grad():
                    # for i in tqdm.tqdm(range(len(test_dataset))):
                    rgbs = []
                    depths = []
                    for i in tqdm.tqdm(range(len(testPoses))):
                        dataset.training = False

                        # data = dataset[i]
                        data = testPoses[i]
                        render_bkgd = data["color_bkgd"]
                        rays = data["rays"]
                        # pixels = data["pixels"]

                        # rendering
                        rgb, acc, depth, _ = render_image(
                            radiance_field,
                            occupancy_grid,
                            rays,
                            render_aabb,
                            # rendering options
                            near_plane=near_plane,
                            far_plane=far_plane,
                            render_step_size=render_step_size,
                            render_bkgd=render_bkgd,
                            cone_angle=args.cone_angle,
                            alpha_thre=alpha_thre,
                            # test options
                            test_chunk_size=args.test_chunk_size,
                        )
                        # mse = F.mse_loss(rgb, pixels)
                        # psnr = -10.0 * torch.log(mse) / np.log(10.0)
                        # psnrs.append(psnr.item())

                        saveImg = os.path.join(savepath,"rgb_test_"+str(i)+".png")
                        saveDepth = os.path.join(savepath,"depth_test_"+str(i)+".png")
                        
                        #save rgb image
                        rgbImage = (rgb.cpu().numpy() * 255).astype(np.uint8)
                        rgbs.append(rgbImage)
                        
                        #save depth image (4000 is max depth)
                        depthImage = depth.cpu().numpy()
                        depthImage = depthImage[...,-1]

                        # a colormap and a normalization instance
                        cmap = plt.cm.turbo
                        norm = plt.Normalize(vmin=1000, vmax=depthImage.max())

                        # map the normalized data to colors
                        depthImage = (cmap(norm(depthImage)) * 255).astype(np.uint8)
                        depths.append(depthImage)

                    rgbs = np.stack(rgbs, 0)
                    imageio.mimwrite(os.path.join(savepath,"rgb"+str(step)+".mp4"), rgbs, fps=30, quality=8)
                    
                    depths = np.stack(depths, 0)
                    imageio.mimwrite(os.path.join(savepath,"depth"+str(step)+".mp4"), depths, fps=30, quality=8)

                # psnr_avg = sum(psnrs) / len(psnrs)
                # print(f"evaluation: psnr_avg={psnr_avg}")
                dataset.training = True

            if step == max_steps:
                print("training stops")
                exit()

            step += 1
