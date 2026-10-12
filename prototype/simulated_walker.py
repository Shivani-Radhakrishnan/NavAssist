"""A virtual user walks the planned route and speaks each instruction."""
import shutil
import subprocess
import time

import cv2
import numpy as np

from route_planner import (CELL, SIZE, S, astar, base_view, nearest_walkable,
                   simplify, smooth, to_screen, walkable, wrap)

SPEED = 0.5                  # walking speed in meters per second
SAY = shutil.which("say")    # built-in macOS text-to-speech


def turn_words(turn):
    side = "left" if turn > 0 else "right"
    t = abs(turn)
    if t < 45:
        return f"Veer slightly {side}"
    if t < 120:
        return f"Turn {side}"
    return f"Turn sharply {side}"


def plan_steps(waypoints):
    """Same rules as describe() in route_planner.py, but each instruction also
    remembers the points it covers, so the walker knows where to go."""
    pts = simplify(waypoints)
    groups = []
    for a, b in zip(pts[:-1], pts[1:]):
        vx, vy = b[0] - a[0], b[1] - a[1]
        h = float(np.degrees(np.arctan2(vy, vx)))
        d = float(np.hypot(vx, vy)) * CELL
        if groups and abs(wrap(h - groups[-1]["h"])) < 30:
            g = groups[-1]
            g["d"] += d
            g["last_h"] = h
            g["pts"].append(b)
        else:
            groups.append({"h": h, "d": d, "last_h": h, "pts": [a, b]})

    steps = []
    prev = None
    for g in groups:
        text = "Walk straight" if prev is None else turn_words(wrap(g["h"] - prev))
        steps.append((f"{text} for {g['d']:.1f} meters", g["pts"]))
        prev = g["last_h"]
    return pts, steps


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


def run():
    start = nearest_walkable(SIZE // 2, SIZE // 2)
    pos = np.array(start, dtype=float)      # walker position, in cells
    heading = np.array([1.0, 0.0])          # direction the walker faces
    speaker = Speaker()
    walk = None                             # the route currently being walked
    state = {"click": None}

    def on_click(event, x, y, flags, param):
        if event == cv2.EVENT_LBUTTONDOWN:
            state["click"] = (x // S, SIZE - 1 - y // S)

    win = "Virtual walker (click a destination)"
    cv2.namedWindow(win)
    cv2.setMouseCallback(win, on_click)
    background = base_view()
    if not SAY:
        print("(No 'say' command found; instructions will only be printed.)")
    print("Click a WHITE spot to send the walker there. Press q to quit.")

    last = time.time()
    while True:
        now = time.time()
        dt = min(now - last, 0.1)           # cap so a slow frame doesn't teleport
        last = now

        # ---- new destination ----
        if state["click"] is not None:
            cx, cy = state["click"]
            state["click"] = None
            here = (int(round(pos[0])), int(round(pos[1])))
            if not walkable[here[1], here[0]]:
                here = nearest_walkable(*here)
            goal = nearest_walkable(cx, cy)
            path = astar(here, goal)
            if path is None:
                print("No route found. Try a white area connected to the walker.")
            else:
                pts, steps = plan_steps(smooth(path))
                background = base_view()
                for a, b in zip(pts[:-1], pts[1:]):
                    cv2.line(background, to_screen(a), to_screen(b), (0, 160, 0), 2)
                cv2.circle(background, to_screen(goal), 6, (0, 0, 255), -1)
                pos = np.array(here, dtype=float)
                print("\n--- Walking ---")
                if steps:
                    walk = {"steps": steps, "k": 0, "i": 0, "announced": False}
                else:
                    speaker.say("You are already there")
                    walk = None

        # ---- walking ----
        if walk is not None:
            msg, pts = walk["steps"][walk["k"]]
            if not walk["announced"]:
                speaker.say(msg)            # hear the instruction first
                walk["announced"] = True
            elif not speaker.busy():        # then walk that piece
                move = SPEED * dt / CELL    # cells to cover this frame
                while move > 0:
                    target = np.array(pts[walk["i"] + 1], dtype=float)
                    gap = target - pos
                    dist = float(np.hypot(gap[0], gap[1]))
                    if dist > 1e-9:
                        heading = gap / dist
                    if dist > move:
                        pos = pos + heading * move
                        break
                    pos = target
                    move -= dist
                    walk["i"] += 1
                    if walk["i"] == len(pts) - 1:       # finished this instruction
                        walk["k"] += 1
                        walk["i"] = 0
                        walk["announced"] = False
                        if walk["k"] == len(walk["steps"]):
                            speaker.say("You have arrived")
                            walk = None
                        break

        # ---- drawing ----
        view = background.copy()
        p = to_screen(pos)
        tip = to_screen(pos + heading * 6)
        cv2.circle(view, p, 6, (0, 140, 255), -1)       # orange = walker
        cv2.line(view, p, tip, (0, 80, 200), 2)         # facing direction
        cv2.imshow(win, view)
        if cv2.waitKey(30) & 0xFF == ord("q"):
            break

    speaker.stop()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    run()