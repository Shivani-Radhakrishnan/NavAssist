import cv2
import numpy as np

folder = "rgbd_dataset_freiburg1_xyz"


def read_list(filename):
    """Read a TUM text file: returns list of (timestamp, rest_of_line)."""
    rows = []
    with open(f"{folder}/{filename}") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            parts = line.split()
            rows.append((float(parts[0]), parts[1:]))
    return rows


rgb_list = read_list("rgb.txt")
depth_list = read_list("depth.txt")
gt_list = read_list("groundtruth.txt")

depth_times = np.array([t for t, _ in depth_list])
gt_times = np.array([t for t, _ in gt_list])


def closest_index(times, t):
    """Index of the timestamp in `times` nearest to t."""
    return int(np.argmin(np.abs(times - t)))


path_xyz = []  # the user's trail so far

print("Playing... click an image window and press q to quit.")

for t, rgb_info in rgb_list:
    # Load the color frame
    rgb = cv2.imread(f"{folder}/{rgb_info[0]}")

    # Find the depth frame closest in time
    di = closest_index(depth_times, t)
    depth = cv2.imread(f"{folder}/{depth_list[di][1][0]}", cv2.IMREAD_UNCHANGED)
    depth_m = depth.astype(np.float32) / 5000.0

    # Find the true camera position closest in time
    gi = closest_index(gt_times, t)
    x, y, z = [float(v) for v in gt_list[gi][1][:3]]
    path_xyz.append((x, y, z))

    # Colorize depth for viewing
    depth_view = cv2.convertScaleAbs(depth_m, alpha=255.0 / 4.0)
    depth_view = cv2.applyColorMap(depth_view, cv2.COLORMAP_JET)

    # Write the position on the RGB image
    label = f"x={x:.2f} y={y:.2f} z={z:.2f}  frame {len(path_xyz)}/{len(rgb_list)}"
    cv2.putText(rgb, label, (10, 25), cv2.FONT_HERSHEY_SIMPLEX,
                0.6, (0, 255, 0), 2)

    cv2.imshow("RGB", rgb)
    cv2.imshow("Depth", depth_view)

    # ~30 frames per second; press q to quit
    if cv2.waitKey(33) & 0xFF == ord("q"):
        break

cv2.destroyAllWindows()
print("Frames played:", len(path_xyz))
print("Start position:", path_xyz[0])
print("End position:  ", path_xyz[-1])