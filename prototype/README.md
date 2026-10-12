# Python prototype

The step-by-step exploration NavAssist grew out of. It builds a map from an RGB-D camera
recording, plans routes, speaks directions to a simulated walker, and finally warns about
obstacles from a live iPhone camera.

Run them in this order. Each one builds on the one before it.

| Script | What it does |
|---|---|
| `check_setup.py` | Checks the environment (OpenCV and Matplotlib) |
| `depth_viewer.py` | Loads one RGB frame and its depth image from the TUM dataset and shows depth in color |
| `trajectory_playback.py` | Plays the recording with the ground-truth camera position for each frame |
| `topdown_map.py` | Projects depth into 3-D and draws a top-down map. Pass a dataset folder to change sequence (default `freiburg1_room`) |
| `height_filtered_map.py` | Filters the map by height to remove floor and ceiling, and finds the floor level |
| `occupancy_grid.py` | Builds an occupancy grid with free space by ray-casting, saved as `map.npy` |
| `route_planner.py` | A* route planning on the grid with a safety margin, and turn-by-turn directions; click a destination |
| `simulated_walker.py` | A simulated walker follows the route while the directions are spoken (macOS `say`) |
| `offroute_replanning.py` | Off-route detection: push the walker off the route (`a` / `d`) and it re-plans |
| `live_obstacle_warnings.py` | Live obstacle warnings from an iPhone camera (Continuity Camera) with Depth Anything V2 |

## Setup

```bash
python3.10 -m venv venv && source venv/bin/activate
pip install -r prototype/requirements.txt
```

Download the `freiburg1_xyz` and `freiburg1_room` sequences (TGZ) from the
[TUM RGB-D benchmark](https://cvg.cit.tum.de/data/datasets/rgbd-dataset/download) and
extract them into this folder, so you have `prototype/rgbd_dataset_freiburg1_room/rgb.txt` and so on.

Run the scripts from inside this folder. `occupancy_grid.py` writes `map.npy`, which the
planner, walker and re-planning scripts use:

```bash
cd prototype
python occupancy_grid.py
python route_planner.py
```

`live_obstacle_warnings.py` downloads the Depth Anything V2 Small model (about 100 MB) on its
first run. Use `python live_obstacle_warnings.py --list` to find the iPhone's camera number.
