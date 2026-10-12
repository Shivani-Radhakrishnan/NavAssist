# Python prototype

The step-by-step exploration NavAssist grew out of. It builds a map from an RGB-D camera
recording, plans routes, speaks directions to a simulated walker, and finally warns about
obstacles from a live iPhone camera.

| Script | What it does |
|---|---|
| `test.py` | Checks the environment (OpenCV and Matplotlib) |
| `step2.py` | Loads one RGB frame and its depth image from the TUM dataset and shows depth in color |
| `step3.py` | Plays the recording with the ground-truth camera position for each frame |
| `step4.py` | Projects depth into 3-D and draws a top-down map (`freiburg1_xyz`) |
| `step5.py` | Same as step 4 on the larger `freiburg1_room` sequence |
| `step6.py` | Filters the map by height and finds the floor level |
| `step7.py` | Builds an occupancy grid with free space by ray-casting, saved as `map.npy` |
| `step8.py` | A* route planning on the grid with a safety margin, and turn-by-turn directions; click a destination |
| `step9.py` | A simulated walker follows the route while the directions are spoken (macOS `say`) |
| `step10.py` | Off-route detection: push the walker off the route (`a` / `d`) and it re-plans |
| `step11.py` | Live obstacle warnings from an iPhone camera (Continuity Camera) with Depth Anything V2 |

## Setup

```bash
python3.10 -m venv venv && source venv/bin/activate
pip install -r prototype/requirements.txt
```

Download the `freiburg1_xyz` and `freiburg1_room` sequences (TGZ) from the
[TUM RGB-D benchmark](https://cvg.cit.tum.de/data/datasets/rgbd-dataset/download) and
extract them into this folder, so you have `prototype/rgbd_dataset_freiburg1_room/rgb.txt` and so on.

Run the scripts from inside this folder, in order. Step 7 writes `map.npy`, which steps 8–10 use:

```bash
cd prototype
python step7.py
python step8.py
```

`step11.py` downloads the Depth Anything V2 Small model (about 100 MB) on its first run.
Use `python step11.py --list` to find the iPhone's camera number.
