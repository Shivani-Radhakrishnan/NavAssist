"""Obstacle warnings from the iPhone camera (Continuity Camera).
Depth Anything V2 Small estimates relative depth. The floor at the bottom of
the picture is used as a ruler: anything in the left / center / right zones
that looks much closer than that floor triggers a spoken warning.

    python live_obstacle_warnings.py --list      # show which camera numbers work
    python live_obstacle_warnings.py --cam 1     # run with camera 1
"""
import argparse
import shutil
import subprocess
import time

import cv2
import numpy as np
import torch
from transformers import AutoModelForDepthEstimation

MODEL = "depth-anything/Depth-Anything-V2-Small-hf"
IN_W, IN_H = 518, 294          # model input size (multiples of 14, about 16:9)
VIEW_W, VIEW_H = 640, 360      # size of each half of the window

FLOOR_ROWS = (0.85, 1.00)      # bottom strip of the picture = the floor ruler
FLOOR_COLS = (0.30, 0.70)
ZONE_ROWS = (0.15, 0.75)       # band where obstacles are looked for
ZONES = ["left", "center", "right"]

WARN_DEFAULT = 150             # slider value / 100 = how much closer than the floor
SMOOTH = 0.4                   # how much each new frame moves the zone scores (0..1)
BLOCK_S = 0.4                  # a zone must look blocked this long to count as blocked
CLEAR_S = 1.0                  # ...and look clear this long to count as clear again
CLEAR_RATIO = 0.85             # "clear" means below warn_at * this (a gap stops flicker)
STABLE_S = 0.6                 # a new warning must stay the same this long before speaking
PATH_CLEAR_S = 2.0             # say "Path clear" only after this long with no warning
SIDE_MARGIN = 0.15             # only switch the "clearer" side if the other is this much better
REPEAT_S = 4.0                 # repeat a warning this often while it lasts
SAY = shutil.which("say")      # built-in macOS text-to-speech


class Speaker:
    """Speaks one sentence at a time without freezing the window."""

    def __init__(self):
        self.proc = None

    def say(self, text):
        print("  [speaking]", text)
        self.stop()
        if SAY:
            self.proc = subprocess.Popen([SAY, text])

    def busy(self):
        return self.proc is not None and self.proc.poll() is None

    def stop(self):
        if self.busy():
            self.proc.terminate()


def open_cam(i):
    cap = cv2.VideoCapture(i, cv2.CAP_AVFOUNDATION)
    if not cap.isOpened():
        return None
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1920)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 1080)
    return cap


def list_cams(n=6):
    print("Checking cameras (this takes a few seconds)...")
    for i in range(n):
        cap = open_cam(i)
        if cap is None:
            continue
        ok, frame = False, None
        for _ in range(20):                 # some cameras need a moment to start
            ok, frame = cap.read()
            if ok:
                break
            time.sleep(0.1)
        if ok:
            h, w = frame.shape[:2]
            print(f"  camera {i}: works, {w}x{h}")
        else:
            print(f"  camera {i}: opens but gives no picture")
        cap.release()
    print("The iPhone is usually the larger one (often 1920x1080).")


def load_model():
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    print(f"Loading {MODEL} on {device} (first run downloads about 100 MB)...")
    model = AutoModelForDepthEstimation.from_pretrained(MODEL).to(device).eval()
    return model, device


MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)


@torch.no_grad()
def estimate(model, device, frame):
    """Relative inverse depth at IN_W x IN_H: bigger number = closer."""
    rgb = cv2.cvtColor(cv2.resize(frame, (IN_W, IN_H)), cv2.COLOR_BGR2RGB)
    x = (rgb.astype(np.float32) / 255.0 - MEAN) / STD
    x = torch.from_numpy(x.transpose(2, 0, 1))[None].to(device)
    depth = model(pixel_values=x).predicted_depth[0]
    return depth.float().cpu().numpy()


def box(arr_shape, rows, cols):
    h, w = arr_shape
    return int(rows[0] * h), int(rows[1] * h), int(cols[0] * w), int(cols[1] * w)


def zone_scores(depth, floor_ref):
    """How close each zone looks compared with the floor (1.0 = as close)."""
    scores = []
    for k in range(3):
        y0, y1, x0, x1 = box(depth.shape, ZONE_ROWS, (k / 3, (k + 1) / 3))
        near = np.percentile(depth[y0:y1, x0:x1], 90)   # closest 10% of the zone
        scores.append(float(near / floor_ref))
    return scores


def clearer_side(blocked, scores, prev):
    """Which side to recommend. Sticks with the previous side unless the
    other one is clearly better, so the advice doesn't flip back and forth."""
    left, _, right = blocked
    if left != right:
        return "right" if left else "left"
    best = "left" if scores[0] <= scores[2] else "right"
    if prev is not None and best != prev and abs(scores[0] - scores[2]) < SIDE_MARGIN:
        return prev
    return best


def warning_text(blocked, side):
    left, center, right = blocked
    if center:
        if left and right:
            return "Obstacle ahead, stop"
        return f"Obstacle ahead, clearer on the {side}"
    if left and right:
        return "Obstacles on both sides"
    if left:
        return "Obstacle on the left"
    if right:
        return "Obstacle on the right"
    return None


def draw(frame, depth, scores, blocked, warn_at, floor_ref):
    cam = cv2.resize(frame, (VIEW_W, VIEW_H))
    d = cv2.resize(depth, (VIEW_W, VIEW_H))
    d = cv2.normalize(d, None, 0, 255, cv2.NORM_MINMAX).astype(np.uint8)
    dview = cv2.applyColorMap(d, cv2.COLORMAP_INFERNO)    # brighter = closer

    for view in (cam, dview):
        y0, y1, x0, x1 = box((VIEW_H, VIEW_W), FLOOR_ROWS, FLOOR_COLS)
        cv2.rectangle(view, (x0, y0), (x1, y1 - 1), (255, 200, 0), 1)
        cv2.putText(view, "floor ruler", (x0 + 4, y0 + 14),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, (255, 200, 0), 1)
        for k in range(3):
            y0, y1, x0, x1 = box((VIEW_H, VIEW_W), ZONE_ROWS, (k / 3, (k + 1) / 3))
            color = (0, 0, 255) if blocked[k] else (0, 200, 0)
            cv2.rectangle(view, (x0 + 2, y0), (x1 - 2, y1), color, 3 if blocked[k] else 1)
            cv2.putText(view, f"{ZONES[k]} {scores[k]:.2f}", (x0 + 8, y0 + 20),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.55, color, 2)
    cv2.putText(cam, f"warn at {warn_at:.2f}x floor", (10, VIEW_H - 10),
                cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 2)
    return np.hstack([cam, dview])


def run(cam_index):
    cap = open_cam(cam_index)
    if cap is None:
        print(f"Camera {cam_index} did not open. Try: python live_obstacle_warnings.py --list")
        return
    model, device = load_model()
    speaker = Speaker()

    win = "Obstacle warnings (q quits)"
    cv2.namedWindow(win)
    cv2.createTrackbar("warn at x100", win, WARN_DEFAULT, 300, lambda v: None)

    floor_ref = None
    smooth = None                          # smoothed zone scores
    blocked = [False, False, False]
    changing_since = [None, None, None]    # when each zone started looking different
    side = None                            # current "clearer on the ..." side
    spoken, last_said = None, 0.0          # last warning actually spoken
    pending, pending_since = None, 0.0     # warning waiting to become stable
    clear_since = None
    fps_t, fps = time.time(), 0.0
    print("Hold the phone at chest height, pointing forward, with floor at the bottom.")

    while True:
        ok, frame = cap.read()
        if not ok:
            print("No picture from the camera. Is the iPhone still connected?")
            time.sleep(0.2)
            if cv2.waitKey(1) & 0xFF == ord("q"):
                break
            continue

        depth = estimate(model, device, frame)

        # ---- floor ruler, smoothed so one odd frame doesn't throw it off ----
        y0, y1, x0, x1 = box(depth.shape, FLOOR_ROWS, FLOOR_COLS)
        floor_now = max(float(np.median(depth[y0:y1, x0:x1])), 1e-6)
        if floor_ref is None:
            floor_ref = floor_now
        elif floor_now < 1.5 * floor_ref:     # a big jump means something covers the floor
            floor_ref = 0.9 * floor_ref + 0.1 * floor_now

        warn_at = max(cv2.getTrackbarPos("warn at x100", win), 10) / 100
        now = time.time()
        raw = zone_scores(depth, floor_ref)
        smooth = raw if smooth is None else [
            (1 - SMOOTH) * a + SMOOTH * b for a, b in zip(smooth, raw)]
        scores = smooth

        # ---- blocked / clear, with a gap and a delay so it doesn't flicker ----
        for k in range(3):
            if blocked[k]:
                wants_change = scores[k] < warn_at * CLEAR_RATIO
                need = CLEAR_S
            else:
                wants_change = scores[k] >= warn_at
                need = BLOCK_S
            if not wants_change:
                changing_since[k] = None
            elif changing_since[k] is None:
                changing_since[k] = now
            elif now - changing_since[k] >= need:
                blocked[k] = not blocked[k]
                changing_since[k] = None
        shown = list(blocked)
        if floor_now >= 1.5 * floor_ref:      # something right at your feet, in front
            shown[1] = True

        # ---- speech: only speak a warning once it has been stable ----
        side = clearer_side(shown, scores, side) if shown[1] else None
        msg = warning_text(shown, side)
        if msg != pending:
            pending, pending_since = msg, now
        stable = now - pending_since >= STABLE_S or (shown[1] and not blocked[1])

        if msg is None:
            if clear_since is None:
                clear_since = now
            if spoken is not None and now - clear_since >= PATH_CLEAR_S:
                speaker.say("Path clear")
                spoken = None
        else:
            clear_since = None
            if stable and (msg != spoken or
                           (now - last_said >= REPEAT_S and not speaker.busy())):
                speaker.say(msg)
                spoken, last_said = msg, now

        # ---- drawing ----
        fps = 0.9 * fps + 0.1 / max(now - fps_t, 1e-3)
        fps_t = now
        view = draw(frame, depth, scores, shown, warn_at, floor_ref)
        cv2.putText(view, f"{fps:.0f} fps", (VIEW_W * 2 - 80, 20),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 2)
        cv2.imshow(win, view)
        if cv2.waitKey(1) & 0xFF == ord("q"):
            break

    speaker.stop()
    cap.release()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", action="store_true", help="show which cameras work")
    ap.add_argument("--cam", type=int, default=1, help="camera number (default 1)")
    args = ap.parse_args()
    if args.list:
        list_cams()
    else:
        run(args.cam)
