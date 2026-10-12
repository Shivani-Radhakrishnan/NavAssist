import cv2
import numpy as np

folder = "rgbd_dataset_freiburg1_room"

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

step = 4
us, vs = np.meshgrid(np.arange(0, 640, step), np.arange(0, 480, step))
us = us.flatten()
vs = vs.flatten()


def world_points(t):
    """Return (3D points in world coords, camera position) for time t."""
    di = closest_index(depth_times, t)
    depth = cv2.imread(f"{folder}/{depth_list[di][1][0]}", cv2.IMREAD_UNCHANGED)
    gi = closest_index(gt_times, t)
    tx, ty, tz, qx, qy, qz, qw = [float(v) for v in gt_list[gi][1][:7]]

    d = depth[vs, us].astype(np.float32) / DEPTH_SCALE
    ok = (d > 0.1) & (d < 3.5)
    d, u, v = d[ok], us[ok], vs[ok]
    pts_cam = np.stack([(u - CX) * d / FX, (v - CY) * d / FY, d], axis=1)
    R = quat_to_matrix(qx, qy, qz, qw)
    return pts_cam @ R.T + np.array([tx, ty, tz]), (tx, ty, tz)

# ---------- Settings ----------
floor_z = 0.04          # measured in step 6
LOW = floor_z + 0.20    # ignore the floor itself
HIGH = floor_z + 1.90   # ignore the ceiling

CELL = 0.05
SIZE = 200
first = [float(v) for v in gt_list[0][1][:3]]
origin_x = first[0] - SIZE * CELL / 2
origin_y = first[1] - SIZE * CELL / 2

logodds = np.zeros((SIZE, SIZE), dtype=np.float32)  # 0 = unknown
N_BINS = 360            # one viewing direction per degree
trail = []

print("Building map with free space... click a window and press q to quit.")
for n, (t, rgb_info) in enumerate(rgb_list):
    if n % 2 != 0:
        continue
    rgb = cv2.imread(f"{folder}/{rgb_info[0]}")
    pts, (tx, ty, tz) = world_points(t)

    keep = (pts[:, 2] > LOW) & (pts[:, 2] < HIGH)
    pts = pts[keep]
    if len(pts) == 0:
        continue

    # Camera cell and obstacle cells
    cam_x = int(np.floor((tx - origin_x) / CELL))
    cam_y = int(np.floor((ty - origin_y) / CELL))
    gx = np.floor((pts[:, 0] - origin_x) / CELL).astype(int)
    gy = np.floor((pts[:, 1] - origin_y) / CELL).astype(int)
    inside = (gx >= 0) & (gx < SIZE) & (gy >= 0) & (gy < SIZE)

    # Cells that contain obstacle points this frame
    hit_mask = np.zeros((SIZE, SIZE), dtype=np.uint8)
    hit_mask[gy[inside], gx[inside]] = 1

    # For each viewing direction, find the NEAREST obstacle point
    dx = pts[:, 0] - tx
    dy = pts[:, 1] - ty
    dist = np.hypot(dx, dy)
    ang = np.arctan2(dy, dx)
    bins = ((ang + np.pi) / (2 * np.pi) * N_BINS).astype(int) % N_BINS
    order = np.lexsort((dist, bins))           # sort by bin, then by distance
    _, first_in_bin = np.unique(bins[order], return_index=True)
    nearest = order[first_in_bin]              # nearest point in each direction

    # Draw a free-space line from the camera to each nearest obstacle
    free_mask = np.zeros((SIZE, SIZE), dtype=np.uint8)
    for i in nearest:
        cv2.line(free_mask, (cam_x, cam_y), (int(gx[i]), int(gy[i])), 1, 1)
    free_mask[hit_mask == 1] = 0               # an obstacle cell is never "free"

    # Update the scores
    logodds[hit_mask == 1] += 0.9
    logodds[free_mask == 1] -= 0.4
    np.clip(logodds, -5, 5, out=logodds)

    trail.append((cam_x, cam_y))

    # Draw: gray = unknown, white = free, black = obstacle, red = trail
    map_img = np.full((SIZE, SIZE, 3), 128, dtype=np.uint8)
    map_img[logodds < -0.5] = (255, 255, 255)
    map_img[logodds > 1.0] = (0, 0, 0)
    for (cx_, cy_) in trail:
        if 0 <= cx_ < SIZE and 0 <= cy_ < SIZE:
            map_img[cy_, cx_] = (0, 0, 255)

    cv2.imshow("RGB", rgb)
    cv2.imshow("Map (free space)", cv2.resize(map_img, (600, 600),
                                              interpolation=cv2.INTER_NEAREST))
    if cv2.waitKey(1) & 0xFF == ord("q"):
        break

cv2.destroyAllWindows()
np.save("map.npy", logodds)    # saved for the next step (path planning)
print("Obstacle cells:", int((logodds > 1.0).sum()))
print("Free cells:    ", int((logodds < -0.5).sum()))
print("Saved map.npy")