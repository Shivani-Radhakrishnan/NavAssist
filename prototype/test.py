import numpy as np
import cv2
import matplotlib.pyplot as plt

grid = np.zeros((50, 50))
grid[10:20, 15:30] = 1  # a pretend wall/obstacle

plt.imshow(grid, cmap="gray_r")
plt.title("Hello occupancy grid")
plt.show()

print("OpenCV version:", cv2.__version__)
print("All good!")