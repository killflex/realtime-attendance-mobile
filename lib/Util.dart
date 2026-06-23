import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

class Util {
  static img.Image convertBGRA8888ToImage(CameraImage cameraImage) {
    final plane = cameraImage.planes[0];

    return img.Image.fromBytes(
      width: cameraImage.width,
      height: cameraImage.height,
      bytes: plane.bytes.buffer,
      rowStride: plane.bytesPerRow,
      order: img.ChannelOrder.bgra,
    );
  }

  static img.Image convertNV21(CameraImage image) {
    Uint8List yuv420sp = image.planes[0].bytes;

    final width = image.width.toInt();
    final height = image.height.toInt();

    final outImg = img.Image(height: height, width: width);
    final int frameSize = width * height;

    for (int j = 0, yp = 0; j < height; j++) {
      int uvp = frameSize + (j >> 1) * width, u = 0, v = 0;

      for (int i = 0; i < width; i++, yp++) {
        int y = (0xff & yuv420sp[yp]) - 16;

        if (y < 0) y = 0;

        if ((i & 1) == 0) {
          v = (0xff & yuv420sp[uvp++]) - 128;
          u = (0xff & yuv420sp[uvp++]) - 128;
        }

        int y1192 = 1192 * y;
        int r = (y1192 + 1634 * v);
        int g = (y1192 - 833 * v - 400 * u);
        int b = (y1192 + 2066 * u);

        if (r < 0) {
          r = 0;
        } else if (r > 262143) {
          r = 262143;
        }

        if (g < 0) {
          g = 0;
        } else if (g > 262143) {
          g = 262143;
        }

        if (b < 0) {
          b = 0;
        } else if (b > 262143) {
          b = 262143;
        }

        outImg.setPixelRgb(
          i,
          j,
          ((r << 6) & 0xff0000) >> 16,
          ((g >> 2) & 0xff00) >> 8,
          (b >> 10) & 0xff,
        );
      }
    }

    return outImg;
  }

  // Convert CameraImage to Image
  img.Image convertYUV420ToImage(CameraImage cameraImage) {
    final width = cameraImage.width;
    final height = cameraImage.height;

    final yRowStride = cameraImage.planes[0].bytesPerRow;
    final uvRowStride = cameraImage.planes[1].bytesPerRow;
    final uvPixelStride = cameraImage.planes[1].bytesPerPixel!;

    final image = img.Image(width: width, height: height);

    for (var w = 0; w < width; w++) {
      for (var h = 0; h < height; h++) {
        final uvIndex =
            uvPixelStride * (w / 2).floor() + uvRowStride * (h / 2).floor();
        final yIndex = h * yRowStride + w;

        final y = cameraImage.planes[0].bytes[yIndex];
        final u = cameraImage.planes[1].bytes[uvIndex];
        final v = cameraImage.planes[2].bytes[uvIndex];

        image.data!.setPixelR(w, h, yuv2rgb(y, u, v)); //= yuv2rgb(y, u, v);
      }
    }

    return image;
  }

  int yuv2rgb(int y, int u, int v) {
    // Convert yuv pixel to rgb
    var r = (y + v * 1436 / 1024 - 179).round();
    var g = (y - u * 46549 / 131072 + 44 - v * 93604 / 131072 + 91).round();
    var b = (y + u * 1814 / 1024 - 227).round();

    // Clipping RGB values to be inside boundaries [ 0 , 255 ]
    r = r.clamp(0, 255);
    g = g.clamp(0, 255);
    b = b.clamp(0, 255);

    return 0xff000000 |
        ((b << 16) & 0xff0000) |
        ((g << 8) & 0xff00) |
        (r & 0xff);
  }

  static img.Image cropAndRotate(
    img.Image src, {
    required int left,
    required int top,
    required int width,
    required int height,
    required CameraLensDirection direction,
  }) {
    // Create the target image. Width is height of crop, height is width of crop.
    final dst = img.Image(width: height, height: width, format: src.format);

    final bool isFront = direction == CameraLensDirection.front;

    for (int ty = 0; ty < width; ty++) {
      for (int tx = 0; tx < height; tx++) {
        int sx;
        int sy;

        if (isFront) {
          // 270° CCW: landscape_sx = cropW - 1 - ty, landscape_sy = tx
          sx = width - 1 - ty;
          sy = tx;
        } else {
          // 90° CW: landscape_sx = ty, landscape_sy = cropH - 1 - tx
          sx = ty;
          sy = height - 1 - tx;
        }

        // Map to absolute coordinates in the source landscape image
        final int srcX = left + sx;
        final int srcY = top + sy;

        final srcPixel = src.getPixel(srcX, srcY);
        final dstPixel = dst.getPixel(tx, ty);

        dstPixel.r = srcPixel.r;
        dstPixel.g = srcPixel.g;
        dstPixel.b = srcPixel.b;
        dstPixel.a = srcPixel.a;
      }
    }

    return dst;
  }

  static img.Image convertNV21CropAndRotate(
    CameraImage image,
    Rect lsBox,
    CameraLensDirection direction,
  ) {
    final int width = image.width;
    final int height = image.height;
    final Uint8List yuv420sp = image.planes[0].bytes;

    final int left = lsBox.left.clamp(0.0, (width - 1).toDouble()).toInt();
    final int top = lsBox.top.clamp(0.0, (height - 1).toDouble()).toInt();
    final int right = lsBox.right.clamp((left + 1).toDouble(), width.toDouble()).toInt();
    final int bottom = lsBox.bottom.clamp((top + 1).toDouble(), height.toDouble()).toInt();
    final int cropW = right - left;
    final int cropH = bottom - top;

    // Output dimensions are swapped because we rotate 90/270 degrees.
    // Width becomes cropH, height becomes cropW.
    final dst = img.Image(width: cropH, height: cropW);

    final bool isFront = direction == CameraLensDirection.front;
    final int frameSize = width * height;

    for (int ty = 0; ty < cropW; ty++) {
      for (int tx = 0; tx < cropH; tx++) {
        int sx;
        int sy;

        if (isFront) {
          // 270° CCW: landscape_sx = cropW - 1 - ty, landscape_sy = tx
          sx = cropW - 1 - ty;
          sy = tx;
        } else {
          // 90° CW: landscape_sx = ty, landscape_sy = cropH - 1 - tx
          sx = ty;
          sy = cropH - 1 - tx;
        }

        // Map to absolute coordinates in the source landscape image
        final int srcX = (left + sx).clamp(0, width - 1);
        final int srcY = (top + sy).clamp(0, height - 1);

        // Fetch Y
        final int yIndex = srcY * width + srcX;
        final int yValue = yuv420sp[yIndex];

        // Fetch U & V (NV21 format: V, U, V, U... interleaved)
        final int uvRow = srcY >> 1;
        final int uvCol = srcX >> 1;
        final int uvIndex = frameSize + uvRow * width + uvCol * 2;

        final int vValue = yuv420sp[uvIndex];
        final int uValue = yuv420sp[uvIndex + 1];

        // YUV to RGB Conversion
        int yVal = (yValue & 0xff) - 16;
        if (yVal < 0) yVal = 0;
        int vVal = (vValue & 0xff) - 128;
        int uVal = (uValue & 0xff) - 128;

        int y1192 = 1192 * yVal;
        int r = (y1192 + 1634 * vVal) >> 10;
        int g = (y1192 - 833 * vVal - 400 * uVal) >> 10;
        int b = (y1192 + 2066 * uVal) >> 10;

        r = r.clamp(0, 255);
        g = g.clamp(0, 255);
        b = b.clamp(0, 255);

        final dstPixel = dst.getPixel(tx, ty);
        dstPixel.r = r;
        dstPixel.g = g;
        dstPixel.b = b;
        dstPixel.a = 255;
      }
    }

    return dst;
  }

  static Uint8List imageToRgbBytes(img.Image image) {
    final rgbBytes = Uint8List(image.width * image.height * 3);
    int idx = 0;
    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        rgbBytes[idx++] = pixel.r.toInt();
        rgbBytes[idx++] = pixel.g.toInt();
        rgbBytes[idx++] = pixel.b.toInt();
      }
    }
    return rgbBytes;
  }
}
