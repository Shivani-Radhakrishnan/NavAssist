"""Off-route detection.
Push the walker off the green line with the a / d keys. The system notices,
says "Off route. Recalculating.", and plans a new route from where it is."""
import time

import cv2
import numpy as np

from route_planner import (CELL, SIZE, S, astar, base_view, nearest_walkable,
                   smooth, to_screen, walkable)
from simulated_walker import SPEED, Speaker, plan_steps

OFF_ROUTE_M = 0.35     # farther than this from the green line counts as off route
OFF_ROUTE_S = 0.3      # ...if it lasts at least this many seconds
PUSH_M = 0.5           # how far one press of a / d pushes the walker sideways


def is_walkable(p):
    x, y = int(round(p[0])), int(round(p[1]))
    return 0 <= x < SIZE and 0 <= y < SIZE and bool(walkable[y, x])


def cell_of(p):
    """The walker's grid cell, moved to the nearest walkable cell if needed."""
    here = (int(round(p[0])), int(round(p[1])))
    return here if is_walkable(p) else nearest_walkable(*here)


def dist_to_route(p, pts):
    """Shortest distance in meters from point p to the route's line segments."""
    best = 1e9
    for a, b in zip(pts[:-1], pts[1:]):
        a = np.array(a, dtype=float)
        b = np.array(b, dtype=float)
        ab = b - a
        length2 = float(ab @ ab)
        t = 0.0 if length2 == 0 else float(np.clip((p - a) @ ab / length2, 0, 1))
        closest = a + t * ab
        best = min(best, float(np.hypot(*(p - closest))))
    return best * CELL


def make_walk(here, goal):
    """Plan a route and package everything the walker needs to follow it."""
    path = astar(here, goal)
    if path is None:
        return None
    pts, steps = plan_steps(smooth(path))
    bg = base_view()
    for a, b in zip(pts[:-1], pts[1:]):
        cv2.line(bg, to_screen(a), to_screen(b), (0, 160, 0), 2)
    cv2.circle(bg, to_screen(goal), 6, (0, 0, 255), -1)
    return {"pts": pts, "steps": steps, "k": 0, "i": 0, "announced": False,
            "goal": goal, "bg": bg, "off_since": None}


def run():
    pos = np.array(nearest_walkable(SIZE // 2, SIZE // 2), dtype=float)
    heading = np.array([1.0, 0.0])
    speaker = Speaker()
    walk = None
    background = base_view()
    state = {"click": None}

    def on_click(event, x, y, flags, param):
        if event == cv2.EVENT_LBUTTONDOWN:
            state["click"] = (x // S, SIZE - 1 - y // S)

    win = "Off-route test (click a destination)"
    cv2.namedWindow(win)
    cv2.setMouseCallback(win, on_click)
    print("Click a WHITE spot to send the walker there.")
    print("While it walks: press a to push it LEFT, d to push it RIGHT. q quits.")

    def start(new):
        """Begin following a newly planned walk (or report a problem)."""
        nonlocal walk, background, pos
        if new is None:
            print("No route found. Try a white area connected to the walker.")
            walk = None
            return
        background = new["bg"]
        if not new["steps"]:
            speaker.say("You are already there")
            walk = None
            return
        walk = new

    last = time.time()
    while True:
        now = time.time()
        dt = min(now - last, 0.1)
        last = now

        # ---- new destination ----
        if state["click"] is not None:
            cx, cy = state["click"]
            state["click"] = None
            here = cell_of(pos)
            pos = np.array(here, dtype=float)
            print("\n--- Walking ---")
            start(make_walk(here, nearest_walkable(cx, cy)))

        # ---- off-route check ----
        off = None
        if walk is not None:
            off = dist_to_route(pos, walk["pts"])
            if off > OFF_ROUTE_M:
                if walk["off_since"] is None:
                    walk["off_since"] = now
                elif now - walk["off_since"] >= OFF_ROUTE_S:
                    print(f"\n--- Off route ({off:.2f} m from the line), re-planning ---")
                    speaker.say("Off route. Recalculating.")
                    here = cell_of(pos)
                    pos = np.array(here, dtype=float)
                    start(make_walk(here, walk["goal"]))
            else:
                walk["off_since"] = None

        # ---- walking ----
        if walk is not None:
            msg, pts = walk["steps"][walk["k"]]
            if not walk["announced"]:
                if not speaker.busy():          # let "Recalculating" finish first
                    speaker.say(msg)
                    walk["announced"] = True
            elif not speaker.busy():
                move = SPEED * dt / CELL
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
                    if walk["i"] == len(pts) - 1:
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
        cv2.circle(view, p, 6, (0, 140, 255), -1)                 # orange = walker
        cv2.line(view, p, to_screen(pos + heading * 6), (0, 80, 200), 2)
        if off is not None:
            color = (0, 0, 255) if off > OFF_ROUTE_M else (0, 120, 0)
            cv2.putText(view, f"off line: {off:.2f} m", (10, 25),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, color, 2)
        cv2.imshow(win, view)

        # ---- keys ----
        key = cv2.waitKey(30) & 0xFF
        if key == ord("q"):
            break
        if key in (ord("a"), ord("d")) and walk is not None:
            if key == ord("a"):
                side, name = np.array([-heading[1], heading[0]]), "left"
            else:
                side, name = np.array([heading[1], -heading[0]]), "right"
            for m in (PUSH_M, 0.4, 0.3, 0.2):      # shorter push if a wall is close
                p_new = pos + side * (m / CELL)
                if is_walkable(p_new):
                    pos = p_new
                    print(f"(pushed {name} {m:.1f} m)")
                    break
            else:
                print(f"(can't push {name}: too close to a wall)")

    speaker.stop()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    run()