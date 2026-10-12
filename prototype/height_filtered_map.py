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
    ok = d > 0.1
    d, u, v = d[ok], us[ok], vs[ok]
    pts_cam = np.stack([(u - CX) * d / FX, (v - CY) * d / FY, d], axis=1)
    R = quat_to_matrix(qx, qy, qz, qw)
    return pts_cam @ R.T + np.array([tx, ty, tz]), (tx, ty, tz)


# ---------- PASS 1: find the floor height ----------
print("Pass 1: estimating floor height (about 20 seconds)...")
all_z = []
for n in range(0, len(rgb_list), 10):
    pts, _ = world_points(rgb_list[n][0])
    all_z.append(pts[:, 2])
all_z = np.concatenate(all_z)

for p in (1, 5, 25, 50, 75, 95, 99):
    print(f"  {p:2d}th percentile of height: {np.percentile(all_z, p):.2f}")

floor_z = np.percentile(all_z, 2)
LOW = floor_z + 0.20    # ignore the floor itself
HIGH = floor_z + 1.90   # ignore the ceiling
print(f"Estimated floor z = {floor_z:.2f}  -> keeping points {LOW:.2f} to {HIGH:.2f}")

# ---------- PASS 2: build the filtered map ----------
CELL = 0.05
SIZE = 200
first = [float(v) for v in gt_list[0][1][:3]]
origin_x = first[0] - SIZE * CELL / 2
origin_y = first[1] - SIZE * CELL / 2
hits = np.zeros((SIZE, SIZE), dtype=np.int32)
trail = []

print("Pass 2: building map... click a window and press q to quit.")
for n, (t, rgb_info) in enumerate(rgb_list):
    if n % 2 != 0:
        continue
    rgb = cv2.imread(f"{folder}/{rgb_info[0]}")
    pts, (tx, ty, tz) = world_points(t)

    keep = (pts[:, 2] > LOW) & (pts[:, 2] < HIGH)   # height filter
    pts = pts[keep]

    gx = ((pts[:, 0] - origin_x) / CELL).astype(int)
    gy = ((pts[:, 1] - origin_y) / CELL).astype(int)
    inside = (gx >= 0) & (gx < SIZE) & (gy >= 0) & (gy < SIZE)
    np.add.at(hits, (gy[inside], gx[inside]), 1)

    trail.append((int((tx - origin_x) / CELL), int((ty - origin_y) / CELL)))

    map_img = np.full((SIZE, SIZE, 3), 255, dtype=np.uint8)
    map_img[hits >= 5] = (0, 0, 0)          # stricter: need 5 hits
    for (cx_, cy_) in trail:
        if 0 <= cx_ < SIZE and 0 <= cy_ < SIZE:
            map_img[cy_, cx_] = (0, 0, 255)
    cv2.imshow("RGB", rgb)
    cv2.imshow("Map (filtered)", cv2.resize(map_img, (600, 600),
                                            interpolation=cv2.INTER_NEAREST))
    if cv2.waitKey(1) & 0xFF == ord("q"):
        break

cv2.destroyAllWindows()
print("Done. Obstacle cells:", int((hits >= 5).sum()))