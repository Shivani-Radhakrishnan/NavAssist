import sys

import cv2
import numpy as np

# Which TUM sequence to map: python topdown_map.py [rgbd_dataset_freiburg1_xyz]
folder = sys.argv[1] if len(sys.argv) > 1 else "rgbd_dataset_freiburg1_room"

# Camera lens numbers for the TUM freiburg1 camera
FX, FY, CX, CY = 517.3, 516.5, 318.6, 255.3
DEPTH_SCALE = 5000.0


def read_list(filename):
    rows = []
    with open(f"{folder}/{filename}") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            parts = line.split()
            rows.append((float(parts[0]), parts[1:]))
    return rows


def closest_index(times, t):
    return int(np.argmin(np.abs(times - t)))


def quat_to_matrix(qx, qy, qz, qw):
    """Turn a rotation quaternion into a 3x3 rotation matrix."""
    return np.array([
        [1 - 2*(qy*qy + qz*qz), 2*(qx*qy - qz*qw),     2*(qx*qz + qy*qw)],
        [2*(qx*qy + qz*qw),     1 - 2*(qx*qx + qz*qz), 2*(qy*qz - qx*qw)],
        [2*(qx*qz - qy*qw),     2*(qy*qz + qx*qw),     1 - 2*(qx*qx + qy*qy)],
    ])


rgb_list = read_list("rgb.txt")
depth_list = read_list("depth.txt")
gt_list = read_list("groundtruth.txt")
depth_times = np.array([t for t, _ in depth_list])
gt_times = np.array([t for t, _ in gt_list])

# Map settings: 10 m x 10 m area, each cell is 5 cm
CELL = 0.05
SIZE = 200
first_pose = [float(v) for v in gt_list[0][1][:3]]
origin_x = first_pose[0] - SIZE * CELL / 2
origin_y = first_pose[1] - SIZE * CELL / 2
hits = np.zeros((SIZE, SIZE), dtype=np.int32)  # how many points landed in each cell

# Precompute pixel coordinates (every 4th pixel to keep it fast)
step = 4
us, vs = np.meshgrid(np.arange(0, 640, step), np.arange(0, 480, step))
us = us.flatten()
vs = vs.flatten()

trail = []

print("Building map... click a window and press q to quit.")

for n, (t, rgb_info) in enumerate(rgb_list):
    if n % 2 != 0:        # use every 2nd frame for speed
        continue

    rgb = cv2.imread(f"{folder}/{rgb_info[0]}")
    di = closest_index(depth_times, t)
    depth = cv2.imread(f"{folder}/{depth_list[di][1][0]}", cv2.IMREAD_UNCHANGED)
    gi = closest_index(gt_times, t)
    tx, ty, tz, qx, qy, qz, qw = [float(v) for v in gt_list[gi][1][:7]]

    # 1) Depth pixels -> 3D points in the camera's own frame
    d = depth[vs, us].astype(np.float32) / DEPTH_SCALE
    ok = d > 0.1                      # throw away missing depth
    d, u, v = d[ok], us[ok], vs[ok]
    px = (u - CX) * d / FX
    py = (v - CY) * d / FY
    pts_cam = np.stack([px, py, d], axis=1)

    # 2) Camera frame -> world frame using the camera's pose
    R = quat_to_matrix(qx, qy, qz, qw)
    pts_world = pts_cam @ R.T + np.array([tx, ty, tz])

    # 3) Drop onto the top-down grid (use world x and y, ignore height for now)
    gx = ((pts_world[:, 0] - origin_x) / CELL).astype(int)
    gy = ((pts_world[:, 1] - origin_y) / CELL).astype(int)
    inside = (gx >= 0) & (gx < SIZE) & (gy >= 0) & (gy < SIZE)
    np.add.at(hits, (gy[inside], gx[inside]), 1)

    # Remember where the user is, for drawing the trail
    trail.append((int((tx - origin_x) / CELL), int((ty - origin_y) / CELL)))

    # 4) Draw the map: white = unknown, black = obstacle seen, red = user trail
    map_img = np.full((SIZE, SIZE, 3), 255, dtype=np.uint8)
    map_img[hits >= 3] = (0, 0, 0)
    for (cx_, cy_) in trail:
        if 0 <= cx_ < SIZE and 0 <= cy_ < SIZE:
            map_img[cy_, cx_] = (0, 0, 255)
    map_big = cv2.resize(map_img, (600, 600), interpolation=cv2.INTER_NEAREST)

    cv2.imshow("RGB", rgb)
    cv2.imshow("Map (top-down)", map_big)
    if cv2.waitKey(1) & 0xFF == ord("q"):
        break

cv2.destroyAllWindows()
print("Done. Cells marked as obstacle:", int((hits >= 3).sum()))