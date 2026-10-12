import heapq
import cv2
import numpy as np

# ---------- Load the map made in step 7 ----------
logodds = np.load("map.npy")
SIZE = logodds.shape[0]
CELL = 0.05                       # each cell is 5 cm
MARGIN_M = 0.25                   # stay at least 25 cm away from obstacles

free = logodds < -0.5
obstacle = logodds > 1.0

# Grow obstacles by the safety margin; unknown (gray) cells are NOT walkable
m = int(round(MARGIN_M / CELL))
kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * m + 1, 2 * m + 1))
blocked = cv2.dilate(obstacle.astype(np.uint8), kernel) > 0
walkable = free & ~blocked


def nearest_walkable(x, y):
    """If (x, y) isn't walkable, move to the closest cell that is."""
    ys, xs = np.nonzero(walkable)
    i = np.argmin((xs - x) ** 2 + (ys - y) ** 2)
    return int(xs[i]), int(ys[i])


# ---------- A* path planning ----------
MOVES = [(1, 0, 1.0), (-1, 0, 1.0), (0, 1, 1.0), (0, -1, 1.0),
         (1, 1, 1.414), (1, -1, 1.414), (-1, 1, 1.414), (-1, -1, 1.414)]


def astar(start, goal):
    def h(c):
        return float(np.hypot(c[0] - goal[0], c[1] - goal[1]))

    heap = [(h(start), 0.0, start)]
    came = {}
    best = {start: 0.0}
    while heap:
        _, g, cur = heapq.heappop(heap)
        if cur == goal:
            path = [cur]
            while cur in came:
                cur = came[cur]
                path.append(cur)
            return path[::-1]
        if g > best.get(cur, 1e9):
            continue
        for dx, dy, cost in MOVES:
            nx, ny = cur[0] + dx, cur[1] + dy
            if not (0 <= nx < SIZE and 0 <= ny < SIZE):
                continue
            if not walkable[ny, nx]:
                continue
            # don't cut corners diagonally between two blocked cells
            if dx != 0 and dy != 0:
                if not (walkable[cur[1], nx] and walkable[ny, cur[0]]):
                    continue
            ng = g + cost
            if ng < best.get((nx, ny), 1e9):
                best[(nx, ny)] = ng
                came[(nx, ny)] = cur
                heapq.heappush(heap, (ng + h((nx, ny)), ng, (nx, ny)))
    return None


def line_clear(a, b):
    n = int(max(abs(b[0] - a[0]), abs(b[1] - a[1]))) + 1
    xs = np.linspace(a[0], b[0], n).round().astype(int)
    ys = np.linspace(a[1], b[1], n).round().astype(int)
    return bool(walkable[ys, xs].all())


def smooth(path):
    """Keep only the corner points: skip ahead whenever a straight line is clear."""
    out = [path[0]]
    i = 0
    while i < len(path) - 1:
        j = len(path) - 1
        while j > i + 1 and not line_clear(path[i], path[j]):
            j -= 1
        out.append(path[j])
        i = j
    return out


# ---------- Turn the route into instructions ----------
def wrap(angle):
    """Wrap an angle in degrees to the range -180..180."""
    return (angle + 180) % 360 - 180


def simplify(waypoints, min_len=0.5):
    """Remove corner points that create very short segments (under 0.5 m)."""
    pts = list(waypoints)
    changed = True
    while changed and len(pts) > 2:
        changed = False
        for i in range(len(pts) - 1):
            seg = float(np.hypot(pts[i + 1][0] - pts[i][0],
                                 pts[i + 1][1] - pts[i][1])) * CELL
            if seg < min_len:
                if i + 1 < len(pts) - 1:
                    del pts[i + 1]          # drop the corner after the short piece
                elif i > 0:
                    del pts[i]              # short last piece: drop the corner before it
                else:
                    continue
                changed = True
                break
    return pts


def describe(waypoints):
    """Grid x = east, grid y = north (like the real world), so a positive
    turn angle (counter-clockwise) means LEFT."""
    pts = simplify(waypoints)

    # 1) heading and length of each straight piece
    segs = []
    for a, b in zip(pts[:-1], pts[1:]):
        vx, vy = b[0] - a[0], b[1] - a[1]
        segs.append((float(np.degrees(np.arctan2(vy, vx))),
                     float(np.hypot(vx, vy)) * CELL))

    # 2) merge neighbouring pieces that point almost the same way (within 30 degrees)
    groups = []                              # each: [first_heading, length, last_heading]
    for h, d in segs:
        if groups and abs(wrap(h - groups[-1][0])) < 30:
            groups[-1][1] += d
            groups[-1][2] = h
        else:
            groups.append([h, d, h])

    # 3) words
    msgs = []
    prev = None
    for h, d, last_h in groups:
        if prev is None:
            text = "Walk straight"
        else:
            turn = wrap(h - prev)
            side = "left" if turn > 0 else "right"
            t = abs(turn)
            if t < 45:
                text = f"Veer slightly {side}"
            elif t < 120:
                text = f"Turn {side}"
            else:
                text = f"Turn sharply {side}"
        msgs.append(f"{text} for {d:.1f} meters")
        prev = last_h
    msgs.append("You have arrived")
    return msgs


# ---------- Drawing ----------
S = 3                                    # screen pixels per cell


def to_screen(c):
    # flip vertically so the picture looks like a real overhead view
    return int(c[0] * S + S // 2), int((SIZE - 1 - c[1]) * S + S // 2)


def base_view():
    img = np.full((SIZE, SIZE, 3), 128, dtype=np.uint8)   # gray = unknown
    img[free] = (255, 255, 255)                           # white = free
    img[free & blocked] = (210, 210, 255)                 # pink = too close to a wall
    img[obstacle] = (0, 0, 0)                             # black = obstacle
    big = cv2.resize(img, (SIZE * S, SIZE * S), interpolation=cv2.INTER_NEAREST)
    return cv2.flip(big, 0)


def run():
    start = nearest_walkable(SIZE // 2, SIZE // 2)   # where the walk began
    print("Walkable cells:", int(walkable.sum()))
    print("Click a WHITE spot on the map to choose a destination. Press q to quit.")

    state = {"click": None}

    def on_click(event, x, y, flags, param):
        if event == cv2.EVENT_LBUTTONDOWN:
            state["click"] = (x // S, SIZE - 1 - y // S)

    win = "Route planner (click a destination)"
    cv2.namedWindow(win)
    cv2.setMouseCallback(win, on_click)

    view = base_view()
    cv2.circle(view, to_screen(start), 6, (255, 0, 0), -1)

    while True:
        cv2.imshow(win, view)
        if state["click"] is not None:
            cx, cy = state["click"]
            state["click"] = None
            goal = nearest_walkable(cx, cy)
            if goal != (cx, cy):
                print("(That spot isn't walkable; using the nearest walkable spot.)")
            path = astar(start, goal)
            view = base_view()
            cv2.circle(view, to_screen(start), 6, (255, 0, 0), -1)   # blue = start
            cv2.circle(view, to_screen(goal), 6, (0, 0, 255), -1)    # red = goal
            if path is None:
                print("No route found. Try a white area connected to the start.")
                continue
            wps = smooth(path)
            for a, b in zip(wps[:-1], wps[1:]):
                cv2.line(view, to_screen(a), to_screen(b), (0, 160, 0), 2)
            print("\n--- Route ---")
            for k, msg in enumerate(describe(wps), 1):
                print(f"{k}. {msg}")
        if cv2.waitKey(30) & 0xFF == ord("q"):
            break
    cv2.destroyAllWindows()


if __name__ == "__main__":
    run()