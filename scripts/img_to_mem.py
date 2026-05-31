"""
img_to_mem.py

Converts a 640x480 image to a 1-bit-per-pixel .mem file for FPGA framebuffer
initialization via XPM_MEMORY_SDPRAM's MEMORY_INIT_FILE parameter.

Supports multiple dithering modes including blue noise for high-quality
binarization of grayscale images.

Usage:
    python img_to_mem.py <input_image> [output.mem] [--dither blue_noise|bayer|floyd|threshold] [--threshold 128] [--invert]

Output format: ASCII hex, one pixel per line (0 or 1), 307,200 lines total.
Pixels are in row-major order (left-to-right, top-to-bottom).

Requirements:
    pip install Pillow numpy
"""

import argparse
import sys
import numpy as np
from PIL import Image


def generate_blue_noise(size=64):
    """
    Generate a blue noise threshold matrix using a simplified void-and-cluster
    algorithm. The result is a tileable size x size matrix with values 0-255.
    """
    rng = np.random.default_rng(42)

    # Start with ~10% of pixels set as initial binary pattern
    initial_density = 0.1
    binary = rng.random((size, size)) < initial_density

    def gaussian_energy(pattern, sigma=1.5):
        """Compute energy map by convolving with a Gaussian kernel (wrapping)."""
        from scipy.ndimage import gaussian_filter
        return gaussian_filter(pattern.astype(float), sigma=sigma, mode='wrap')

    # Phase 1: Remove tightest clusters from initial pattern
    n_ones = int(binary.sum())
    rank = np.zeros((size, size), dtype=int)
    current = binary.copy()
    rank_value = n_ones - 1

    for _ in range(n_ones):
        energy = gaussian_energy(current)
        # Find tightest cluster (highest energy among set pixels)
        masked = np.where(current, energy, -np.inf)
        idx = np.unravel_index(masked.argmax(), masked.shape)
        current[idx] = False
        rank[idx] = rank_value
        rank_value -= 1

    # Phase 2: Add pixels to largest voids
    current = binary.copy()
    rank_value = n_ones

    for _ in range(size * size - n_ones):
        energy = gaussian_energy(current)
        # Find largest void (lowest energy among unset pixels)
        masked = np.where(~current, energy, np.inf)
        idx = np.unravel_index(masked.argmin(), masked.shape)
        current[idx] = True
        rank[idx] = rank_value
        rank_value += 1

    # Normalize to 0-255
    result = (rank / (size * size - 1) * 255).astype(np.uint8)
    return result


def generate_bayer(n=3):
    """Generate a Bayer ordered dither matrix of size 2^n x 2^n."""
    if n == 0:
        return np.array([[0]])
    smaller = generate_bayer(n - 1)
    size = smaller.shape[0]
    result = np.zeros((size * 2, size * 2), dtype=int)
    result[0::2, 0::2] = 4 * smaller
    result[0::2, 1::2] = 4 * smaller + 2
    result[1::2, 0::2] = 4 * smaller + 3
    result[1::2, 1::2] = 4 * smaller + 1
    total = (size * 2) ** 2
    return (result / total * 255).astype(np.uint8)


def dither_blue_noise(gray, invert):
    """Apply blue noise dithering using a generated threshold matrix."""
    try:
        noise = generate_blue_noise(64)
    except ImportError:
        print("Blue noise requires scipy. Install with: pip install scipy")
        print("Falling back to Bayer dithering.")
        return dither_bayer(gray, invert)

    h, w = gray.shape
    # Tile the noise texture across the image
    tiled = np.tile(noise, (h // 64 + 1, w // 64 + 1))[:h, :w]

    result = (gray >= tiled).astype(np.uint8)
    if invert:
        result = 1 - result
    return result


def dither_bayer(gray, invert):
    """Apply Bayer ordered dithering."""
    bayer = generate_bayer(3)  # 8x8 matrix
    h, w = gray.shape
    tiled = np.tile(bayer, (h // 8 + 1, w // 8 + 1))[:h, :w]

    result = (gray >= tiled).astype(np.uint8)
    if invert:
        result = 1 - result
    return result


def dither_floyd_steinberg(gray, invert):
    """Apply Floyd-Steinberg error diffusion dithering."""
    img = gray.astype(float)
    h, w = img.shape
    result = np.zeros((h, w), dtype=np.uint8)

    for y in range(h):
        for x in range(w):
            old = img[y, x]
            new = 255.0 if old >= 128 else 0.0
            result[y, x] = 1 if new > 0 else 0
            error = old - new

            if x + 1 < w:
                img[y, x + 1] += error * 7 / 16
            if y + 1 < h:
                if x - 1 >= 0:
                    img[y + 1, x - 1] += error * 3 / 16
                img[y + 1, x] += error * 5 / 16
                if x + 1 < w:
                    img[y + 1, x + 1] += error * 1 / 16

    if invert:
        result = 1 - result
    return result


def dither_threshold(gray, threshold, invert):
    """Simple threshold binarization."""
    result = (gray >= threshold).astype(np.uint8)
    if invert:
        result = 1 - result
    return result


def convert(input_path, output_path, dither="blue_noise", threshold=128, invert=False):
    img = Image.open(input_path)

    # Resize to 640x480 if needed
    if img.size != (640, 480):
        print(f"Resizing from {img.size} to (640, 480)")
        img = img.resize((640, 480), Image.LANCZOS)

    # Convert to grayscale numpy array
    gray = np.array(img.convert("L"))

    # Apply dithering
    if dither == "blue_noise":
        print("Applying blue noise dithering...")
        result = dither_blue_noise(gray, invert)
    elif dither == "bayer":
        print("Applying Bayer ordered dithering...")
        result = dither_bayer(gray, invert)
    elif dither == "floyd":
        print("Applying Floyd-Steinberg dithering...")
        result = dither_floyd_steinberg(gray, invert)
    elif dither == "threshold":
        print(f"Applying threshold binarization (threshold={threshold})...")
        result = dither_threshold(gray, threshold, invert)
    else:
        print(f"Unknown dither mode: {dither}")
        sys.exit(1)

    # Write .mem file
    with open(output_path, "w") as f:
        for y in range(480):
            for x in range(640):
                f.write(f"{result[y, x]}\n")

    # Also save a preview PNG for verification
    preview_path = output_path.rsplit(".", 1)[0] + "_preview.png"
    preview = Image.fromarray(result * 255)
    preview.save(preview_path)

    total = 640 * 480
    print(f"Wrote {total} pixels to {output_path}")
    print(f"Preview saved to {preview_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Convert an image to a 1bpp .mem file for FPGA framebuffer"
    )
    parser.add_argument("input", help="Input image path (any format Pillow supports)")
    parser.add_argument(
        "output", nargs="?", default="framebuffer_init.mem",
        help="Output .mem file path (default: framebuffer_init.mem)"
    )
    parser.add_argument(
        "--dither", choices=["blue_noise", "bayer", "floyd", "threshold"],
        default="blue_noise",
        help="Dithering mode (default: blue_noise)"
    )
    parser.add_argument(
        "--threshold", type=int, default=128,
        help="Brightness threshold for 'threshold' mode (0-255, default 128)"
    )
    parser.add_argument(
        "--invert", action="store_true",
        help="Invert the output (swap black/white)"
    )
    args = parser.parse_args()
    convert(args.input, args.output, args.dither, args.threshold, args.invert)


if __name__ == "__main__":
    main()