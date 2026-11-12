"""
Photo handling: every upload is re-encoded so nothing from the original file
survives except the pixels. That strips EXIF (which holds the exact GPS
position and phone model), fixes rotation, shrinks large photos and blurs any
areas the finder marked as private (ID numbers, card numbers, addresses).
"""
import io

from django.conf import settings
from django.core.files.base import ContentFile
from PIL import Image, ImageFilter, ImageOps, UnidentifiedImageError


class ImageError(ValueError):
    pass


def _clamp(value, low=0.0, high=1.0):
    return max(low, min(high, float(value)))


def blur_regions(img, regions):
    """
    Blur rectangles given as fractions of the image size:
    [{"x": 0.1, "y": 0.2, "w": 0.3, "h": 0.1}, ...]. Fractions keep the
    phone and server in agreement whatever size the photo ends up.
    """
    width, height = img.size
    for region in regions or []:
        try:
            x = _clamp(region["x"])
            y = _clamp(region["y"])
            w = _clamp(region["w"])
            h = _clamp(region["h"])
        except (KeyError, TypeError, ValueError):
            raise ImageError("Each blur region needs numeric x, y, w and h between 0 and 1.")
        left, top = int(x * width), int(y * height)
        right, bottom = int(min(1.0, x + w) * width), int(min(1.0, y + h) * height)
        if right - left < 2 or bottom - top < 2:
            continue
        box = (left, top, right, bottom)
        patch = img.crop(box)
        # Pixelate, then blur: a plain blur on large text can stay readable.
        small = patch.resize(
            (max(1, patch.width // 16), max(1, patch.height // 16)), Image.Resampling.BILINEAR
        )
        patch = small.resize(patch.size, Image.Resampling.NEAREST).filter(
            ImageFilter.GaussianBlur(radius=max(4, min(patch.size) // 10))
        )
        img.paste(patch, box)
    return img


def clean_image(uploaded_file, regions=None):
    """Return (ContentFile, width, height) of a metadata-free JPEG."""
    limit_mb = settings.FTL["MAX_IMAGE_MB"]
    if uploaded_file.size > limit_mb * 1024 * 1024:
        raise ImageError(f"Each photo must be under {limit_mb} MB.")
    try:
        img = Image.open(uploaded_file)
        img.load()
    except (UnidentifiedImageError, OSError):
        raise ImageError("That file isn't a photo we can read.")

    img = ImageOps.exif_transpose(img)  # apply the phone's rotation before dropping EXIF
    if img.mode not in ("RGB", "L"):
        img = img.convert("RGB")

    max_side = settings.FTL["IMAGE_MAX_SIDE_PX"]
    img.thumbnail((max_side, max_side), Image.Resampling.LANCZOS)
    img = blur_regions(img, regions)

    # Copy pixels into a fresh image so no metadata (EXIF, XMP, ICC, GPS) is carried over.
    clean = Image.new(img.mode, img.size)
    clean.paste(img)

    buffer = io.BytesIO()
    clean.save(buffer, format="JPEG", quality=82, optimize=True)
    return ContentFile(buffer.getvalue(), name="photo.jpg"), clean.width, clean.height
