import cv2
import numpy as np

folder = "rgbd_dataset_freiburg1_xyz"

# Read the list of RGB images (skip comment lines starting with #)
with open(f"{folder}/rgb.txt") as f:
    rgb_lines = [l.split() for l in f if not l.startswith("#")]

with open(f"{folder}/depth.txt") as f:
    depth_lines = [l.split() for l in f if not l.startswith("#")]

print("Number of RGB frames:", len(rgb_lines))
print("Number of depth frames:", len(depth_lines))

# Load the first RGB image and first depth image
rgb = cv2.imread(f"{folder}/{rgb_lines[0][1]}")
depth = cv2.imread(f"{folder}/{depth_lines[0][1]}", cv2.IMREAD_UNCHANGED)

print("RGB shape:", rgb.shape)
print("Depth shape:", depth.shape, "dtype:", depth.dtype)

# TUM depth is stored so that 5000 = 1 meter
depth_m = depth.astype(np.float32) / 5000.0
print("Closest point (m):", depth_m[depth_m > 0].min())
print("Farthest point (m):", depth_m.max())

# Make the depth image viewable
depth_view = cv2.convertScaleAbs(depth_m, alpha=255.0 / 4.0)
depth_view = cv2.applyColorMap(depth_view, cv2.COLORMAP_JET)

cv2.imshow("RGB", rgb)
cv2.imshow("Depth (colors = distance)", depth_view)
cv2.waitKey(0)
cv2.destroyAllWindows()